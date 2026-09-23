# ADR 0043: 1回のチャットが1口座に閉じるという制約を、プロンプトではなくfraud-mcp-serverのツール実装で強制する

- **Status**: Accepted
- **Date**: 2026-09-24

## Context

frontendのチャット画面（`/chat?accountId=`）は「1回の会話は1口座の精査に閉じる」という前提で設計されている（[ADR 0011](0011-scenario-ai-assisted-unfreeze.md)・[ADR 0036](0036-unfreeze-proposal-approval-step.md)）。しかし実装は、ダッシュボードからの最初の自動送信メッセージ（「口座Xが凍結されています…」）にのみ口座IDを埋め込んでおり、それ以降に人間が自由入力欄から送る追加発話には口座の文脈が一切乗らなかった（fraud-agentはメッセージ単位で毎回新規セッションを作り、会話履歴を保持しないため。architecture.md §11「複数ターン会話の永続化」）。実機で、口座固有のpending提案（依頼者本人以外には決定不能になったもの。realm再importによるユーザーID変更が原因、insights.md参照）を回避しようと自由入力欄に「もう一度調べてください」とだけ送ったところ、担当範囲内の凍結中口座**全て**が新たに調査され、意図しない口座にまで新しい提案が作られてしまった。

応急対応として、自由入力メッセージにも口座IDの文脈（`[口座{accountId}についての会話です]`）を前置する改修を行ったが、これはプロンプト文字列でモデルの振る舞いを誘導しているに過ぎない。ユーザーからの指摘の通り、プロンプトによる制限は指示追従に依存し確実ではなく、実際に「全ての凍結口座を調べ直してください」という明示的な逸脱指示を与えると、この前置だけでは防げないことを実機で確認した。ツール呼び出し側で強制する必要がある。

## Decision

### 強制はfraud-mcp-server（ツール実装そのもの）で行う

frontend（`chat.vue`）が会話の紐付く口座IDを`POST /chat?accountId=`のクエリパラメータとして渡し、`server/routes/chat.post.ts`がこれを`X-Gekko-Session-Account-Id`ヘッダーへ変換してfraud-agentへ転送する（AG-UIの`RunAgentInput`スキーマ（body）には混ぜず、独立したヘッダーにすることでスキーマ検証への影響を避けた）。fraud-agentはこの値を検証せず、fraud-mcp-server宛てのMCP接続の`headers`へそのまま転送する中継役に徹する。

fraud-mcp-server（`services/fraud-mcp-server/app.py`）の各ツール関数の先頭で、この値と`account_id`引数を突合する：

- `get_account_history`・`propose_unfreeze`・`conclude_no_unfreeze`：`account_id`引数がヘッダーの値と一致しなければ`ToolError`
- `get_frozen_accounts`：口座横断の一覧系ツールのため、そもそも会話が1口座に紐付いている場合は不要（`get_account_history`で凍結理由・取引履歴の両方が取れる）。ヘッダーが存在する場合は呼び出し自体を`ToolError`で拒否する

ヘッダーが無い呼び出し（frontend以外からの直接呼び出し等）は既存の挙動（BR4の範囲内で無制限）を維持する（fail open。既存の`scripts/verify-hop.sh`等との互換性を優先した意図的な選択）。

### fraud-agent側の`canUseTool`によるツール呼び出し強制は断念した（実機検証）

当初はfraud-agent（`ClaudeAgentAdapter`）側にも`canUseTool`コールバックを実装し、多層防御（ADR 0009 §2の思想）としてツール呼び出しの瞬間に二重で強制する設計にした。しかし実機検証で、`@ag-ui/claude-agent-sdk`の`ClaudeAgentAdapter`経由では、`permissionMode`の値（`dontAsk`・`default`いずれでも）に関わらず`canUseTool`がMCPサーバー提供ツールに対して一度も呼ばれないことを確認した（詳細は[insights.md](../insights.md)「fraud-agentのcanUseToolコールバックは、MCPサーバー提供ツールに対して呼ばれない」参照）。動かないコードを「多層防御」と称して残すことは誤解を招くため、この実装は削除し、fraud-mcp-server側の強制のみに一本化した。

## Consequences

- 影響範囲：`services/frontend/pages/chat.vue`（`accountId`をクエリパラメータとしても送信）、`services/frontend/server/routes/chat.post.ts`（ヘッダーへの変換）、`services/fraud-agent/src/app.ts`（ヘッダーの中継のみ、検証は行わない）、`services/fraud-mcp-server/app.py`（各ツールでの突合）
- 実機で、「全ての凍結口座を調べ直してください」という明示的な逸脱指示を与えても、指定口座以外の提案が作られないことを確認した（`kubectl logs`で`get_frozen_accounts`の呼び出しが実際に`ToolError`で拒否されていることも確認済み）
- 強制はfraud-mcp-server（Python）の1箇所のみで、fraud-agent（TypeScript）側には強制ロジックが無い。将来`@ag-ui/claude-agent-sdk`または`@anthropic-ai/claude-agent-sdk`のアップデートで`canUseTool`がMCPツールに対しても呼ばれるようになった場合、fraud-agent側にも同等の強制を追加し多層防御にする余地がある
- ヘッダーが無い呼び出し（fail open）は、BR4のABAC範囲を超えることはないため権限的な逸脱にはならないが、「1回のチャットは1口座に閉じる」という制約自体は及ばない。frontend以外の呼び出し元は現状存在しないため実害はない
