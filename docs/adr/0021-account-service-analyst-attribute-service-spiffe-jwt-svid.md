# ADR 0021: account-service→analyst-attribute-service(表3)をSPIFFE JWT-SVIDクライアント認証で実装する

- **Status**: Accepted
- **Date**: 2026-09-17

## Context

account-service→analyst-attribute-service(表3、Token Exchange)は先行して着手していたが、当時は共有`ext-authz-service-analyst`がaccount-serviceのclient_secretを保持して代理でToken Exchangeを行うという、[ADR 0019](0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)が指摘したのと同じ身元検証ギャップを抱える設計だった。ADR 0019の方針転換を受けてこの作業は一旦保留し(`k8s/analyst-attribute-service/`・`k8s/ext-authz/*-analyst.yaml`は未コミットのまま作業ツリーに残した)、新しいパターンが確立してから作り直す方針とした([ADR 0019](0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md) Consequences参照)。

ADR 0019(Token Exchange)・[ADR 0020](0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)(client_credentials)で、KeycloakネイティブのSPIFFE JWT-SVID対応(`federated-jwt`)が2つのグラントタイプで実機確認済みとなり、account-serviceはfraud-mcp-server(ADR 0019)と全く同じToken Exchangeグラントを使うホップであるため、追加のスパイクは不要と判断した。analyst-attribute-service自体は本実装が未着手のため、旧方式の`ext-authz-service-analyst`のような中間ステップを経由せず、**最初からSPIFFE JWT-SVIDクライアント認証で実装する**。

## Decision

### analyst-attribute-serviceを新規実装する(ingress側)

`k8s/analyst-attribute-service/`に、account-service自身のingress Envoy設定(jwt_authn/rbac/合言葉、[ADR 0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md))と同型のPod(initContainer＋app＋Envoy)を新設した。委任チェーンの終端(表3:account-serviceからのみ照会される)のため、account-serviceと異なりegressリスナー・hostAliasesは持たない。Keycloakには`clientAuthenticatorType`を指定しない標準クライアント(`analyst-attribute-service`)を作成した——このクライアントはKeycloakへ自分から認証済みリクエストを送ることが無く(audienceとして名指しされるだけ)、client_secretや`federated-jwt`属性はそもそも不要。

### account-serviceに新規Token Exchange実行主体を追加する(egress側)

account-serviceは、ADR 0019のfraud-mcp-serverと同じ構成で、自身のPod内に`token-exchange`サイドカーコンテナを追加した(`k8s/account-service/token-exchange-app-configmap.yaml`。`k8s/fraud-mcp-server/token-exchange-app-configmap.yaml`から分岐・移植し、CLIENT_ID/FIXED_SCOPEのみ差し替え)。account-serviceは1ホップ先行検証で初めて**ingress(fraud-mcp-server/fraud-detection-engineから)とegress(analyst-attribute-serviceへ)の両方を持つサービス**になった。既存のingress用Envoyリスナー(0.0.0.0:8080)に加え、fraud-mcp-serverと同じ構造のegressリスナー(127.0.0.1:80、hostAliasesで"analyst-attribute-service"・"keycloak"を横取り)を同じEnvoyプロセスへ追加した。

Keycloak側は`account-service`クライアントの`clientAuthenticatorType`を`client-secret`から`federated-jwt`に変更し、`jwt.credential.issuer`/`jwt.credential.sub`属性を追加した。`standard.token.exchange.enabled`・`optionalClientScopes: ["analyst:read"]`は変更していない(account-serviceは元々このscopeを持っていた)。

### 移行手順は不要、Envoy許可リスト・NetworkPolicyは最初から正しい値で作成する

fraud-mcp-server(ADR 0019)・fraud-detection-engine(ADR 0020)は既存の`client-secret`方式から移行したため、`ext-authz-service(-cc)`のSPIFFE IDをKeycloakのEnvoy許可リスト・NetworkPolicyへ一時的に残したまま切り替えるという手順を踏んだが、account-service→analyst-attribute-serviceは新規実装のため、Keycloakの許可リスト(`k8s/keycloak/envoy-configmap.yaml`のmatch_typed_subject_alt_names・`k8s/keycloak/networkpolicy.yaml`のingress)に`account-service`・`analyst-attribute-service`のSPIFFE IDを最初から追加すればよい。ADR 0020で実機確認した「許可リストの更新漏れは`SSLV3_ALERT_CERTIFICATE_UNKNOWN`で検出できる」という知見が活きた。

### SPIRE registration entry

account-serviceの`envoy`コンテナ(mTLS用のX.509-SVID)と`token-exchange`コンテナ(JWT-SVID)は同じSPIFFE ID(`spiffe://gekko.internal/ns/gekko/sa/default/account-service`)を持つ必要があるため、ADR 0019/0020と同じく`k8s:container-name`セレクタだけが異なる2つのentryを作成した。analyst-attribute-serviceは`envoy`コンテナのみの単一entry(他のサービスの初期実装と同型)。

## Consequences

- account-service→analyst-attribute-serviceのToken Exchangeで、Keycloakが検証する身元(mTLS/JWT-SVID)と主張するclient_idが一致するようになった。共有`ext-authz-service`インスタンス方式を経由することなく、最初から新パターンで実装できた
- `docs/backlog.md`に残っていた「ext-authz-service-analystの身元検証ギャップ」は解消した。ADR 0002/0016由来の共有ext-authz-serviceインスタンス方式は、fraud-mcp-server(ADR 0019)・fraud-detection-engine(ADR 0020)・account-service(本ADR)の全ホップで置き換えが完了した
- account-serviceはingress/egress両方のリスナーを持つ初めてのサービスになった。1つのEnvoyプロセスに複数の責務(着信の認可・発信の委任)を持たせる構成が実機で問題なく動作することを確認した
- `scripts/verify-hop.sh`にパターン③(account-service→analyst-attribute-service)の検証ステップを追加し、全14ステップが成功することを確認した
