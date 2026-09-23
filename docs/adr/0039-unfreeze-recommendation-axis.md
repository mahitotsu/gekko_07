# ADR 0039: 凍結解除提案に「AIの結論」軸を追加し、根拠なしという結論も記録・確認の対象にする

- **Status**: Accepted
- **Date**: 2026-09-23
- **Amends**: [0011](0011-scenario-ai-assisted-unfreeze.md)（「AIエージェントは凍結解除を提案する」という記述に、根拠なしという結論も正式な精査結果として扱う旨を追加）
- **Amends**: [0036](0036-unfreeze-proposal-approval-step.md)（承認/却下の状態遷移を、AIの結論が`keep_frozen`の場合にも適用する。ボタン文言はrecommendationで出し分ける）

## Context

実機で口座456の精査を行ったところ、AIは分析はしたが解除を提案しなかった（誤検知ではないと判断したと推測される）。この場合account-serviceには何も記録されず、ダッシュボードは「未精査」のまま次に開くたびに一から分析がやり直しになった。

現状の設計（[ADR 0011](0011-scenario-ai-assisted-unfreeze.md)・[ADR 0036](0036-unfreeze-proposal-approval-step.md)）は「AIが解除を推奨した場合の提案」だけを`unfreeze_proposals`に記録する片方向の仕組みで、「AIが精査した結果、解除の根拠なしと判断した」という結論そのものを記録する経路が無かった。

この「提案なし」も一つの正式な結論（解除リクエストの却下）として扱うべきだが、これは「人間がAIの解除提案を却下した」ケースとは意味が異なる（前者はAI自身の結論、後者は人間がAIの提案に不同意）。両者を同じ「却下」という言葉・記録で扱うと、事後に「誰が・何を根拠に凍結を維持すると判断したか」を再構成できなくなり、BR8/BR9が求める事後追跡可能性の精神に反する。

## Decision

`unfreeze_proposals`に、AIの結論を表す`recommendation`（`unfreeze`=解除推奨、`keep_frozen`=根拠なし）を、既存の`status`（`pending`/`approved`/`rejected`、人間の判断）とは独立した軸として追加する。実際に凍結解除が実行されるかどうかは、この2軸の組み合わせ（`recommendation=unfreeze`かつ`status=approved`の場合のみ）で決まる。

### fraud-mcp-server: 結論を記録する2つのツール

`propose_unfreeze`（既存、`recommendation=unfreeze`を明示的に送るよう変更）と対になる`conclude_no_unfreeze`ツールを新設する。どちらも同じ`POST /accounts/{id}/unfreeze-proposals`を、`recommendation`の値だけを変えて呼ぶ。1つのツールに`recommend: boolean`のような引数を持たせるのではなく、名前の異なる2つのツールに分けたのは、モデルに何を呼ぶべきかを名前だけで明確に伝え、引数の設定ミスによる誤記録を防ぐため。

fraud-agentのシステムプロンプトを改訂し、「解除を推奨する場合はpropose_unfreezeを、根拠なしと判断した場合はconclude_no_unfreezeを、理由とともに必ずどちらか一方を呼び出す」ことを明記した。これが無いと、今回の口座456のように結論を文章で述べるだけでツールを呼ばずに終わってしまう。

### account-service: 実行時の多層防御

`POST /accounts/{id}/unfreeze`の提案経由実行に、紐付く提案の`recommendation == 'unfreeze'`であることの検証を追加した。人間が誤って`keep_frozen`の提案を承認していても（フロントエンドのボタン出し分けが正しく機能している限り起こらないはずだが）、構造的に凍結解除を実行できないようにする。

### frontend: 文言を完全に分ける

`recommendation=keep_frozen`の場合、chat.vueのボタンは「承認/却下」ではなく「了解(凍結を維持)」「納得できない(見直しを依頼)」にする。「承認」という言葉を凍結解除以外の文脈で使わないことで、画面を見ただけで「これは解除の承認/却下ではない」と分かるようにする。「了解」後はdashboard.vueで「精査済み(凍結維持)」という終端表示にし、「凍結解除を確定」ボタンは出さない（実行対象が無いため）。

### 今回やらないこと

`keep_frozen`の結論に人間が「納得できない」（却下）した場合、[ADR 0011](0011-scenario-ai-assisted-unfreeze.md)のBR8が許容する「提案に基づかない直接実行」経路（`proposalId`省略の凍結解除API）をUIから呼び出す導線は今回作らない。却下後は「ダッシュボードから再度精査を依頼」に差し戻すのみとする（architecture.md §11参照）。

## Consequences

- 影響範囲：`services/account-service`（マイグレーション`V5`、`UnfreezeProposal`・`ProposeRequest`・`ProposalView`・`FrozenAccountView`・`AccountController`・`AccountRepository`）、`services/fraud-mcp-server/app.py`（`conclude_no_unfreeze`新設）、`services/fraud-agent/src/app.ts`（`ALLOWED_TOOLS`・`SYSTEM_PROMPT`・リトライ時の副作用二重実行防止ロジック）、`services/frontend/pages/dashboard.vue`・`chat.vue`（表示・ボタン文言の分岐）
- [docs/requirements.md](../requirements.md)にBR10を新設し、[docs/architecture.md](../architecture.md) §10 UC1に分岐を追記、§11に「今回やらないこと」を追記した。[docs/services.md](../services.md)のfraud-agent/fraud-mcp-server/account-service節も新ツール・データ構造に合わせて更新した
- `recommendation`列の既定値は`unfreeze`とした。この列を追加する前から存在した提案は、常に「解除推奨」だった提案なので意味が保たれる
- `conclude_no_unfreeze`もaccount-serviceへの書き込みであるため、`account:propose`スコープの範囲内で完結する（新しいスコープは追加していない）。認可トポロジー（表1・表2）に変更はない
