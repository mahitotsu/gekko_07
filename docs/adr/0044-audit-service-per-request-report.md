# ADR 0044: audit-serviceの突合結果をリクエスト単位で再構成し、jti+Envoyアクセスログによる完全一致判定に切り替える

- **Status**: Accepted
- **Date**: 2026-09-24
- **Amends**: [0041](0041-audit-service-implementation.md)（突合ロジックを、自己申告の`sub`+時刻近接という近似一致から、トークン識別子(jti)とaccount-service自身のEnvoyアクセスログによる完全一致判定へ置き換える）

## Context

[ADR 0042](0042-audit-service-senior-gate.md)でfrontendに監査画面（`/audit`）を追加したが、実際にユーザーが画面を見た結果、次の指摘を受けた。

1. 画面が「承認・却下(decisions)」「凍結解除実行(executions)」というカテゴリ別の件数集計（`total`/`verified`件数と、不一致のみの生データ一覧）を表示するだけで、何と何を照合して「問題なし」と言っているのかが読み取れない
2. カテゴリ別の合計件数（例：承認却下8件、凍結解除実行6件）と、画面外で見えている「凍結解除リクエスト」の件数（例：3件）が対応せず、閲覧者には食い違いにしか見えない。実際には「承認/却下」と「凍結解除の実行」は[ADR 0036](0036-unfreeze-proposal-approval-step.md)により別々の操作（別のボタン・別のAPI・別のKeycloak Token Exchangeイベント）であり、却下された提案や未実行の承認済み提案は実行の記録を持たない。加えて、[ADR 0041](0041-audit-service-implementation.md)が明記した「提案を経由しない直接実行」（`proposalId`省略）経路も件数の食い違いの一因だが、旧仕様の画面はこれを他の実行と区別せず同じ一覧に混ぜていた
3. 突合の基準自体（`sub`が一致し時刻差が許容範囲内）が、精度の面で不十分ではないかという指摘。同じアナリストが短時間に別々の操作（例：別口座の承認と実行）を行った場合、片方の自己申告時刻が改ざんされていても、たまたま近くにある別の本物のイベントを誤って裏付けとして採用してしまう余地がある

指摘3を検討する過程で、[ADR 0040](0040-audit-service-reconciliation.md)自身が当初「両系統に同じ`sessionId`/`sub`/`jti`の組が過不足なく対応しているか」を突合の基準として挙げていた（`jti`を含む）にもかかわらず、実装した[ADR 0041](0041-audit-service-implementation.md)は`sub`+時刻近接のみで済ませ、`jti`は使っていなかったことが分かった。同様に、ADR 0040は第三者記録として「Keycloakイベントログ・**Envoyアクセスログ**」の両方を挙げていたが、ADR 0041はKeycloakのTOKEN_EXCHANGEイベントしか使っていなかった。いずれも0041が実装時にスコープを狭めたまま明示的な記録を残していなかった積み残しであり、本ADRはこれを埋める。

対応方針として、次の2方向を比較した。

- **方向A（採用）**：呼び出しの都度計算するスナップショットのまま、表示・突合の精度を上げる。[ADR 0040](0040-audit-service-reconciliation.md)のステートレス方針（自身の永続ストアを持たない）と矛盾しない
- **方向B（見送り）**：不一致件数の時系列推移など、過去の突合結果を横断する履歴レポートを作る。これには突合結果の永続化が必要になり、ADR 0040が明示的に見送った「ステートフルな構成」に踏み込むことになる。過去の推移を追いたいという要件がまだ明確でないため、今回は見送る（`docs/architecture.md` §11「監査」に未着手事項として残す）

さらに、「監査タブという独立画面自体が要るか」（個々の凍結解除リクエストの操作履歴ページへの導線に置き換え、集約画面自体を廃止する案）も検討したが、audit-serviceの本来の目的（ADR 0040：全口座を横断して自己申告の改ざんを能動的に検知する）は、既に特定のリクエストを疑っている人が個別に確認する用途とは異なる。個々のリクエスト起点の導線だけにすると、どのリクエストを確認すべきかを能動的に見つける手段が失われるため、独立画面は維持することにした。一方で、既に特定の口座を見ているアナリストが、その口座に絞って結果を確認したいという需要（個別リクエスト起点の導線）自体は正当なため、独立画面を主としつつ、口座ごとの画面（ダッシュボード）からその口座に絞り込んだ形で同じ画面へ入れる導線も併せて用意する。

旧形式（`jti`を持たない）の自己申告データを新しい判定基準でどう扱うかも検討したが、恒久的な後方互換フォールバック（`jti`が無ければ旧来のsub+時刻近接に戻す）は、2種類の判定基準が併存して画面の説明が複雑になるうえ、このプロジェクトはデモ用データであり実データの保全が要件ではないため、旧データは破棄し新形式のみをサポートすることにした（ユーザー判断）。

## Decision

### `GET /reconcile`のレスポンスを、凍結解除リクエスト（提案）単位の配列に変更する

カテゴリ別の集計（`decisions`/`executions`の`total`/`verified`/`unverified`）を廃止し、`unfreeze_proposals`の1件（＝1つの凍結解除リクエスト）につき1エントリを返す形にする。各エントリは、その提案に対する「承認/却下」の突合結果（`decision`）と「凍結解除実行」の突合結果（`execution`）を両方保持する。承認/却下は[ADR 0036](0036-unfreeze-proposal-approval-step.md)により別操作のため、いずれか一方だけが存在する（未決定・却下・未実行のケース）ことを許容する（`decision`/`execution`とも省略可能なフィールドとする）。

提案に紐付かない凍結解除実行（`unfreeze_executions.proposal_id IS NULL`、[ADR 0041](0041-audit-service-implementation.md)が定義した「提案を経由しない直接実行」経路）は、どの提案にも属さないため、リクエスト単位の配列とは別の`directExecutions`という枠に分離して返す。これにより、「対応する提案が無いこと自体は異常ではない」ことを閲覧者が構造から読み取れるようにする。

### 突合基準を、`sub`+時刻近接からトークン識別子(jti)の完全一致へ変更する

account-serviceの自己申告（`unfreeze_proposals.decided_*`・`unfreeze_executions.executed_*`）に、その操作に使われたトークンのjti（`decided_jti`/`executed_jti`。account-serviceがEnvoyから受け取る`x-auth-jti`ヘッダーの値）を追加する。audit-serviceはこのjtiを使い、次の2点を確認する。

1. **トークンの発行**：Keycloakのイベントログ（`TOKEN_EXCHANGE`、`account:unfreeze`スコープ）に、このjti（`token_id`フィールド）と一致するトークン発行の記録があるか
2. **account-serviceへの到達**：account-service自身のEnvoy ingressアクセスログ（[ADR 0025](0025-audit-log-aggregation.md)でLoki集約済み）に、このjtiを持つリクエストが、対応するAPIパス（承認なら`.../approve`、却下なら`.../reject`、実行なら`/accounts/{id}/unfreeze`）に実際に届き、2xxで応答された記録があるか

両方確認できて初めて一致（`verified`）とする。`sub`+時刻近接という近似一致（`TOLERANCE_SECONDS`で許容時間を調整する方式）は廃止する。jtiはトークン発行ごとに一意なため、この完全一致判定は「近くにあった無関係な本物のイベントを誤って裏付けとして採用してしまう」という近似一致特有の偽陽性を構造的に排除する。加えて、Envoyアクセスログとの突合を追加したことで、「トークンは発行されたが実際にはその操作に使われていない」という中間状態も検知できるようになった（Keycloakのログだけでは、発行されたトークンがどの操作に使われたかまでは分からない）。

`checkResult`は`verified`(bool)に加えて`tokenIssued`/`requestReachedAccountService`を個別に返し、閲覧者がどちらの確認が失敗したかを区別できるようにする。

#### account-serviceの変更

- Flyway移行（`V6__unfreeze_jti.sql`）で`unfreeze_proposals.decided_jti`（nullable、`decided_by_sub`/`decided_at`と同様pending中はNULL）・`unfreeze_executions.executed_jti`（NOT NULL、追記専用ログのため常に確定済み）を追加する
- `AccountController`の`approveProposal`/`rejectProposal`/`unfreeze`が、既存の`x-auth-sub`と同じ要領で`x-auth-jti`ヘッダー（jwt_authnのclaim_to_headersで既に全リクエストに付与済み。`k8s/account-service/envoy-configmap.yaml`は本ADRのための変更不要）を受け取り、`AccountRepository`経由でDBへ永続化する
- `/audit/unfreeze-proposals`・`/audit/unfreeze-executions`は既存の仕組み（ドメインレコードをそのまま返す）でjtiも自動的にレスポンスへ含まれる

#### 旧データの扱い

`jti`を持たない既存の自己申告データは新しい判定基準では意味を持たない。恒久的な後方互換フォールバックは画面の説明を複雑にするため設けず、`V6__unfreeze_jti.sql`内で`unfreeze_executions`・`unfreeze_proposals`を削除してから列を追加する（デモ用データであり実データの保全は要件でないため。ユーザー判断）。以降のデモ操作（提案の承認/却下/実行）はユーザー自身が実機で行い、新形式のデータを生成し直す。

### frontend: 画面冒頭に固定の説明文を追加する

`pages/audit.vue`を全面的に書き換え、上記のレスポンス構造をそのままリクエスト単位の表として表示する。画面の先頭に「何をチェックしているか」「判定基準（①トークンの発行・②account-serviceへの到達の2点）」を固定文言で明記した。各操作の結果は①②を個別の行として表示し、どちらが不一致の原因かを示す。旧仕様は集計値と生データを提示するのみで、閲覧者が文脈（何と何を比べているか）を画面外から補う必要があったが、これを画面内で完結させる。

### frontend: ダッシュボードの口座行から、その口座に絞り込んだ監査結果へ遷移できるようにする

`pages/dashboard.vue`（凍結中口座一覧）の各行に「監査結果を見る」リンクを追加し、`/audit?accountId=<口座ID>`へ遷移する。`pages/audit.vue`は`accountId`クエリパラメータがある場合、`requests`・`directExecutions`を当該口座のものだけに絞り込んで表示し、画面上部に絞り込み中であることと全件表示に戻るリンクを出す。

このリンクは、junior/senior問わず全ログインユーザーに表示する。閲覧可否の判定はこれまで通りaudit-service側（`x-auth-sub`によるanalyst-attribute-service照会、BR11）で行い、frontend側では出し分けない（[ADR 0042](0042-audit-service-senior-gate.md)の「監査」ナビゲーションリンクと同じ考え方）。junior analystがこのリンクを踏んだ場合も、`/audit`本体を直接開いた場合と同じ403画面になる。

## Consequences

- 影響範囲：`services/account-service/src/main/resources/db/migration/V6__unfreeze_jti.sql`（新設）、`services/account-service/.../domain/UnfreezeProposal.java`・`UnfreezeExecution.java`（jtiフィールド追加）、`AccountRepository.java`（jtiの永続化・読み出し）、`AccountController.java`（`x-auth-jti`ヘッダー受け取り。`k8s/account-service/envoy-configmap.yaml`は既にjwt_authnが全リクエストに`x-auth-jti`を付与済みのため変更不要）、`services/audit-service/main.go`（レスポンス構造の変更、`hasMatch`→`evaluateCheck`、Keycloakの`token_id`抽出とaccount-service自身のEnvoyアクセスログ取得を追加）、`services/audit-service/main_test.go`（新しい関数・構造に合わせて全面更新）、`k8s/audit-service/deployment.yaml`（不要になった`TOLERANCE_SECONDS`env varを削除）、`services/frontend/pages/audit.vue`（全面書き換え、`accountId`クエリによる絞り込みを追加）、`services/frontend/pages/dashboard.vue`（口座行に監査結果へのリンクを追加）、`scripts/verify-audit-service.sh`（コメント更新のみ、レスポンス構造の参照箇所`directExecutions[].check.verified`は変更不要）、`docs/architecture.md`（§9・§11「監査」）、`docs/services.md`（account-service節・audit-service節・frontend節）
- 破壊的変更：`GET /reconcile`のレスポンス形式が変わる（`decisions`/`executions`フィールドを廃止し、`requests`/`directExecutions`に置き換え。`checkResult`から`nearestDeltaSeconds`/`toleranceSeconds`を廃止し`jti`/`tokenIssued`/`requestReachedAccountService`を追加）。このAPIの呼び出し元はfrontendのみ（[ADR 0042](0042-audit-service-senior-gate.md)、`audit:read`スコープはfrontend限定）であり、同じコミットでfrontend側も追随済みのため、互換性維持のための移行期間は設けない
- account-serviceのDB破壊的変更：`unfreeze_proposals`・`unfreeze_executions`の既存データを削除する（デモ用データのため実施。本番相当データを扱う場合はバックフィル戦略の検討が必要になる）
- 時系列の傾向・履歴レポート（方向B）は`docs/architecture.md` §11「監査」に未着手事項として残した。要件が明確になった場合、[ADR 0040](0040-audit-service-reconciliation.md)のステートレス方針の再検討（本ADRのAmends対象になる）が必要になる
- [ADR 0041](0041-audit-service-implementation.md)のStatus行を`Partially superseded by 0042・0044`に更新し、本文中の該当箇所（`hasMatch`の説明）に訂正注記を追加した（本文自体は書き換えない）
