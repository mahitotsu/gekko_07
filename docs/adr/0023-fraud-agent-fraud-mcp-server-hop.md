# ADR 0023: fraud-agentを新規実装し、fraud-mcp-serverのingressを活性化する

- **Status**: Accepted
- **Date**: 2026-09-17

## Context

`docs/backlog.md`の「frontend方向への横展開」は、ADR 0019〜0021で確立した「呼び出し元自身のPod内Envoyサイドカー＋SPIRE発行JWT-SVIDクライアント認証」パターンを、残りのホップ（frontend→account-service、frontend→fraud-agent、fraud-agent→fraud-mcp-server）へ展開する項目だが、frontend/fraud-agentの両方が未実装であることを理由に着手できずにいた。

frontendはブラウザ向けOIDCフロー・edge-proxyルーティング変更・`directAccessGrantsEnabled`後始末など決定事項が多く単独でも大きいため、先にスコープの小さい**fraud-agent**（ingress+egressの単一固定スコープ構成で、account-serviceの構造にほぼそのまま倣える）に着手し、frontend実装（別途）の土台を作ることにした。

`k8s/fraud-mcp-server/`は当初からegress専用スタブとして存在していたが、app.py・handshake initContainer・SPIRE UDSマウント等ingressに必要な要素はコメント付きで先回りして用意されていた（「このホップの検証ではfraud-mcp-server自身への着信(ingress)は使わないが、Pod構成の一貫性と将来のingress検証のために同居させる」）。今回追加するのはEnvoyのingressリスナー・Service・NetworkPolicyのingress許可の3点のみで、アプリ/handshakeロジックの変更は不要だった。

Keycloakの`fraud-agent`クライアント定義は、ADR 0019〜0021が既存サービスに後付けで塞いだ「身元検証ギャップ」（Keycloakが検証する身元＝mTLS/JWT-SVIDと、クライアントが主張するclient_idの不一致）を最初から抱えていなかった——単に`clientAuthenticatorType`が未設定（`client_secret`前提）のままだった。account-serviceがADR 0021で「表3は最初からこの形で実装」としたのと同じ考え方で、fraud-agentも中間ステップを経由せず最初から`federated-jwt`で実装する。

## Decision

### fraud-agentを新規実装する(ingress+egress両方)

`k8s/fraud-agent/`に、account-service（ingress+egress両方を持つ唯一の既存サービス。表3導入前のADR 0021参照）と同型のPod構成（initContainer＋app＋Envoy＋token-exchange）を新設した。

- ingress：`jwt_authn`（`audiences: ["fraud-agent"]`）→`rbac`（`account:read`保有のみを要求する単一ワイルドカードルート。analyst-attribute-serviceのingressと同じ簡略化）→`lua`（合言葉注入）→`router`。mTLS呼び出し元はfrontendのみに制限（frontend自体は未実装のため、実際にこの制限を満たす呼び出し元は現時点で存在しない）
- egress：`token-exchange`サイドカーが`FIXED_SCOPE=account:read`でfraud-mcp-server向けToken Exchangeを実行する（fraud-mcp-serverはscopeがpathによらず1つだけのホップのため、fraud-mcp-server→account-serviceのようなpath/methodからscopeを解決する対応表は不要）

Keycloak側は`fraud-agent`クライアントに`clientAuthenticatorType: federated-jwt`と`jwt.credential.issuer`/`jwt.credential.sub`属性を追加した。`standard.token.exchange.enabled`・`optionalClientScopes: ["account:read"]`は変更していない。

### fraud-mcp-serverのingressを活性化する

`k8s/fraud-mcp-server/envoy-configmap.yaml`にingressリスナー（analyst-attribute-serviceのingressと同型：単一固定scope`account:read`、呼び出し元をfraud-agentのみに制限）を追加し、既存のegressリスナーと同じEnvoyプロセスに同居させた。Service（`k8s/fraud-mcp-server/service.yaml`、これまで存在しなかった）とNetworkPolicyのingress許可（`app: fraud-agent`から8080）も新規追加した。アプリ本体（app-configmap.yaml）は変更していない——先行して用意されていたスタブロジックがそのまま使われる形になった。

fraud-mcp-serverはaccount-serviceに続き、ingress/egress両方のリスナーを持つ2番目のサービスになった。

### Keycloak自身の許可リストにfraud-agentを追加する

fraud-agentのtoken-exchangeサイドカーは自身でKeycloakへ直接mTLS接続する（fraud-mcp-server/fraud-detection-engine/account-serviceと同じ構成）。`k8s/keycloak/envoy-configmap.yaml`のmTLS SAN許可リスト（`match_typed_subject_alt_names`）と`k8s/keycloak/networkpolicy.yaml`のingress許可の両方に`fraud-agent`のSPIFFE IDを追加した。ADR 0021の教訓（許可リストの更新漏れは`SSLV3_ALERT_CERTIFICATE_UNKNOWN`で検出できる）に基づき、新規実装なので最初から正しい値で作成した。

### SPIRE registration entry

fraud-agentの`envoy`コンテナ（mTLS用のX.509-SVID）と`token-exchange`コンテナ（JWT-SVID）は同じSPIFFE ID（`spiffe://gekko.internal/ns/gekko/sa/default/fraud-agent`）を持つ必要があるため、ADR 0019/0020/0021と同じく`k8s:container-name`セレクタだけが異なる2つのentryを作成した。

### frontend→fraud-agentのingress側は今回検証できない

frontend自体が未実装のため、fraud-agentのingress（mTLS+jwt_authn+rbac+合言葉）を実際に通過する呼び出し元は存在しない。これはADR 0014のConsequencesで既に「frontend/fraud-agent双方が未実装のため、frontend→fraud-agentホップの実機検証はどちらか（または両方）の実装着手時まで行えない」と明記されていた制約であり、新たに発生したギャップではない。

`scripts/verify-hop.sh`には、frontend代役のToken Exchange（Keycloakへ直接、audience=fraud-agent、scope=account:read）取得後、fraud-agent-stub Pod内のappコンテナへ**ingressを経由せず**直接Authorizationヘッダー付きでリクエストし、fraud-agent自身のegress（Token Exchange）→fraud-mcp-serverのingress、という後半の実装を検証するステップを追加した。この方法は、mTLS/jwt_authn/rbacを通過したかのようにアプリ層のみを単体で駆動するものであり、fraud-agent自身のingress側の実機検証（mTLSでのSPIFFE ID制限・JWT署名検証・scope RBAC）はfrontend実装まで持ち越しとなる。

## Consequences

- fraud-agent→fraud-mcp-serverのToken Exchangeで、Keycloakが検証する身元（JWT-SVID）と主張するclient_idが一致する構成を最初から実装できた。`ext-authz-service`のような共有インスタンス方式を経由する中間ステップは発生しなかった
- `docs/backlog.md`の「frontend方向への横展開」のうち、fraud-agent→fraud-mcp-serverホップ分は解消した。残るfrontend→account-service・frontend→fraud-agentはfrontend実装まで持ち越し
- fraud-mcp-serverはaccount-serviceに続き、ingress/egress両方のリスナーを持つ2番目のサービスになった
- fraud-agent自身のingress（frontend→fraud-agent）の実機検証はfrontend実装まで持ち越し。frontend実装時に、`scripts/verify-hop.sh`のステップ15〜16をfrontendの実際のToken ExchangeとfraudエージェントServiceへの実呼び出し（mTLS込み）に置き換える必要がある
- `scripts/verify-hop.sh`に新規ステップを追加し、既存ステップとあわせて全ステップが成功することを確認した
