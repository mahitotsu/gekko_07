# ADR 0036: 凍結解除提案に承認/却下の状態遷移を導入し、確定操作を精緻化する

- **Status**: Partially superseded by [0039](0039-unfreeze-recommendation-axis.md)（承認/却下の状態遷移自体はAIの結論が`keep_frozen`の場合にも適用するが、ボタン文言は解除の承認/却下と混同しないよう別にする）
- **Date**: 2026-09-21
- **Amends**: [0011](0011-scenario-ai-assisted-unfreeze.md)（確定操作を単一ボタンから提案の承認/却下を伴う2段階の手続きに精緻化）
- **Amends**: [0024](0024-frontend-edge-proxy-and-simplified-login.md)（frontendのegress scope解決表SCOPE_RULESに承認/却下パスを追加）
- **Amends**: [0031](0031-frontend-implementation.md)（chat.vue/dashboard.vueの確定操作UIをこの2段階に対応させる）

## Context

[ADR 0011](0011-scenario-ai-assisted-unfreeze.md)は「AIが提案し、人間がUIの決定論的操作で確定する」という構造を決定したが、実装は「提案（`unfreeze_proposals`）は承認/却下ステータスを持たない単なる追記ログであり、凍結解除の確定操作（`POST /accounts/{id}/unfreeze`）はどの提案とも紐付けずに（あるいは任意のproposalIdを添えて）いつでも実行できる」という状態だった。ダッシュボードの「凍結解除を確定」ボタンも、提案の有無・内容に関わらず常時有効だった。

これでは「AIの提案を審査した上で承認した」という業務プロセスの実在感がなく、BR8の追跡対象（どの提案に基づく実行か）も名ばかりだった。実際の不正対策運用では、解除の是非は「精査→再評価→承認者による最終決定」という段階を踏むのが通常であり、AIエージェント自身もその精査・再評価を代行する存在として位置づける方が、単なる自由入力チャットより実務に近い。

## Decision

`unfreeze_proposals`に`status`（pending/approved/rejected）・`decided_by_sub`・`decided_at`を追加し、提案を状態機械として扱う。account-serviceに`POST /accounts/{id}/unfreeze-proposals/{proposalId}/approve`・`.../reject`を新設し、いずれも`account:unfreeze`スコープ（実行と同じ人間専用スコープ）を要求する。承認・却下を行えるのは、その提案の作成を依頼した本人アナリストのみとする（BR9。4-eyes原則は導入しない）。

`POST /accounts/{id}/unfreeze`は、`proposalId`が指定された場合に限り、当該提案が`approved`であること・承認者=実行者本人であることを新たに検証する。`proposalId`省略時の「提案に基づかないアナリスト独自の実行」経路（BR8が意図的に許容する設計）はこの検証の対象外のまま維持する。

### UI: チャット起点の精査フロー

ダッシュボードの「AIによる精査を依頼」ボタンが、口座に対する精査開始（顧客・行員からの解除要請を簡略化して表現したもの）の起点であり、独立した「要請」エンティティは設けない。押下するとchat.vueへ`accountId`付きで遷移し、精査を依頼する文面が自動送信されてAIエージェントとの分析が始まる（自由入力欄は併存させ、精査結果を確認した後の追加調査・質問にも使える）。

承認/却下ボタンの唯一の起点はchat.vueであり続ける（ダッシュボードは提案状態の表示と、承認済み提案がある場合の最終確定ボタンのみを持つ）。〔[ADR 0039](0039-unfreeze-recommendation-axis.md)で追加：AIの結論が「根拠なし」の場合、ボタン文言は「承認/却下」ではなく「了解/納得できない」になり、ダッシュボードの最終確定ボタンも出さない〕

## Consequences

- 影響範囲：[requirements.md](../requirements.md)（BR9新設）、[architecture.md](../architecture.md)（表2・§9・§10 UC1手順8以降）、[services.md](../services.md)（account-service・frontendの記述更新）、`k8s/account-service/envoy-configmap.yaml`（approve/rejectパスを`account:unfreeze`のRBACポリシーに追加、ingress側）、`k8s/frontend/token-exchange-app-configmap.yaml`（同パスをSCOPE_RULESに追加、egress側。ingress側だけの更新では呼び出し元がそもそもscopeを解決できず、実機検証で403として顕在化した。詳細は[insights.md](../insights.md)）、ADR 0011・ADR 0024・ADR 0031（Status行・インライン訂正注記）
- 承認と実行を分離したことで、BR8の追跡証跡が「誰が提案し・誰がいつ承認し・誰がいつ実行したか」の3点に精緻化された
- 却下された提案はレコードとして残ったまま（削除しない）、同じ口座に対して新しい提案を作ることで再挑戦できる
- `proposalId`を指定しない直接実行の経路（BR8）はAPIレベルでは引き続き到達可能。今回の変更は「UI操作を通じた通常の業務フローでは必ず承認ゲートを経由する」ことを保証するものであり、APIを直接叩く経路自体を塞ぐものではない
