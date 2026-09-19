<script setup lang="ts">
// UC1手順2〜10のfrontend側入口。POST /chat(fraud-agentへプロキシ、ADR 0030のAG-UI SSE
// イベントストリーム)を最小限のクライアント側パーサで読み、アシスタントのテキストを逐次
// 表示する。propose_unfreezeのTOOL_CALL_RESULTを検出したら、対象口座・提案IDでその場から
// 「凍結解除を確定」できるようにし(UC1手順8〜10をチャット画面内で完結させる)。
//
// AG-UIプロトコルの型・SSEフレーミングは公式SDK(@ag-ui/*)がサーバー側(services/fraud-agent)
// で担っており、ここではその出力(`data: {...}\n\n`)をイベント種別だけ見て最小限に解釈する
// 手書きパーサにとどめる(依存を増やさない・画面表示に必要な範囲に絞るため)。
definePageMeta({ layout: "authenticated" });

interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
}

interface ProposalHint {
  toolCallId: string;
  accountId: string;
  proposalId: string;
  confirmed: boolean;
  error: string | null;
}

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
    msg = { id: messageId, role: "assistant", text: "" };
    messages.value.push(msg);
  }
  return msg;
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
    case "TOOL_CALL_START":
      if (event.toolCallId && event.toolCallName) {
        toolCallNames.set(event.toolCallId, event.toolCallName);
      }
      break;
    case "TOOL_CALL_RESULT": {
      const name = toolCallNames.get(event.toolCallId);
      if (name === "mcp__fraud_mcp_server__propose_unfreeze" && typeof event.content === "string") {
        try {
          const parsed = JSON.parse(event.content);
          if (parsed.proposalId && parsed.accountId) {
            proposals.value.push({
              toolCallId: event.toolCallId,
              accountId: parsed.accountId,
              proposalId: parsed.proposalId,
              confirmed: false,
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

async function send() {
  const text = input.value.trim();
  if (!text || sending.value) {
    return;
  }
  const userMessageId = crypto.randomUUID();
  messages.value.push({ id: userMessageId, role: "user", text });
  input.value = "";
  sending.value = true;
  runError.value = null;

  try {
    const res = await fetch("/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        threadId,
        runId: crypto.randomUUID(),
        messages: [{ id: userMessageId, role: "user", content: text }],
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

async function confirmProposal(proposal: ProposalHint) {
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
    proposal.confirmed = true;
  } catch {
    proposal.error = "確定中にエラーが発生しました。";
  }
}
</script>

<template>
  <section class="chat">
    <h1>AIアシスタント</h1>
    <div class="messages">
      <p v-for="m in messages" :key="m.id" :class="['message', m.role]">
        <strong>{{ m.role === "user" ? "あなた" : "AI" }}:</strong> {{ m.text }}
      </p>
    </div>
    <p v-if="runError" class="error">{{ runError }}</p>

    <div v-for="p in proposals" :key="p.toolCallId" class="proposal">
      <span>口座 {{ p.accountId }} の凍結解除案(提案ID: {{ p.proposalId }})</span>
      <button v-if="!p.confirmed" @click="confirmProposal(p)">この提案を確定</button>
      <span v-else>確定済み</span>
      <span v-if="p.error" class="error">{{ p.error }}</span>
    </div>

    <form @submit.prevent="send">
      <textarea v-model="input" :disabled="sending" rows="3" placeholder="凍結中の口座について質問する" />
      <button type="submit" :disabled="sending || !input.trim()">送信</button>
    </form>
  </section>
</template>

<style scoped>
.messages {
  min-height: 4rem;
  margin-bottom: 1rem;
}
.message.user {
  color: #333;
}
.message.assistant {
  color: #0b5394;
}
.proposal {
  display: flex;
  gap: 0.75rem;
  align-items: center;
  margin-bottom: 0.5rem;
}
.error {
  color: #b00020;
}
textarea {
  width: 100%;
  display: block;
  margin-bottom: 0.5rem;
}
</style>
