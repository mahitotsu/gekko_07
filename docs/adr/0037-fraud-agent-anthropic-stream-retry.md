# ADR 0037: fraud-agentがAnthropic応答ストリーミング中の切断を検知し、ターン単位で1回自動リトライする

- **Status**: Accepted
- **Date**: 2026-09-23
- **Amends**: [0030](0030-fraud-agent-implementation.md)（アダプタ実行失敗時に無条件で`RUN_ERROR`を返していた挙動を、ターン単位の1回自動リトライに置き換え）

## Context

[ADR 0030](0030-fraud-agent-implementation.md)は、fraud-agent→Anthropic API間のHTTP/1.1 keep-alive接続が、ツール呼び出しを挟んだ間隔でAnthropic側のエッジから先に閉じられることがある問題に対し、Envoyの`retry_policy`（`reset,connect-failure,refused-stream`、`num_retries: 2`）で対応した。この対応は**新しいリクエストを送る際に失効した接続を掴んでしまい、レスポンスヘッダー到達前に失敗するケース**を対象にしている。

実機（frontend本実装後の実際のチャット利用）で、これとは異なるケースが2回連続で再現した：あるターンのAnthropic応答が実際に届き始め（見出し・表の一部までクライアントに正しく描画された）、**本文ストリーミングの途中で**`API Error: The socket connection was closed unexpectedly`により切断される。これは「新しいリクエストの最初で古い接続を掴む」ケースではなく、確立済みの接続が能動的にデータを流している最中に切れるケースであり、`retry_policy`の対象外（レスポンスヘッダー到達後）である。

## Decision

`services/fraud-agent/src/app.ts`のアダプタ実行失敗時の扱いに、ターン単位の1回自動リトライを追加した。

### 検討した選択肢

**1. Envoy側で接続を予防的にリサイクルする（`max_requests_per_connection`、不採用）**：`anthropic_upstream`クラスタにこの設定を加え、一定リクエスト数ごとに強制的に新しい接続へ切り替えることで、失効した接続を掴む確率を下げる案。ADR 0030本来のケース（リクエスト間でのアイドル失効）には有効だが、今回再現したケース（確立済みの接続が能動的にストリーミング中に切れる）には効かない。接続の入れ替えはリクエストとリクエストの「間」でしか起きないため、進行中の1本のレスポンスが外部要因（Anthropic側のインフラ、経路上のネットワーク）で切られること自体は防げない。

**2. アプリ層でターン単位の1回自動リトライ（採用）**：`services/fraud-agent/src/app.ts`の`adapter.run(input)`が失敗した場合、同一の`RunAgentInput`で最初から1回だけやり直す。読み取り専用ツール（`get_frozen_accounts`・`get_account_history`）は再実行されても冪等なので安全。副作用を持つツール（`propose_unfreeze`）の`TOOL_CALL_RESULT`が一度でも観測された後の失敗はリトライしない（account-serviceへの提案作成を二重に走らせないため）。リトライ対象は`err.message`が既知の接続断パターン（`socket connection was closed unexpectedly`・`ECONNRESET`・`socket hang up`）に一致する場合のみとし、それ以外のエラー（入力不正・権限エラー等、再試行しても直らない種類）は従来通り即座に`RUN_ERROR`にする。

### 実装内容

- `TOOL_CALL_START`→`TOOL_CALL_RESULT`のtoolCallId対応を自前の`Map`で追跡し、`propose_unfreeze`の`TOOL_CALL_RESULT`を一度でも観測したら`proposalCommitted`フラグを立てる
- `adapter.run(input)`の`error`コールバックで、1回目の失敗かつ`proposalCommitted`が`false`かつエラーメッセージが既知の接続断パターンに一致する場合のみ、新しい`ClaudeAgentAdapter`インスタンスを作り直し同じ`input`で`run()`し直す（`buildAdapter()`をリクエストごとの関数として抽出し、初回・リトライ双方から呼べるようにした）
- 2回目の失敗、またはリトライ対象外の失敗は、[ADR 0030](0030-fraud-agent-implementation.md)通り`RUN_ERROR`イベントを書いて接続を閉じる
- リトライは同一のSSEレスポンス内で行う（クライアントからは新しいHTTPリクエストには見えない）。リトライ発生時、クライアント（`pages/chat.vue`）は2回目の`RUN_STARTED`以降のイベント（新しい`messageId`・`toolCallId`を持つ）を新しい吹き出しとして描画するため、1回目のターンの冒頭（挨拶・ツール呼び出し進捗）が画面上に残ったまま2回目のターンが続けて表示される。エラーメッセージ自体はユーザーに見えない

## Consequences

- 影響範囲：`services/fraud-agent/src/app.ts`のみ。`docs/architecture.md` §11「fraud-agent」の該当項目（[ADR 0030](0030-fraud-agent-implementation.md)のkeep-alive失効の既知の制約）を、未対応事項から今回の対応内容の記述に更新した
- 検討した選択肢1(Envoy予防的リサイクル)は実装していない。今回のリトライでも防げない切断（例:2回とも同じ理由で失敗する）が今後観測された場合、ADR 0030本来のケースへの追加対策として選択肢1を改めて検討する余地は残る
- `propose_unfreeze`が実際にaccount-service側で成立したにもかかわらず、その`TOOL_CALL_RESULT`イベント自体が同じ切断で失われた場合（ツール呼び出しを送った直後、結果が返る前に切れる極めて狭い時間帯）は、`proposalCommitted`が立たずリトライが走り、`propose_unfreeze`が二重に呼ばれ得る。account-serviceは提案を追記ログとして扱う設計（低リスク・可逆、[ADR 0011](0011-scenario-ai-assisted-unfreeze.md)）であり、重複した提案が生じても人間のアナリストが承認/却下する段階で吸収できるため、この残存リスクは許容する
- リトライ発生時、Claude Agent SDKの`maxTurns: 10`は1回目・2回目それぞれで独立にリセットされる(最大で約2倍のターン数・トークン消費があり得る)
- `isRetryableRunError`はSDKが投げるエラーメッセージの文字列パターンに依存する、やや脆い判定である。将来SDKのバージョンアップでエラーメッセージの文言が変わった場合、リトライが効かなくなる可能性がある(その場合も従来通りの`RUN_ERROR`にフォールバックするだけで、fail-closeの安全側には倒れる)
