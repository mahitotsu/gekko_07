# ADR 0024: frontendを新規実装し、edge-proxy配線・簡易ログインでaccount-service/fraud-agentへ横展開する

- **Status**: Partially superseded by [0031](0031-frontend-implementation.md)
- **Date**: 2026-09-17

## Context

fraud-agent実装（[ADR 0023](0023-fraud-agent-fraud-mcp-server-hop.md)）で`docs/backlog.md`の「frontend方向への横展開」のうちfraud-agent→fraud-mcp-serverホップは解消したが、frontend自体が未実装のため、frontend→account-service・frontend→fraud-agentは着手できずにいた。またADR 0023はfraud-agent自身のingress側（frontend→fraud-agent）の実機検証を「frontend実装まで持ち越し」としていた（[ADR 0014](0014-fraud-agent-token-exchange.md) Consequences由来の制約）。

frontendは他5サービスと異なり、SPIFFE mTLSを持てないブラウザが実際の呼び出し元になる唯一のサービスであり、[ADR 0017](0017-edge-proxy-full-keycloak-mtls.md)のedge-proxyが「frontend実装時にroute_configへ追加する」と想定していたピースでもある。

ユーザーと相談の上、スコープを次の3案の中間に決定した：pod-exec直叩きのみ（案A、最小）、**edge-proxy配線＋簡易ログイン（採用）**、本物のAuthorization Code+PKCEブラウザフロー（案C、最大）。手戻りリスクについても確認済み：Envoy sidecar構成・SPIRE ID・Keycloakクライアント定義・NetworkPolicy・edge-proxyルーティングは他5サービスと同じく本実装でも流用される。手戻りが生じるのは「app.pyという薄いスタブ業務ロジック」と「`/login`（ROPCの代用）という、本物のPKCEに置き換わった時点で丸ごと捨てる部分」に限られる。

## Decision

### frontendを新規実装する(ingress+egress両方)

`k8s/frontend/`に、account-service・fraud-agentと同型のPod構成（initContainer＋app＋Envoy＋token-exchange）を新設した。他サービスと異なる点は以下2点：

1. **ingressの呼び出し元はedge-proxy（mTLS）であり、jwt_authnは`/login`パスのみ免除する**。`/login`はログイン前で当然トークンを持たないため、jwt_authnの`rules`に`{match: {path: "/login"}}`（要件なし）を`{match: {prefix: "/"}, requires: {provider_name: keycloak}}`より先に置いた。rbacフィルタは付けない——ログイントークンはscopeをほとんど持たないため、scopeによる差別化はここでは行わず、実際の認可はaccount-service/fraud-agent側の受け側で行う
2. **ADR 0002の原則（appはKeycloakと直接通信しない）をログインにも一貫適用する**。`/login`はappからtoken-exchangeサイドカー（127.0.0.1:9002）への単純なリレーで、ROPC（`grant_type=password`）の実行とSPIRE JWT-SVIDの取り扱いはサイドカーの責務。サイドカーは同じHTTPサーバーで、Envoyのegress ext_authzからのcheck-request（`do_check`、account-service/fraud-agentへのToken Exchange）と、appからの直接POST（`do_login`、ROPCログイン）の両方を扱う

egressはaccount-service・fraud-agentの2つの実サービスへhostAliasesで横取りする。token-exchangeサイドカーはfraud-mcp-serverのSCOPE_RULES方式（[ADR 0019](0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)）を踏襲しつつ、frontendは2つの異なるaudienceへ委任するため、解決キーに`host`を加えた：`(account-service, GET /accounts/**) → account:read`、`(account-service, POST /accounts/{id}/unfreeze) → account:unfreeze`、`(fraud-agent, POST /chat) → account:read`。

Keycloakの`frontend`クライアントは`clientAuthenticatorType: federated-jwt`へ変更し、`jwt.credential.issuer`/`jwt.credential.sub`を追加した（fraud-mcp-server/fraud-detection-engine/account-service/fraud-agentと同じパターン）。`directAccessGrantsEnabled`はrealm-configmap.yamlで直接`true`にして恒久化した（従来`k8s/keycloak/test-fixtures-configmap.yaml`が一時的に`kcadm update`していたものを、簡易ログインの実装そのものとして正式採用。`FRONTEND_CLIENT_SECRET`は不要になり、Makefile/test-fixtures/verify-hop.shから削除した）。

### account-serviceに`unfreeze` rbacポリシーを追加する

account-serviceのingressには`read`/`propose`/`freeze`ポリシーしか無く、`account:unfreeze`のポリシーが存在しないことが判明した（確定パスの呼び出し元がこれまで存在しなかったため）。frontendが最初の呼び出し元になるため、`POST /accounts/{id}/unfreeze` + `x-auth-scope contains account:unfreeze`のポリシーを追加した。mTLS SAN許可リスト・NetworkPolicyにもfrontendを追加した。

### edge-proxyのroute_configをパスベースで分割する

`k8s/edge-proxy/envoy-configmap.yaml`のroute_configを、`/realms/`prefix（Keycloakの全OIDCエンドポイント。ROPC・Token Exchange・将来のAuthorization Codeフローもすべてこの配下）→`keycloak_upstream`、それ以外（`/`）→新設の`frontend_upstream`（mTLS、SAN=frontend）に分割した。Envoyのroute matchは列挙順で最初にマッチしたものが勝つため、`/realms/`を先に置く必要がある。現状edge-proxy経由の呼び出しは`/realms/...`（kcadm.shはPod内へkubectl execで直接到達するため対象外）とfrontendの2系統のみのため、この分割は既存動作に影響しなかった（実機で確認済み）。edge-proxy自身のDeployment/Service/NetworkPolicy（フロントエンドへのegress追加を除く）は変更していない。

### Keycloakの許可リストにfrontendを追加する

frontendのtoken-exchangeサイドカーは自身でKeycloakへ直接mTLS接続する（ログイン・Token Exchange両方）。`k8s/keycloak/envoy-configmap.yaml`のSAN許可リストと`k8s/keycloak/networkpolicy.yaml`のingressにfrontendを追加した。

### SPIRE registration entry

frontendの`envoy`コンテナと`token-exchange`コンテナは同じSPIFFE ID（`spiffe://gekko.internal/ns/gekko/sa/default/frontend`）を持つ必要があるため、ADR 0019/0020/0021/0023と同じく2つのentryを作成した。

### verify-hop.shの全面更新

frontend/fraud-agentが共に`client_secret`ではなく`federated-jwt`になったため、クラスタ外から`client_id`+`client_secret`でこれらを名乗ってKeycloakを直接叩く手段が無くなった（以前はこれで「frontendが将来行う処理」を代用していた）。これにより、以下を実際のfrontendエンドポイント経由に置き換えた：

- ログイン：`$EDGE/login`（旧：Keycloakへ直接ROPC）
- account-serviceへの読み取り・確定操作：`$EDGE/accounts/{id}/transactions`（GET）・`$EDGE/accounts/{id}/unfreeze`（POST）（新規。account-serviceの新設unfreezeポリシーもここで検証される）
- fraud-agentへのチャット開始：`$EDGE/chat`（POST）（旧：fraud-agent-stub Podへの直接pod-exec呼び出しで代用）

一方、パターン①（fraud-mcp-server→account-service）が使う個別トークン（`aud=fraud-mcp-server`）は、table 1（access-control-design.md）ではfrontendに許可されていない（frontend→fraud-mcp-serverの直接exchangeはDENY）。旧verify-hop.shはこれを無視してfrontend役に直接exchangeさせていたが、これは意図しない抜け道だった（Keycloakの`account:read`スコープが3つのaudienceマッパーを共有しているため、技術的には成功してしまっていた。table 1のDENYはKeycloak側の強制ではなく、各クライアントの実装が要求するaudienceを自制することに依存している）。今回、`frontend→fraud-agent→fraud-mcp-server`という実チェーンを、各サービス自身のtoken-exchangeサイドカーへ直接（Envoyが送るのと同じ形で）リクエストして正しいトークンを取得する方式に置き換え、この抜け道を使わなくなった。

## Consequences

- frontend→account-service（読み取り・確定パス両方）・frontend→fraud-agentのToken Exchangeが実機で検証された。`docs/backlog.md`の「frontend方向への横展開」は完全に解消した
- ADR 0023が「frontend実装まで検証できない」としていたfraud-agent自身のingress（mTLS+jwt_authn+rbac+合言葉）が、実際のfrontendから初めて実機検証された
- account-serviceの`unfreeze` rbacポリシー欠落という既存の抜けを発見・是正した
- Keycloakの`account:read`スコープの監査ギャップ（audienceパラメータを技術的に自由に選べる）が判明した。Client Policiesを使わない設計（architecture.md §4）の下では、これは各クライアント実装（token-exchangeサイドカーのSCOPE_RULES）の自制に依存する。今のところ全クライアントのサイドカーは正しいaudienceしか要求しないためリスクは顕在化していないが、将来的な懸念としてinsights.mdに記録した
- 簡易ログイン（`/login`、ROPC）と`directAccessGrantsEnabled=true`の恒久化は、本物のAuthorization Code+PKCEブラウザフローに置き換わる時点で丸ごと捨てる想定の暫定実装。Cookieによるセッション管理（services.md記載）も引き続き未実装
  - **[0031](0031-frontend-implementation.md)で置き換え済み**：ROPC・`directAccessGrantsEnabled=true`・frontend ingressのjwt_authnは0031で撤去し、Authorization Code+PKCE・暗号化Cookieセッション・RP-Initiated Logoutへ置き換えた。edge-proxy配線・Token Exchangeのscope解決方式・account-serviceのunfreeze rbacポリシーは本ADRのまま有効
- `scripts/verify-hop.sh`を全面更新し、frontend/fraud-agent/fraud-mcp-server/account-service/analyst-attribute-serviceを含む全区間で新規ステップが成功することを確認した
