<script setup lang="ts">
import MarkdownIt from "markdown-it";

// UC1手順2〜11のfrontend側入口。POST /chat(fraud-agentへプロキシ、ADR 0030のAG-UI SSE
// イベントストリーム)を最小限のクライアント側パーサで読み、アシスタントのテキストを逐次
// 表示する。propose_unfreezeのTOOL_CALL_RESULTを検出したら、対象口座・提案IDでその場から
// 承認/却下、承認後は「凍結解除を確定」ができるようにし(UC1手順8〜11をチャット画面内で
// 完結させる。ADR 0036)。dashboard.vueから`?accountId=`付きで遷移してきた場合は、精査を
// 依頼する文面を自動送信して開始する(ボタン起点の構造化フロー)。
//
// AG-UIプロトコルの型・SSEフレーミングは公式SDK(@ag-ui/*)がサーバー側(services/fraud-agent)
// で担っており、ここではその出力(`data: {...}\n\n`)をイベント種別だけ見て最小限に解釈する
// 手書きパーサにとどめる(依存を増やさない・画面表示に必要な範囲に絞るため)。
//
// ツール呼び出し中・応答が確定するまでの間、画面が止まって見える(ハングと区別できない)問題への
// 対応として、TOOL_CALL_START/RESULTとTEXT_MESSAGE_END/RUN_ERRORも使い、進捗を可視化する。
definePageMeta({ layout: "authenticated" });

const md = new MarkdownIt();

interface ChatMessage {
  id: string;
  // "tool"は口座情報の照会等、fraud-mcp-serverへのツール呼び出しの進捗を示す行(会話の
  // ロールではないが、時系列上の見た目はメッセージと同じ吹き出しにする)。
  role: "user" | "assistant" | "tool";
  text: string;
  // assistant: TEXT_MESSAGE_END未到達(まだストリーミング中)ならfalse。tool: TOOL_CALL_RESULT
  // 未到達(まだ実行中)ならfalse。userは常にtrue。
  done: boolean;
}

const TOOL_LABELS: Record<string, string> = {
  mcp__fraud_mcp_server__get_frozen_accounts: "凍結中口座を確認中…",
  mcp__fraud_mcp_server__get_account_history: "取引履歴を照会中…",
  mcp__fraud_mcp_server__propose_unfreeze: "解除案を検討中…",
  mcp__fraud_mcp_server__conclude_no_unfreeze: "解除の根拠を検討中…",
};

// 精査結論を記録する2つのツール(ADR 0039)。どちらのTOOL_CALL_RESULTもproposalsへ集約する。
const CONCLUSION_TOOL_RECOMMENDATION: Record<string, "unfreeze" | "keep_frozen"> = {
  mcp__fraud_mcp_server__propose_unfreeze: "unfreeze",
  mcp__fraud_mcp_server__conclude_no_unfreeze: "keep_frozen",
};

interface ProposalHint {
  toolCallId: string | null;
  accountId: string;
  proposalId: string;
  status: "pending" | "approved" | "rejected";
  // AIの精査結論("unfreeze"=解除推奨/"keep_frozen"=根拠なし)。statusとは独立した軸(ADR 0039)。
  recommendation: "unfreeze" | "keep_frozen";
  // AIの根拠説明。ライブ実行時は直前のテキストメッセージから、復元時は永続化済みの
  // proposalReasoningから、いずれもこのフィールドへ集約する(結果カードで一元表示するため)。
  reasoning: string;
  executed: boolean;
  error: string | null;
}

interface FrozenAccount {
  id: string;
  proposalId: string | null;
  proposalStatus: "pending" | "approved" | "rejected" | null;
  proposalReasoning: string | null;
  proposalRecommendation: "unfreeze" | "keep_frozen" | null;
}

const route = useRoute();
const accountId = typeof route.query.accountId === "string" ? route.query.accountId : null;

const threadId = crypto.randomUUID();
const messages = ref<ChatMessage[]>([]);
const input = ref("");
const sending = ref(false);
const runError = ref<string | null>(null);
const proposals = ref<ProposalHint[]>([]);
const toolCallNames = new Map<string, string>();

function ensureAssistantMessage(messageId: string): ChatMessage {
  let msg = messages.value.find((m) => m.id === messageId);
  if (!msg) {
    msg = { id: messageId, role: "assistant", text: "", done: false };
    messages.value.push(msg);
  }
  return msg;
}

function renderMarkdown(text: string): string {
  return md.render(text);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function handleAgUiEvent(event: any) {
  switch (event.type) {
    case "TEXT_MESSAGE_START":
      ensureAssistantMessage(event.messageId);
      break;
    case "TEXT_MESSAGE_CONTENT": {
      const msg = ensureAssistantMessage(event.messageId);
      msg.text += event.delta ?? "";
      break;
    }
    case "TEXT_MESSAGE_END": {
      const msg = messages.value.find((m) => m.id === event.messageId);
      if (msg) {
        msg.done = true;
      }
      break;
    }
    case "TOOL_CALL_START":
      if (event.toolCallId && event.toolCallName) {
        toolCallNames.set(event.toolCallId, event.toolCallName);
        messages.value.push({
          id: event.toolCallId,
          role: "tool",
          text: TOOL_LABELS[event.toolCallName] ?? `${event.toolCallName}を実行中…`,
          done: false,
        });
      }
      break;
    case "TOOL_CALL_RESULT": {
      const toolMsg = messages.value.find((m) => m.role === "tool" && m.id === event.toolCallId);
      if (toolMsg) {
        toolMsg.done = true;
      }
      const name = toolCallNames.get(event.toolCallId);
      const recommendation = name ? CONCLUSION_TOOL_RECOMMENDATION[name] : undefined;
      if (recommendation && typeof event.content === "string") {
        try {
          const parsed = JSON.parse(event.content);
          if (parsed.proposalId && parsed.accountId) {
            // AIの根拠説明は直前のテキストメッセージとして既にmessagesに表示されている。
            // 精査が完了した時点で実行ログ(ツール進捗・やりとりの吹き出し)は役目を終えるため、
            // 根拠だけを結果カードへ取り込んでmessagesはクリアする。これにより、ライブ実行
            // 直後の見た目と、dashboard.vueから後で見返したとき(下記onMounted)の見た目が
            // 「結果カードのみ」で一致する。
            const reasoning = [...messages.value].reverse().find((m) => m.role === "assistant")?.text ?? "";
            messages.value = [];
            proposals.value.push({
              toolCallId: event.toolCallId,
              accountId: parsed.accountId,
              proposalId: parsed.proposalId,
              status: parsed.status === "approved" || parsed.status === "rejected" ? parsed.status : "pending",
              recommendation: parsed.recommendation === "keep_frozen" ? "keep_frozen" : recommendation,
              reasoning,
              executed: false,
              error: null,
            });
          }
        } catch {
          // 期待した形式でなければ無視する(テキスト表示のみで妥協する)
        }
      }
      break;
    }
    case "RUN_ERROR":
      runError.value = typeof event.message === "string" ? event.message : "エラーが発生しました。";
      break;
    default:
      break;
  }
}

function handleFrame(frame: string) {
  const line = frame.split("\n").find((l) => l.startsWith("data:"));
  if (!line) {
    return;
  }
  try {
    handleAgUiEvent(JSON.parse(line.slice("data:".length).trim()));
  } catch {
    // 不正なフレームは無視する
  }
}

// 異常終了時の「再試行」ボタン用に直近のユーザー発話(accountId起点の自動送信文面も含む)を
// 保持する。
const lastUserText = ref<string | null>(null);

async function send(overrideText?: string) {
  const text = (overrideText ?? input.value).trim();
  if (!text || sending.value) {
    return;
  }
  lastUserText.value = text;
  const userMessageId = crypto.randomUUID();
  messages.value.push({ id: userMessageId, role: "user", text, done: true });
  input.value = "";
  sending.value = true;
  runError.value = null;

  // fraud-agentはメッセージ単位で毎回新規セッションを作る(会話履歴を保持しない。architecture.md
  // §11参照)ため、最初の自動送信メッセージ以降に人間が自由入力欄から送るメッセージには
  // 口座IDの文脈が一切乗らない。accountIdがある限り毎回のメッセージにその文脈を明示的に含めて
  // 送ることで、モデルが不要な口座まで調査するのを未然に防ぐ(画面上の吹き出し(text)には元の
  // 発話のみを表示し、口座文脈はAIへの送信内容(promptText)にのみ付与する)。
  //
  // ただしこれはあくまでモデルへのヒントであり、指示追従に依存する不確実な制約にすぎない。
  // 確実な制約は`?accountId=`クエリパラメータ経由でfraud-agent/fraud-mcp-serverのツール呼び出し
  // そのものに強制する(server/routes/chat.post.ts→X-Gekko-Session-Account-Idヘッダー、ADR 0043)。
  const promptText = accountId ? `[口座${accountId}についての会話です] ${text}` : text;
  const chatUrl = accountId ? `/chat?accountId=${encodeURIComponent(accountId)}` : "/chat";

  try {
    const res = await fetch(chatUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        threadId,
        runId: crypto.randomUUID(),
        messages: [{ id: userMessageId, role: "user", content: promptText }],
      }),
    });
    if (res.status === 401) {
      window.location.href = "/login";
      return;
    }
    if (!res.ok || !res.body) {
      runError.value = `チャット呼び出しに失敗しました (HTTP ${res.status})`;
      return;
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      buffer += decoder.decode(value, { stream: true });
      const frames = buffer.split("\n\n");
      buffer = frames.pop() ?? "";
      for (const frame of frames) {
        handleFrame(frame);
      }
    }
    if (buffer) {
      handleFrame(buffer);
    }
  } catch {
    runError.value = "チャット呼び出し中にエラーが発生しました。";
  } finally {
    sending.value = false;
  }
}

function retry() {
  if (lastUserText.value) {
    void send(lastUserText.value);
  }
}

async function decideProposal(proposal: ProposalHint, decision: "approve" | "reject") {
  proposal.error = null;
  try {
    const res = await fetch(`/accounts/${proposal.accountId}/unfreeze-proposals/${proposal.proposalId}/${decision}`, {
      method: "POST",
    });
    if (res.status === 401) {
      window.location.href = "/login";
      return;
    }
    if (!res.ok) {
      proposal.error = `${decision === "approve" ? "承認" : "却下"}に失敗しました (HTTP ${res.status})`;
      return;
    }
    proposal.status = decision === "approve" ? "approved" : "rejected";
  } catch {
    proposal.error = "処理中にエラーが発生しました。";
  }
}

async function confirmUnfreeze(proposal: ProposalHint) {
  proposal.error = null;
  try {
    const res = await fetch(`/accounts/${proposal.accountId}/unfreeze`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ proposalId: proposal.proposalId }),
    });
    if (res.status === 401) {
      window.location.href = "/login";
      return;
    }
    if (!res.ok) {
      proposal.error = `確定に失敗しました (HTTP ${res.status})`;
      return;
    }
    proposal.executed = true;
  } catch {
    proposal.error = "確定中にエラーが発生しました。";
  }
}

// dashboard.vueから`?accountId=`付きで遷移してきた場合の入口。既にpending/approvedの提案が
// あれば(チャットへ戻ってきたケース)それを復元表示し、無ければ(未着手/rejected)精査を自動
// で開始する(UC1手順2〜7相当。ボタン押下起点の構造化フロー)。
// accountId無しでの直接アクセスは認めない(汎用の自由入力チャット入口を持たせず、凍結中
// 口座の精査依頼からのみ起動できるようにするため)。
onMounted(async () => {
  if (!accountId) {
    await navigateTo("/dashboard");
    return;
  }
  try {
    const res = await fetch("/accounts/frozen");
    if (!res.ok) {
      throw new Error(`failed to fetch accounts (HTTP ${res.status})`);
    }
    const accounts: FrozenAccount[] = await res.json();
    const account = accounts.find((a) => a.id === accountId);
    // 「解除の根拠なし」の結論が受理済み(approved)の場合は精査が完結しているため、ダッシュ
    // ボードの「再度精査を依頼」から来た前提で新しい精査を自動開始する(下にフォールスルー)。
    // それ以外のpending/approved(=解除推奨)は従来通り復元表示する。
    const isClosedOutNoUnfreeze =
      account?.proposalStatus === "approved" && account.proposalRecommendation === "keep_frozen";
    if (
      account?.proposalId &&
      !isClosedOutNoUnfreeze &&
      (account.proposalStatus === "pending" || account.proposalStatus === "approved")
    ) {
      // ライブ実行時と同じ結果カード(reasoningを含むProposalHint)だけを表示する。実行ログは
      // 復元しない(ライブ側もTOOL_CALL_RESULT到達時点でmessagesをクリアしており、両者の
      // 見た目を「結果カードのみ」で一致させている。上記handleAgUiEvent参照)。
      proposals.value.push({
        toolCallId: null,
        accountId: account.id,
        proposalId: account.proposalId,
        status: account.proposalStatus,
        recommendation: account.proposalRecommendation ?? "unfreeze",
        reasoning: account.proposalReasoning ?? "",
        executed: false,
        error: null,
      });
      return;
    }
  } catch {
    // 復元に失敗しても自動精査の開始は妨げない(以下にフォールスルー)
  }
  await send(
    `口座${accountId}が凍結されています。凍結理由と取引履歴を確認し、誤検知の疑いがあれば根拠とともに解除を提案してください。`,
  );
});
</script>

<template>
  <section class="chat">
    <div class="page-header">
      <h1>AIアシスタント</h1>
    </div>
    <div class="messages">
      <p v-for="m in messages" :key="m.id" :class="['message', m.role, { pending: !m.done }]">
        <template v-if="m.role === 'tool'">{{ m.done ? "✓" : "⏳" }} {{ m.text }}</template>
        <template v-else-if="m.role === 'assistant'">
          <strong>AI:</strong>
          <span class="assistant-text" v-html="renderMarkdown(m.text)" />
        </template>
        <template v-else><strong>あなた:</strong> {{ m.text }}</template>
      </p>
    </div>
    <p v-if="sending" class="running-indicator">🔄 エージェント実行中…</p>
    <p v-if="runError" class="error">
      {{ runError }}
      <button v-if="lastUserText" type="button" class="btn btn-secondary" @click="retry">再試行</button>
    </p>

    <div v-for="p in proposals" :key="p.toolCallId ?? p.proposalId" class="card proposal-card">
      <header class="proposal-card__header">
        <span class="proposal-card__account">口座 {{ p.accountId }}</span>
        <span :class="['badge', p.recommendation === 'keep_frozen' ? 'badge-muted' : 'badge-accent']">
          {{ p.recommendation === "keep_frozen" ? "精査結果：凍結維持が妥当" : "AIの提案：凍結解除" }}
        </span>
      </header>
      <div v-if="p.reasoning" class="proposal-card__reasoning" v-html="renderMarkdown(p.reasoning)" />
      <footer class="proposal-card__actions">
        <template v-if="p.recommendation === 'keep_frozen'">
          <!-- AIが「根拠なし」と結論したケース(ADR 0039)。凍結解除の承認/却下ではないため、
               文言を完全に分け、実行(凍結解除)ボタンは一切出さない。 -->
          <template v-if="p.status === 'approved'">
            <span>精査完了(凍結維持)</span>
          </template>
          <template v-else-if="p.status === 'rejected'">
            <span>見直しを依頼済み(ダッシュボードから再度精査を依頼できます)</span>
          </template>
          <template v-else>
            <span class="hint">AIは解除の根拠なしと判断しました</span>
            <button class="btn btn-primary" @click="decideProposal(p, 'approve')">了解(凍結を維持)</button>
            <button class="btn btn-secondary" @click="decideProposal(p, 'reject')">納得できない(見直しを依頼)</button>
          </template>
        </template>
        <template v-else>
          <template v-if="p.executed">
            <span>確定済み</span>
          </template>
          <template v-else-if="p.status === 'approved'">
            <button class="btn btn-primary" @click="confirmUnfreeze(p)">凍結解除を確定</button>
          </template>
          <template v-else-if="p.status === 'rejected'">
            <span>却下済み(ダッシュボードから再度精査を依頼できます)</span>
          </template>
          <template v-else>
            <button class="btn btn-primary" @click="decideProposal(p, 'approve')">承認</button>
            <button class="btn btn-secondary" @click="decideProposal(p, 'reject')">却下</button>
          </template>
        </template>
        <span class="proposal-card__meta">提案ID: {{ p.proposalId }}</span>
      </footer>
      <span v-if="p.error" class="error">{{ p.error }}</span>
    </div>

    <form @submit.prevent="send()">
      <textarea v-model="input" :disabled="sending" rows="3" placeholder="凍結中の口座について質問する" />
      <button type="submit" class="btn btn-primary" :disabled="sending || !input.trim()">送信</button>
    </form>
  </section>
</template>

<style scoped>
.messages {
  min-height: 4rem;
  margin-bottom: var(--space-4);
}
.message.user {
  color: var(--color-text);
}
.message.assistant {
  color: var(--color-primary-dark);
}
.message.assistant.pending {
  background: var(--color-primary-bg);
  border-radius: var(--radius-sm);
  padding: 0.25rem 0.5rem;
}
.message.assistant .assistant-text :deep(p:first-child) {
  margin-top: 0;
}
.message.assistant .assistant-text :deep(p:last-child) {
  margin-bottom: 0;
}
.message.assistant.pending .assistant-text::after {
  content: "▌";
  animation: blink 1s step-start infinite;
}
@keyframes blink {
  50% {
    opacity: 0;
  }
}
.message.tool {
  color: var(--color-text-muted);
  font-style: italic;
  font-size: 0.9rem;
}
.message.tool.pending {
  opacity: 0.85;
}
.running-indicator {
  color: var(--color-text-muted);
  font-size: 0.9rem;
}
.proposal-card {
  margin-bottom: var(--space-4);
}
.proposal-card__header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: var(--space-2);
}
.proposal-card__account {
  font-weight: bold;
}
.proposal-card__reasoning {
  color: var(--color-text);
  margin-bottom: var(--space-3);
}
.proposal-card__reasoning :deep(p:first-child) {
  margin-top: 0;
}
.proposal-card__reasoning :deep(p:last-child) {
  margin-bottom: 0;
}
.proposal-card__actions {
  display: flex;
  gap: var(--space-3);
  align-items: center;
}
.proposal-card__meta {
  margin-left: auto;
  color: var(--color-text-muted);
  font-size: 0.8rem;
}
.error {
  color: var(--color-danger);
}
.hint {
  color: var(--color-text-muted);
}
textarea {
  width: 100%;
  display: block;
  margin-bottom: var(--space-2);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: var(--space-2);
  font-family: var(--font-sans);
}
</style>
