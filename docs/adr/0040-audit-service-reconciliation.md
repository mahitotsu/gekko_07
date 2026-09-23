# ADR 0040: account-serviceの自己申告とKeycloak/Envoyの第三者記録を突合する監査サービス(audit-service)を新設する方針を決定する

- **Status**: Accepted
- **Date**: 2026-09-24

## Context

[ADR 0025](0025-audit-log-aggregation.md)で、Keycloakイベントログ・Envoyアクセスログ（account-serviceの外側で生成される記録）をLokiへ集約し、`sessionId`/`sub`/`jti`で事後に相関付けられる基盤を整えた。[ADR 0026](0026-account-service-analyst-attribute-service-implementation.md)・[ADR 0036](0036-unfreeze-proposal-approval-step.md)で、account-service自身が提案・承認・実行の経緯（`unfreeze_proposals`/`unfreeze_executions`、誰が提案し・誰がいつ承認し・誰がいつ実行したか）をDBへ永続化した。architecture.md §9は、この2系統が同じ相関キーを共有しており「事後に再構成できる」と記述している。

しかし実際には、この2系統を突き合わせて一致を確認する仕組みはどこにも無い。BR8（事後追跡可能性）の裏付けは、実質的にaccount-service自身が申告する`unfreeze_proposals`/`unfreeze_executions`の記述が正しいことへの信頼だけに依存しており、account-serviceが侵害されるか、あるいは単なる実装バグがあった場合、自己申告と実際の経緯が食い違っていてもそれを検知する手段が無い。

改ざん耐性を高める手段として、書き換え不能ストレージ（WORM等）の導入も考えられるが、これは標準的なインフラパターンで実現できることが明らかであり、実現可能性をこのプロジェクトで実証する価値は薄い。一方、「自己申告（account-service）」と「第三者記録（account-serviceの外で独立に生成されるKeycloakイベントログ・Envoyアクセスログ）」を実際に突き合わせる仕組みは、まだ実証されていない。この突合が機能することを示せれば、片方だけの改ざんは不整合として検知でき、両方を整合するように改ざんするのは（別コンポーネント・別経路である分）攻撃者にとって手間が大きい、という改ざん耐性の性質を主張できる。これは実際に動かして見せる価値がある。

## Decision

自己申告と第三者記録の突合を行う、AI支援・人間の判断を行うコンポーネント（fraud-agent/fraud-mcp-server/account-service/frontend）とは別の独立したサービス**audit-service**を新設する方針を決定する。

### ステートレスに構成する

audit-serviceは自身の永続ストアを持たない。突合結果はその場で計算するのみで、履歴として保持しない。呼び出しのたびに以下2系統を取得し、決定的なキー突合を行う。

- **第三者記録**：Loki HTTP APIへのLogQLクエリで、Keycloakイベントログ・Envoyアクセスログ（[ADR 0025](0025-audit-log-aggregation.md)で集約済み）を取得する
- **自己申告**：account-serviceが新設する読み取り専用APIから、`unfreeze_proposals`/`unfreeze_executions`の記録を取得する。account-serviceのDBへ直接接続する経路は取らない（§8「各サービスは自分のデータの唯一の番人」の原則を維持するため）

新設する読み取り専用APIのスコープ名・エンドポイント設計、audit-service自身のKeycloakクライアント・SPIRE identity・NetworkPolicy等の実装詳細は、本ADRのスコープ外とし、着手時に別途実装ADRを起こす。

### 突合ロジックはLLMを使わない、決定的な処理に限定する

突合は「両系統に同じ`sessionId`/`sub`/`jti`の組が過不足なく対応しているか」という決定的なキー一致判定のみで行い、LLMによる判断・要約は一切用いない。監査を担うコンポーネント自体が、検証対象であるAI（fraud-agent）と同種の非決定性・不透明さを持ってしまうと、「検証者は再現可能で説明可能である」という本ADRの前提そのものが崩れるため、これは意図的な制約とする。

### 検討したが採用しなかった代替案

- **account-serviceのDBを監査サービスが直接参照する**：§8の「他サービスは直接テーブル・コレクションを見ない」原則に反し、account-service側のスキーマ変更が監査サービスへ無条件に波及する結合を生むため見送った
- **突合結果を永続化するステートフル構成**：まずはステートレスな構成で「突合できる」こと自体を実証することを優先し、過去の突合結果の履歴保持が要件として明確になった場合に改めて検討する
- **書き換え不能ストレージ（WORM等）の追加**：Context参照。標準的なインフラ整備で実現可能なことは自明であり、本プロジェクトで実証する対象としない

## Consequences

- account-serviceに、audit-service向けの新しい読み取り専用APIが今後必要になる。既存の`account:read`（フロントエンド・fraud-mcp-server向け、業務データの読み取り）とは別のスコープを新設し、audit-serviceにのみ付与する想定（§4の「クライアントへのoptional client scope付与のみで委任トポロジーを制御する」原則を踏襲）
- audit-service自体の実装（k8s資材、Keycloakクライアント・スコープ新設、SPIRE identity登録、突合ロジックの実コード、検証スクリプト）は本ADRのスコープ外。着手時に別途実装ADRを起こし、その時点で`docs/architecture.md` §9・§11・[services.md](../services.md)を更新する
- 本決定はBR8（[requirements.md](../requirements.md)）の実現方式を強化するものであり、BR8自体の要件文言に変更はない
- `docs/architecture.md` §11に、本決定を実装未着手の項目として追記した
