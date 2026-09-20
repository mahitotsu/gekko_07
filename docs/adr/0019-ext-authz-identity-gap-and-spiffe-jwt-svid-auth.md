# ADR 0019: ext-authz-serviceの身元検証ギャップを解消し、fraud-mcp-server→account-serviceをSPIFFE JWT-SVIDクライアント認証へ移行する

- **Status**: Accepted
- **Date**: 2026-09-16

## Context

[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)・[ADR 0016](0016-ext-authz-and-keycloak-mtls.md)は、Token Exchangeの実装を各サービスのEnvoyサイドカーから呼ばれる共有の`ext-authz-service`(呼び出し元ごとに固定資格情報を持つ別インスタンス構成)に集約し、`ext-authz-service`自体もSPIRE mTLSで保護した。

この設計をレビューした結果、身元検証という目的にとって看過できないギャップが見つかった。`ext-authz-service`は呼び出し元(例:fraud-mcp-server)のKeycloakクライアントの`client_secret`を保持し、呼び出し元に代わってToken Exchangeを行う。Keycloakが最終的に検証するmTLS接続の身元(SPIFFE ID)は`ext-authz-service`自身のものであり、Keycloakへ主張しているclient_id(呼び出し元のもの)とは一致しない。Keycloakの認可判定は「client_secretを知っているか」に基づいており、「本当にそのワークロードが要求しているか」を検証できていない。NetworkPolicy([ADR 0018](0018-network-policy-default-deny.md))・mTLS([ADR 0012](0012-spiffe-spire-mtls-single-hop.md)〜[0016](0016-ext-authz-and-keycloak-mtls.md))は経路の防御にはなるが、Keycloakというトラスト・アンカー自身にとっての身元証明にはなっていない。

是正案として、以下3方向を検証した（詳細は[docs/insights.md](../insights.md)「ext-authz-serviceの身元検証ギャップとKeycloakクライアント認証方式の調査」節）。

1. **RFC 8705(mTLSクライアント認証、`client-x509`)**：Keycloak 26.7.0の`X509ClientAuthenticator`はSubject DNのみを見ており、SPIFFE X.509-SVIDのURI SANには対応していない(Keycloak公式Issue #41907で既知の未対応機能と確認済み)。**不成立。**
2. **Delegationモデル(`act`/`actor_token`)**：Keycloakのpreview機能`token-exchange-delegation`に依存する。actor_token検証の仕組み自体は本ADRが採用するJWT-SVID方式と技術的に近いが、client認証の軸(誰がKeycloakに対して自分の身元を証明するか)とトークン意味論の軸(`sub`が誰のままか、`act`に何を記録するか)は独立した別の関心事であり、混同すべきではない。本ADRが扱うのは前者(クライアント認証)のみで、後者(トークン意味論)はimpersonation的な現状([ADR 0006](0006-claim-vs-external-attribute-criteria.md)の設計のまま)を変更しない。
3. **KeycloakネイティブのSPIFFE JWT-SVID対応(`federated-jwt`、Preview機能)**：使い捨てDockerコンテナ、次いでgekko_07の実クラスタ(本物のSPIRE Server/Agent・Keycloak)の両方で、client_secret無し・SPIRE発行の本物のJWT-SVIDだけでToken Exchangeが成立することを実機確認した。**採用。**

SPIRE Workload APIのworkload attestationは呼び出し元プロセス(Pod)に紐づくため、共有Podである`ext-authz-service`では呼び出し元自身のJWT-SVIDを取得できない。これはRFC 8705・Delegationモデルのいずれを選んでいても避けられない制約であり、**Token Exchange実行主体を「共有のext-authz-service」から「呼び出し元と同一Pod内のサイドカー」へ移す構造変更が不可避**という結論に至った。

## Decision

**fraud-mcp-server→account-service(パターン①)に限定して、以下を実施する。**

### Token Exchange実行主体をfraud-mcp-server自身のPod内サイドカーへ移す

共有の`ext-authz-service`Deployment(fraud-mcp-server専用インスタンス)を廃止し、同等のロジックを`k8s/fraud-mcp-server/`の新規`token-exchange`サイドカーコンテナへ移植した。fraud-mcp-serverのEnvoy(egress)の`ext_authz`フィルタは、リモートの`ext-authz-service.gekko.svc.cluster.local:8080`ではなく、同一Pod内の`127.0.0.1:9002`(plaintext loopback、`app_upstream`と同じ信頼境界)を呼ぶ。

### client_secretをSPIRE発行JWT-SVIDへ置き換える

`token-exchange`サイドカーは、Keycloakのトークンエンドポイントを呼ぶ際、`client_secret`の代わりに`client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe`＋`client_assertion=<自分のJWT-SVID>`を使う。これによりKeycloakが検証するmTLS接続の身元(SPIRE Workload APIから取得したJWT-SVIDが証明する`spiffe://gekko.internal/ns/gekko/sa/default/fraud-mcp-server`)と、主張するclient_idが一致するようになり、当初の目的(Keycloakが呼び出し元ワークロードの身元を直接検証できること)を達成する。

Keycloak側は`fraud-mcp-server`クライアントの`clientAuthenticatorType`を`client-secret`から`federated-jwt`に変更し、`identity-provider`(`providerId: spiffe`)を1つ追加した。`jwt.credential.issuer`/`jwt.credential.sub`属性で、どのSPIFFE IDを持つJWT-SVIDをこのクライアントとして受理するかを固定する。

### JWT-SVIDの取得方法：Kubernetes ImageVolumeで`spire-agent` CLIを直接マウントする

`ghcr.io/spiffe/spire-agent`イメージは完全にdistroless(シェルもcpも無い)で、initContainerでバイナリだけを取り出すことができなかった(実機確認済み)。SPIRE Workload API(gRPC)をPythonから直接叩く(`grpcio`+`pyspiffe`等の新規依存追加)代わりに、**Kubernetes 1.33+ Betaの`ImageVolume`機能**(`volumes[].image.reference`)でこのイメージ全体を読み取り専用マウントし、中の`spire-agent`バイナリをサブプロセス実行する方式を採った。gekko_07が使うk3s 1.35でこの機能が動作することは実機確認済み。新規Pythonパッケージ依存を増やさずに済み、既存の「stock image＋ConfigMapスクリプト」という流儀([ADR 0002](0002-token-exchange-in-envoy-sidecar.md))とも整合する。

### SPIRE Serverのbundle endpoint(federation機能)を有効化する

KeycloakがJWT-SVID署名検証鍵を含むtrust bundleを取得できるよう、`k8s/spire/server-configmap.yaml`に`federation.bundle_endpoint`(`profile "https_web"`)を追加した。このbundle endpoint自体のTLS終端用証明書は、SPIRE発行のSVIDやtrust bundleの中身とは無関係な、Makefileがopensslで生成する使い捨ての自己署名証明書(`.secrets/spire-bundle-endpoint.{crt,key}`)である。Keycloakはこの証明書を`KC_TRUSTSTORE_PATHS`で信頼する。

### SPIRE registration entry：1つのSPIFFE IDに複数entry

fraud-mcp-serverの`envoy`コンテナ(mTLS用のX.509-SVID)と`token-exchange`コンテナ(JWT-SVID)は、どちらも同じSPIFFE ID(`spiffe://gekko.internal/ns/gekko/sa/default/fraud-mcp-server`)を持つ必要があるが、1つのregistration entryのselectorはAND条件のため両コンテナをまとめて指定できない。同一SPIFFE IDに対し、`k8s:container-name`セレクタだけが異なる2つのentryを作成する構成にした(`k8s/spire/entries-configmap.yaml`)。appコンテナ自体は秘密鍵に一切触れないという原則([ADR 0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md))は変わらない(`token-exchange`もアプリ本体ではなくインフラ層のコンテナ)。

## Consequences

- fraud-mcp-server→account-serviceのToken Exchangeで、Keycloakが検証する身元(mTLS/JWT-SVID)と主張するclient_idが一致するようになった。ext-authz-serviceが呼び出し元のclient_secretを代理保持するという構造は、このホップに関しては解消された
- `ext-authz-service`(共有・fraud-mcp-server専用インスタンス)を廃止した。`ext-authz-service-cc`(fraud-detection-engine、client_credentials、パターン②)・`ext-authz-service-analyst`(account-service→analyst-attribute-service)は本ADRのスコープ外で、従来通りclient_secretを保持する共有インスタンスのまま残る。同じ身元検証ギャップが残っており、同じパターンの横展開をarchitecture.mdに記録する
- Keycloakの`spiffe`機能はKeycloakの成熟度区分で"Preview"(安定版ではない)。x509cert-lookup SPI同様、将来のKeycloakバージョンアップで破壊的変更を受ける可能性がある。関連するAdmin UI側の既知の未解決バグ(Issue #42634・#42044・#51682)もある
- Kubernetes `ImageVolume`機能(Beta)への依存が新たに生じた。この機能が無効化されたクラスタでは`spire-agent`バイナリの入手方法を再検討する必要がある
- fraud-mcp-server-clientのKubernetes Secret・Keycloak client_secretは不要になったため、関連するMakefile変数・test-fixtures.shの設定処理を削除した
- account-service→analyst-attribute-serviceホップ(先行して着手していたが、本ADRの方針転換を受けて一旦保留した)は、この新しいパターンが確立してから同じ形で作り直す方針とする
