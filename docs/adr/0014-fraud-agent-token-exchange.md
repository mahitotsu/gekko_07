# ADR 0014: fraud-agent→fraud-mcp-serverをToken Exchangeに変更し、frontendの事前トークン取得（パターン④）を廃止する

- **Status**: Accepted
- **Date**: 2026-09-16
- **Amends**: [ADR 0010](0010-egress-listener-granularity.md)（egressパターン③・④）

## Context

[ADR 0010](0010-egress-listener-granularity.md)は、fraud-agent→fraud-mcp-serverのホップを「③ 素通し」（frontendが事前にToken Exchangeで取得した`audience=fraud-mcp-server`のトークンを、fraud-agentがそのまま使い回す。ext_authzは呼ばない単純プロキシ）として設計していた。これに対応するため、frontend側には「実アップストリームを一切呼ばない、トークンを取得するためだけの合成的な呼び出し」（④ トークンを値として取得。人工的な専用パス`http://fraud-mcp-server/_mint-token`＋`direct_response`）という、他の3パターンにはない特殊なexceptionが必要になっていた。

この設計には[architecture.md](../architecture.md)が指摘していた矛盾がある：③はfraud-agentのアプリ本体が「frontendから渡されたトークンを自分でAuthorizationヘッダーにセットする」ことを前提にしており、これは[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)が全サービス共通の原則として掲げた「アプリケーション本体には一切Token Exchangeのコードを持たせない・トークンの中身を一切意識しない」に反する。fraud-agentだけがこの原則の例外になっていた。

加えて、④のトークン取得専用パスは実アップストリームを持たない合成的な呼び出しであり、ADR 0010自身が「この1ケースのみ人工的なパスを持つ」と明記する特殊ケースだった。実際にはfrontendは「チャットを開始する」という**実際にfraud-agentを呼び出す操作**を行うのだから、その呼び出し自体が既に「実サービスへの透過的呼び出し」（パターン①）の形を取れるはずであり、値だけを取り出す合成パスを別途用意する必然性は無かった。

## Decision

**fraud-agent→fraud-mcp-serverのホップを、他の全ホップと同じパターン①（Token Exchange、Envoyサイドカーのext_authzが実行、アプリ本体はトークンを一切意識しない）に変更する。** これに伴い、frontendの事前トークン取得（パターン④）を廃止する。

- **frontend→fraud-agent**：frontendはチャット開始時、自身のログイントークン（`aud=frontend`）を`subject_token`に、`audience=fraud-agent, scope=account:read`でToken Exchangeを行った上で、fraud-agentの実APIを呼ぶ（他のホップと同じ、実アップストリームへの透過的呼び出し）。旧設計の`audience=fraud-mcp-server`・`_mint-token`パスは廃止する
- **fraud-agent→fraud-mcp-server**：fraud-agent自身のEnvoyサイドカーのext_authzが、受信した（`aud=fraud-agent`の）トークンを`subject_token`に、`audience=fraud-mcp-server, scope=account:read`でToken Exchangeを行う。fraud-mcp-server→account-service（既に実機検証済み）と全く同じ仕組みであり、fraud-agentのアプリ本体はAuthorizationヘッダーを一切意識しない
- **fraud-agentは新しいKeycloakクライアント**として登録する（confidential、`standard.token.exchange.enabled=true`、`optionalClientScopes: ["account:read"]`）。既存クライアント（frontend/fraud-mcp-server/fraud-detection-engine/account-service）と同列に扱う
- **`account:read`クライアントスコープ**は、対象audienceのマッパーを`account-service`・`fraud-mcp-server`に加え`fraud-agent`の3つ持つ形に拡張する（既存の「同名scopeを複数audienceで使い、実際の絞り込みはToken Exchangeリクエストのaudienceパラメータで行う」という仕組み——[architecture.md](../architecture.md)表1の前提——をそのまま踏襲。単一audience原則（[ADR 0005](0005-single-audience-tokens-only.md)）は保たれる）
- パターン③（素通し）・パターン④（トークンを値として取得）は、この変更により利用者がいなくなり事実上廃止する。egressパターンは①Token Exchange・②client_credentials発行の2種類に整理される

## Consequences

- [architecture.md](../architecture.md)の「fraud-agentのAuthorizationヘッダー処理」項目は解消する（fraud-agentのアプリ本体はトークンを一切意識しない設計になり、ADR 0002の原則から逸脱しなくなるため）
- [architecture.md](../architecture.md)表1（Audience間のToken Exchange可否）を更新する：frontendの列は`fraud-mcp-server`ではなく`fraud-agent`へのALLOWになり、新たに`fraud-agent`の行（`fraud-mcp-server`のみALLOW）が追加される。委任チェーンはfrontend→fraud-agent→fraud-mcp-server→account-serviceと1ホップ増えるが、「各ホップは常に自分宛て（`aud`が自分のクライアントidと一致する）トークンだけを`subject_token`として提示する」という表1の前提（脚注参照）は崩れず、単純な audience→audience 遷移表のまま表現できる
- [architecture.md](../architecture.md)表2（どのトークンがどのスコープを保有するか）を更新する：「frontendが発行するトークン（fraud-mcp-server宛て）」は「frontendが発行するトークン（fraud-agent宛て）」に変わり、新たに「fraud-agentが発行するトークン（fraud-mcp-server宛て）」の行が加わる。いずれも`account:read`のみを保有する点は変わらない
- [architecture.md](../architecture.md) §3（egressの4パターン列挙）・§4（Keycloakクライアント表にfraud-agent追加）、[services.md](../services.md)（frontend・fraud-agentの記述）、[architecture.md](../architecture.md)（UC1手順2・3、UC5手順1）、[k8s/keycloak/realm-configmap.yaml](../../k8s/keycloak/realm-configmap.yaml)（fraud-agentクライアント・`account:read`スコープのマッパー追加）を本ADRに合わせて更新する
- fraud-agentは本ADR時点で未実装（設計段階）のため、既存の稼働中コード（`k8s/fraud-mcp-server/`・`k8s/account-service/`等、パターン①のfraud-mcp-server→account-serviceホップ）への影響はない。realm-configmap.yamlへのfraud-agentクライアント追加は、他クライアントと同様に実装着手前に先行して定義しておくもので、実機検証はfraud-agent実装時に行う
- frontend→fraud-agentのホップ自体（Envoy bootstrap設定、`hostAliases`、ext_authz呼び出し）はfraud-mcp-server→account-serviceで確立済みのパターン①の構成をそのまま横展開できるため、新たな実機検証の観点は増えない。1点、frontendとfraud-agent双方が未実装のため、このホップの実機検証自体はどちらか一方（あるいは両方）の実装着手時まで行えない
