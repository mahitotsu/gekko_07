# ADR 0047: frontend→fraud-agent向けscope`fraud-agent:chat`を`fraud-agent:read`へ改名する

- **Status**: Accepted
- **Amends**: [0046](0046-account-read-audience-scope-split.md)（新設した`fraud-agent:chat`のscope名を`fraud-agent:read`へ改名。scope分離という決定自体・`fraud-mcp-server:read`は変更しない）
- **Date**: 2026-09-24

## Context

[ADR 0046](0046-account-read-audience-scope-split.md)で`account:read`のaudienceマッパー共有を解消し、frontend→fraud-agentホップ向けに`fraud-agent:chat`、fraud-agent→fraud-mcp-serverホップ向けに`fraud-mcp-server:read`という2つの専用scopeを新設した。

このうち`fraud-mcp-server:read`は、既存のscope命名規則（`account:read`・`account:propose`・`account:freeze`・`account:unfreeze`・`account:audit`・`analyst:read`・`audit:read`のいずれも「対象リソースドメイン（≒対象audienceの核となる名詞）:操作カテゴリ」という形）にそのまま従っている。一方`fraud-agent:chat`は、動詞部分がアクセス制御上の操作カテゴリ（read/propose/freeze/unfreeze/audit）ではなく、実際に呼び出すAPI名（`POST /chat`）に由来するアプリケーション層の言葉になっており、他のscopeと型が揃っていない。

実害はない（Keycloakの許可判定はscope名の文字列一致だけを見るため、命名規則からの逸脱そのものはセキュリティ上の問題を生まない）が、以下の理由でこの段階での修正が妥当と判断した：

- architecture.md §4のスコープ一覧表（今後、続編記事等でより詳しい一覧を作る際の土台になる）で、AIエージェント経由の委任チェーン3ホップ（frontend→fraud-agent、fraud-agent→fraud-mcp-server、fraud-mcp-server→account-service）が`fraud-agent:read`・`fraud-mcp-server:read`・`account:read`と全て`:read`で揃うことで、「AIエージェントはどのホップを通じても読み取り権限しか持たない」という本システムの中核的な設計意図（表1・[ADR 0014](0014-fraud-agent-token-exchange.md)）が、スコープ名の並びだけからも読み取れるようになる
- [ADR 0046](0046-account-read-audience-scope-split.md)がまだ他のいかなる文書・実装からも安定した既存の外部名として参照される前（導入直後）の段階であり、改名のコストが最も低いタイミングである

## Decision

### `fraud-agent:chat`を`fraud-agent:read`へ改名する

[k8s/keycloak/realm-configmap.yaml](../../k8s/keycloak/realm-configmap.yaml)のclientScope名を`fraud-agent:chat`から`fraud-agent:read`に変更した（`oidc-audience-mapper`の設定・付与先クライアント（frontendのみ）は無変更）。

以下、scope名の変更に伴い追随させた箇所：

- [k8s/frontend/token-exchange-app-configmap.yaml](../../k8s/frontend/token-exchange-app-configmap.yaml)のSCOPE_RULES：`(fraud-agent, POST /chat)`の解決先scopeを`fraud-agent:chat`から`fraud-agent:read`に変更した
- [k8s/fraud-agent/envoy-configmap.yaml](../../k8s/fraud-agent/envoy-configmap.yaml)：ingress rbacの`x-auth-scope`一致条件を`fraud-agent:chat`から`fraud-agent:read`に変更した

`fraud-mcp-server:read`・fraud-agent→fraud-mcp-serverホップ（`FIXED_SCOPE`）は無変更。命名規則自体は元々ADR 0046で確立したものを踏襲しているだけであり、新しい規則を導入したわけではない。

### 実機検証

`make keycloak-reimport-realm`でrealm設定を反映し、frontend/fraud-agentを再起動した上で、`scripts/verify-hop.sh`のステップ1a（frontend→fraud-agent、`scope=fraud-agent:read`）が成功することを確認した。ステップ1c（[ADR 0046](0046-account-read-audience-scope-split.md)で追加した、`account:read`でfraud-mcp-server宛てを直接要求する抜け道が拒否されることを確認する回帰テスト）は本ADRの変更対象外のホップに対する検証のため、影響なく成功することも確認した。

## Consequences

- architecture.md（§3.3の表1・§4のクライアント・スコープ設計表・表1脚注・表2・§10のUC1シーケンス図と手順・UC5）・services.md・insights.mdの`fraud-agent:chat`表記を`fraud-agent:read`に更新した
- [ADR 0046](0046-account-read-audience-scope-split.md)本文中の`fraud-agent:chat`という表記（Decision・Consequences双方）は書き換えず、該当箇所に本ADRへの訂正注記を追加するに留めた（歴史記録として、導入時に選んだ名前とその後の改名の両方が本文から追える）
- [ADR 0010](0010-egress-listener-granularity.md)・[ADR 0014](0014-fraud-agent-token-exchange.md)・[ADR 0023](0023-fraud-agent-fraud-mcp-server-hop.md)・[ADR 0024](0024-frontend-edge-proxy-and-simplified-login.md)の該当箇所（いずれも[ADR 0046](0046-account-read-audience-scope-split.md)による訂正注記が既に入っている箇所）に、本ADRへのさらなる訂正注記を追加した
- 今後、AIエージェント委任チェーンに新しいホップ・新しいscopeを追加する際は、対象リソースドメイン（≒audience名）と操作カテゴリ（read/propose/freeze/unfreeze/audit等、Keycloakの許可判定上の意味を持つ語）の組み合わせで命名し、実装上のAPI名・エンドポイント名をそのままscope名に持ち込まないことを既定とする
