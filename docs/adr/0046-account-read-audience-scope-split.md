# ADR 0046: `account:read`のaudienceマッパー共有を解消し、fraud-agent・fraud-mcp-server向けを専用scopeへ分離する

- **Status**: Partially superseded by [0047](0047-fraud-agent-scope-rename.md)（新設した`fraud-agent:chat`を`fraud-agent:read`へ改名。scope分離という決定自体・`fraud-mcp-server:read`は有効なまま）
- **Amends**: [0010](0010-egress-listener-granularity.md)・[0014](0014-fraud-agent-token-exchange.md)・[0023](0023-fraud-agent-fraud-mcp-server-hop.md)・[0024](0024-frontend-edge-proxy-and-simplified-login.md)（frontend→fraud-agent・fraud-agent→fraud-mcp-serverの2ホップで使うscope名を`account:read`から専用scopeへ変更）
- **Date**: 2026-09-24

## Context

[ADR 0014](0014-fraud-agent-token-exchange.md)は、frontend→fraud-agent・fraud-agent→fraud-mcp-server・fraud-mcp-server→account-serviceの3ホップで同名の`account:read`client scopeを共有する設計を採用した。この設計は「実際に発行されるトークンはToken Exchangeリクエストの`audience`パラメータで1つに絞り込まれ、単一audience原則（[ADR 0005](0005-single-audience-tokens-only.md)）は保たれる」（[insights.md](../insights.md) 2.3参照）という前提の上に成り立っていたが、Keycloakの`account:read`client scopeがaccount-service・fraud-agent・fraud-mcp-serverの3つの`oidc-audience-mapper`を持つため、**要求元クライアントが`account:read`さえ保有していれば、そのうちどのaudienceでもToken Exchangeを要求できてしまう**という監査ギャップが[ADR 0024](0024-frontend-edge-proxy-and-simplified-login.md)実装時に判明した。当時のverify-hop.sh自身がこの抜け道（frontendを名乗って直接`audience=fraud-mcp-server`を要求する）を使っていたことに気づき、frontend→fraud-agent→fraud-mcp-serverの実チェーン経由に置き換えて回避したが、Keycloak側の設定でこの経路自体を塞ぐことはせず、architecture.md §11に未決事項として残していた（各クライアントのtoken-exchangeサイドカーが正しいaudienceしか要求しないという実装側の自制に依存）。

この状態は、記事として提示している「AIエージェント（fraud-agent/fraud-mcp-server）がどれだけ逸脱を試みても、Keycloakの設定上構造的に凍結解除の実行権限を取得できない」という主張の一部（表1のDENY）が、実際にはKeycloakの強制ではなくアプリ実装の自制に留まっている、という完全性の欠落だった。

対応としてKeycloakのClient Policiesを導入する案も検討したが、以下の理由で採らない：

- Client Policiesの標準condition/executorには「このクライアントはこのaudienceしか要求できない」を直接表現する機能がなく、実現するにはカスタムSPIの実装が要る。本システムは新規可動部を増やさない方針（[docs/architecture.md](../architecture.md) §3.6・SPIRE関連の既存ADR群）を一貫して採ってきており、この方針と矛盾する
- 実際の抜け穴は「1つのclient scopeが複数audienceのマッパーを共有している」ことだけであり、[ADR 0040](0040-audit-service-reconciliation.md)がaudit-service向けの新規読み取り権限を`account:read`に混ぜず`account:audit`という専用scopeで新設したのと全く同じパターンを、既存の`account:read`にも適用すれば、新しい機構を足さずKeycloakの既存の許可判定だけで閉じられる

## Decision

### `account:read`のaudienceマッパーをaccount-service単独に縮小し、2つの専用scopeを新設する

[k8s/keycloak/realm-configmap.yaml](../../k8s/keycloak/realm-configmap.yaml)の`account:read`client scopeから`fraud-agent`・`fraud-mcp-server`向けの`oidc-audience-mapper`を削除し、account-service向けの1つだけを残した。代わりに、audienceごとに1マッパーだけを持つ専用scopeを2つ新設した：

- `fraud-agent:chat`（audience=fraud-agent）：frontendのみに付与〔[ADR 0047](0047-fraud-agent-scope-rename.md)で訂正：`fraud-agent:read`に改名〕
- `fraud-mcp-server:read`（audience=fraud-mcp-server）：fraud-agentのみに付与

frontendの`optionalClientScopes`に`fraud-agent:chat`を追加し〔[ADR 0047](0047-fraud-agent-scope-rename.md)で訂正：`fraud-agent:read`に改名〕、fraud-agentの`optionalClientScopes`は`account:read`から`fraud-mcp-server:read`に置き換えた。fraud-mcp-serverの`optionalClientScopes`（`account:read`・`account:propose`）は変更していない（account-service向けの`account:read`マッパーはそのまま残るため）。

これにより、[insights.md](../insights.md) 2.3節が明文化していた「Standard Token Exchange V2は、要求元クライアントに割り当てられたclient scopeが対象audienceを指す`oidc-audience-mapper`を持っていない限りそのaudienceを解決できない」という既存の実機知見どおり、frontendが`audience=fraud-mcp-server`を要求してもKeycloakが`{"error":"invalid_request","error_description":"Requested audience not available: fraud-mcp-server"}`で拒否するようになった（後述の実機検証で確認）。

### 各サービスのscope解決ロジック・Envoy ingress RBACを追随させる

- [k8s/frontend/token-exchange-app-configmap.yaml](../../k8s/frontend/token-exchange-app-configmap.yaml)のSCOPE_RULES：`(fraud-agent, POST /chat)`の解決先scopeを`account:read`から`fraud-agent:chat`に変更した〔[ADR 0047](0047-fraud-agent-scope-rename.md)で訂正：`fraud-agent:read`に改名〕
- [k8s/fraud-agent/deployment.yaml](../../k8s/fraud-agent/deployment.yaml)・[k8s/fraud-agent/token-exchange-app-configmap.yaml](../../k8s/fraud-agent/token-exchange-app-configmap.yaml)：`FIXED_SCOPE`を`account:read`から`fraud-mcp-server:read`に変更した
- [k8s/fraud-agent/envoy-configmap.yaml](../../k8s/fraud-agent/envoy-configmap.yaml)：ingress rbacの`x-auth-scope`一致条件を`account:read`から`fraud-agent:chat`に変更した（frontend→fraud-agentホップの受信側検証）〔[ADR 0047](0047-fraud-agent-scope-rename.md)で訂正：`fraud-agent:read`に改名〕
- [k8s/fraud-mcp-server/envoy-configmap.yaml](../../k8s/fraud-mcp-server/envoy-configmap.yaml)：ingress rbacの`x-auth-scope`一致条件を`account:read`から`fraud-mcp-server:read`に変更した（fraud-agent→fraud-mcp-serverホップの受信側検証）

fraud-mcp-server→account-serviceホップ（scope=`account:read`または`account:propose`）は無変更。

### 過去のAccepted ADRへの`Amends`

本ADRは、[ADR 0014](0014-fraud-agent-token-exchange.md)のDecisionが定めた「`account:read`を3audience共有スコープとして拡張する」という決定そのものを覆す。また[ADR 0010](0010-egress-listener-granularity.md)・[ADR 0023](0023-fraud-agent-fraud-mcp-server-hop.md)・[ADR 0024](0024-frontend-edge-proxy-and-simplified-login.md)のDecision本文が、この2ホップのscope名を`account:read`と明記している箇所にも影響するため、CLAUDE.mdの「ADR運用ルール」に従い、該当4件のStatus行更新・本文への訂正注記・[README.md](README.md)索引の更新を同じコミットで行う。いずれの本文（Context/Decision）もこの訂正注記の追加以外は書き換えていない。

### 実機検証

`make keycloak-reimport-realm`でrealm設定を反映し、frontend/fraud-agent/fraud-mcp-serverを再起動した上で、`scripts/verify-hop.sh`のステップ1a・1bで新しいscope名（`fraud-agent:chat`・`fraud-mcp-server:read`）による正常系のToken Exchangeが成功することを確認した。〔[ADR 0047](0047-fraud-agent-scope-rename.md)で訂正：`fraud-agent:chat`はさらに`fraud-agent:read`に改名〕

加えて、本ADRが解消を主張する監査ギャップそのものを実機で反証する回帰テストをステップ1cとして追加した：frontend自身のtoken-exchangeサイドカーの`resolve_scope`（SCOPE_RULES）を経由せず、`exchange_token()`を直接呼び出してKeycloakへ`client_id=frontend, audience=fraud-mcp-server, scope=account:read`の生のToken Exchangeリクエストを送る（[ADR 0024](0024-frontend-edge-proxy-and-simplified-login.md)当時の抜け道と同じ形）。修正前はこれが成功してしまう既知の状態だったが、修正後はKeycloakが`{"error":"invalid_request","error_description":"Requested audience not available: fraud-mcp-server"}`で拒否することを確認した。これにより、表1のDENYがアプリ実装の自制ではなくKeycloakの設定そのもので強制されるようになったことを実機で示せた。

## Consequences

- architecture.md §11の「`account:read`スコープのaudience監査ギャップ」は解消したため、該当項目を削除した。§3.2（Keycloak側の前提）・§3.3（表1のホップ一覧）・§4（クライアント・スコープ設計表）・表1の脚注・表2「どのトークンがどのスコープを保有するか」・§10のUC1シーケンス図と手順を、新しいscope名（`fraud-agent:chat`・`fraud-mcp-server:read`）に合わせて更新した〔[ADR 0047](0047-fraud-agent-scope-rename.md)で訂正：`fraud-agent:chat`はさらに`fraud-agent:read`に改名〕
- [services.md](../services.md)のfrontend・fraud-agentの記述（scope=account:readとしていた箇所）も更新した
- [insights.md](../insights.md) 2.3節「`account:read`のaudienceマッパー共有スコープは、requesting client側でaudienceを技術的に制限しない」の対応欄に、本ADRで解消した旨を追記した（症状・原因の記述自体は履歴として保持）
- `scripts/verify-hop.sh`に、この監査ギャップが実際に塞がっていることを示す回帰テスト（ステップ1c）が恒久的に追加された。今後同じ理由で別のscopeを複数audienceに共有させたくなった場合、同種の負のテストを追加することが望ましい
- `account:read`は今後account-service向け専用のscopeという扱いに一本化された。新しい委任関係を追加する際は、[ADR 0040](0040-audit-service-reconciliation.md)・本ADRと同じく「1つのclient scopeには1つのaudienceマッパーのみを持たせる」ことを既定とし、複数audienceでの共有は監査ギャップを生むため避ける
