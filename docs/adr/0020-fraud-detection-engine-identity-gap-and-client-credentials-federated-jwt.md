# ADR 0020: fraud-detection-engineの身元検証ギャップを解消し、client_credentialsグラントもSPIFFE JWT-SVIDクライアント認証へ移行する

- **Status**: Accepted
- **Date**: 2026-09-17

## Context

[ADR 0019](0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)は、fraud-mcp-server→account-service(パターン①、Token Exchange)に限定して、共有`ext-authz-service`が抱えていた身元検証ギャップ(Keycloakが検証するmTLS身元と主張するclient_idの不一致)を解消した。同ADRのConsequencesで明記した通り、`ext-authz-service-cc`(fraud-detection-engine、client_credentials、パターン②、[ADR 0010](0010-token-exchange-multi-caller-generalization.md))は同じギャップを抱えたまま残されていた。

ADR 0019のTokenExchangeでの検証はKeycloakの`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`に対して行ったもので、`grant_type=client_credentials`でも同じクライアント認証機構(`federated-jwt`、`client_assertion_type=...jwt-spiffe`)が使えるかは実機未検証のままdocs/backlog.mdに記録していた(OAuth 2.0のクライアント認証はRFC 6749上grant_typeとは独立した関心事のため理屈上は通るはずだが、Keycloak実装がその通りかは別問題)。

## Decision

**fraud-detection-engine→account-service(パターン②)に、ADR 0019と同じ是正パターンを適用する。**

### client_credentialsトークン取得実行主体をfraud-detection-engine自身のPod内サイドカーへ移す

共有の`ext-authz-service-cc`Deploymentを廃止し、同等のロジックを`k8s/fraud-detection-engine/`の新規`client-credentials`サイドカーコンテナへ移植した(ADR 0019の`token-exchange`サイドカーと同型)。fraud-detection-engineのEnvoy(egress)の`ext_authz`フィルタは、リモートの`ext-authz-service-cc.gekko.svc.cluster.local:8080`ではなく、同一Pod内の`127.0.0.1:9002`(plaintext loopback)を呼ぶ。

### client_secretをSPIRE発行JWT-SVIDへ置き換える

`client-credentials`サイドカーは、Keycloakのトークンエンドポイントを呼ぶ際、`client_secret`の代わりに`client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe`＋`client_assertion=<自分のJWT-SVID>`を使う。**`grant_type=client_credentials`でも`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`と全く同じクライアント認証機構がそのまま使えることを実機確認した**(gekko_07の実クラスタで`scripts/verify-hop.sh`のパターン②検証が200を返すことで確認。docs/backlog.mdの「実機未検証」事項を解消)。Keycloak側は`fraud-detection-engine`クライアントの`clientAuthenticatorType`を`client-secret`から`federated-jwt`に変更し、`jwt.credential.issuer`/`jwt.credential.sub`属性を追加した(`identity-provider`自体はADR 0019で追加済みの`spire-gekko`を共用する)。

### SPIRE registration entry・Keycloak Envoyの許可リストも同じパターンで更新する

fraud-detection-engineの`envoy`コンテナ(mTLS用のX.509-SVID)と`client-credentials`コンテナ(JWT-SVID)は同じSPIFFE ID(`spiffe://gekko.internal/ns/gekko/sa/default/fraud-detection-engine`)を持つ必要があるため、ADR 0019と同じく`k8s:container-name`セレクタだけが異なる2つのentryを作成した(`k8s/spire/entries-configmap.yaml`)。KeycloakのEnvoy(`k8s/keycloak/envoy-configmap.yaml`)がmTLS接続を許可するSPIFFE ID許可リストも、`ext-authz-service-cc`から`fraud-detection-engine`へ差し替えた。

移行作業中、この許可リスト差し替え漏れにより`SSLV3_ALERT_CERTIFICATE_UNKNOWN`(Keycloak側Envoyが未知のクライアント証明書を拒否)で`client-credentials`サイドカーのトークン取得が失敗する現象を実機で確認した。SPIRE registration entry・Envoy許可リスト・Keycloakクライアント属性の3箇所が揃って初めて成立する構成であり、いずれか1つでも旧`ext-authz-service-cc`のSPIFFE IDのままだと失敗することが分かった。

## Consequences

- fraud-detection-engine→account-serviceのclient_credentialsで、Keycloakが検証する身元(mTLS/JWT-SVID)と主張するclient_idが一致するようになった
- `ext-authz-service-cc`を廃止した。これにより共有`ext-authz-service`インスタンス方式(ADR 0002/0016)は全て廃止され、`k8s/ext-authz/`ディレクトリの追跡対象ファイルは無くなった。`ext-authz-service-analyst`(account-service→analyst-attribute-service)のみ同じギャップを抱えたまま未着手で残っており、backlog.mdに記録した
- client_credentialsグラントでも`federated-jwt`によるクライアント認証がそのまま使えることを実機確認した。account-service→analyst-attribute-serviceホップ(Token Exchange)を作り直す際、同じ実装パターンをそのまま踏襲できる根拠になる
- fraud-detection-engine-clientのKubernetes Secret・Keycloak client_secretは不要になったため、関連するMakefile変数・test-fixtures.shの設定処理を削除した
