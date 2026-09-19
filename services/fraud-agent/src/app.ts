// fraud-agent本実装（TypeScript/Claude Agent SDK、ADR 0007・0030）。
//
// 多層防御（ADR 0009 §2）はfraud-mcp-server（services/fraud-mcp-server/app.py、ADR 0029）と
// 同型：①loopback限定bind ②接続元loopback再チェック ③合言葉ヘッダー検証。検証ロジックは
// 環境によらず単一（テスト時だけ迂回するフラグは作らない。CWE-489）。
//
// POST /chatが唯一の業務エンドポイント（frontend→fraud-agent、ADR 0014/0024。
// scripts/verify-hop.shの既存呼び出し先と一致）。AG-UIプロトコル（公式`@ag-ui/claude-agent-sdk`
// アダプタ、ADR 0030）に準拠し、リクエストボディをRunAgentInputとして解釈し、レスポンスを
// Server-Sent Events（AG-UIイベントストリーム）として返す。将来のAG-UI対応frontend実装に
// そのまま繋げられることを見込んだ設計（1リクエスト1レスポンスの同期JSONではなく、最初から
// ストリーミングにしたのはこのため）。
//
// 受信したAuthorizationヘッダーをそのままClaudeAgentAdapterのmcpServers設定（リクエストごとに
// 新しいアダプタインスタンスを作るため、ヘッダーも都度差し替えられる）へ渡し、
// fraud-mcp-server宛てのMCP呼び出しに使わせる。egressのtoken-exchangeサイドカー（ADR 0023）が
// これをsubject_tokenとしてToken Exchangeし、新しいトークンへ置き換える。アプリ本体は
// Token Exchangeを一切意識しない。
//
// Anthropic API（Claude Agent SDK本体の呼び出し先）はToken Exchange/mTLSの対象外の
// クラスタ外エンドポイントであり、CLAUDE_CODE_OAUTH_TOKEN（`claude setup-token`で取得した
// OAuthトークン）をこのプロセス自身がSecret経由で保持する（ADR 0030。Envoyは新設の
// blind tcp_proxyリスナーでバイト列を素通しするだけでAPIキーには一切関与しない）。
import * as http from "node:http";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { ClaudeAgentAdapter } from "@ag-ui/claude-agent-sdk";
import { EventEncoder } from "@ag-ui/encoder";
import { RunAgentInputSchema } from "@ag-ui/core/schemas";
import type { RunAgentInput } from "@ag-ui/core";
import type { McpHttpServerConfig } from "@anthropic-ai/claude-agent-sdk";

const BIND_HOST = process.env.APP_BIND_HOST ?? "127.0.0.1";
const APP_PORT = Number(process.env.APP_PORT ?? "9000");
const HANDSHAKE_HEADER = (process.env.HANDSHAKE_HEADER_NAME ?? "x-gekko-handshake").toLowerCase();
const HANDSHAKE_FILE = process.env.HANDSHAKE_TOKEN_FILE ?? "/handshake/token";
const FRAUD_MCP_SERVER_URL = process.env.FRAUD_MCP_SERVER_URL ?? "http://fraud-mcp-server/mcp";

const MCP_SERVER_NAME = "fraud_mcp_server";
const ALLOWED_TOOLS = [
  `mcp__${MCP_SERVER_NAME}__get_frozen_accounts`,
  `mcp__${MCP_SERVER_NAME}__get_account_history`,
  `mcp__${MCP_SERVER_NAME}__propose_unfreeze`,
];

// UC1（docs/use-cases.md）既定のプロンプト。frontend本実装前のverify-hop.shはRunAgentInputを
// 組み立てずボディ無しで/chatを叩く運用のため、その場合のフォールバックとして使う。
const DEFAULT_PROMPT =
  "凍結中の口座を確認し、凍結理由・取引履歴を分析した上で、" +
  "誤検知の疑いがあり解除すべきものがあれば根拠とともに提案してください。";

const SYSTEM_PROMPT =
  "あなたは金融機関の不正検知アナリストを補助するAIエージェントです。" +
  "fraud-mcp-serverが公開するツールのみを使って凍結口座の状況を確認・分析してください。" +
  "解除を提案する場合は必ず根拠を明示してください。" +
  "あなた自身は凍結解除を実行する権限を持たず、実行することもできません" +
  "（人間のアナリストが確認の上で決定します）。";

function isLoopback(addr: string | undefined): boolean {
  return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1";
}

function checkHandshake(req: http.IncomingMessage): boolean {
  let expected: string | null = null;
  try {
    expected = readFileSync(HANDSHAKE_FILE, "utf8").trim();
  } catch {
    expected = null;
  }
  const got = req.headers[HANDSHAKE_HEADER];
  const gotValue = Array.isArray(got) ? got[0] : got;
  return Boolean(expected) && Boolean(gotValue) && gotValue === expected;
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function defaultRunAgentInput(): RunAgentInput {
  return RunAgentInputSchema.parse({
    threadId: randomUUID(),
    runId: randomUUID(),
    messages: [{ id: randomUUID(), role: "user", content: DEFAULT_PROMPT }],
    tools: [],
    context: [],
  });
}

// クライアントが送ったボディをAG-UIのRunAgentInputとして解釈する。threadId/runId/messagesを
// 補完可能な範囲で補いRunAgentInputSchema.parse()（公式スキーマ、@ag-ui/core）で検証する。
// 本文が空・JSON以外・スキーマ不一致の場合はUC1既定プロンプトへfail closeする
// （ADR 0009の思想を踏襲。verify-hop.shがボディ無しで/chatを叩く運用にも合わせる）。
function buildRunAgentInput(rawBody: string): RunAgentInput {
  if (rawBody.trim().length === 0) {
    return defaultRunAgentInput();
  }
  try {
    const parsed = JSON.parse(rawBody) as Record<string, unknown>;
    const messages =
      Array.isArray(parsed.messages) && parsed.messages.length > 0
        ? parsed.messages
        : [{ id: randomUUID(), role: "user", content: DEFAULT_PROMPT }];
    const candidate = {
      threadId: typeof parsed.threadId === "string" ? parsed.threadId : randomUUID(),
      runId: typeof parsed.runId === "string" ? parsed.runId : randomUUID(),
      messages,
      tools: Array.isArray(parsed.tools) ? parsed.tools : [],
      context: Array.isArray(parsed.context) ? parsed.context : [],
    };
    return RunAgentInputSchema.parse(candidate);
  } catch {
    return defaultRunAgentInput();
  }
}

const server = http.createServer(async (req, res) => {
  // 多層防御②(ADR 0009):bindアドレスの設定に関係なく、接続元がloopbackでなければ拒否する。
  if (!isLoopback(req.socket.remoteAddress)) {
    res.writeHead(403);
    res.end();
    return;
  }

  // 多層防御③(ADR 0009 §2③):合言葉ヘッダーを検証してから初めてリクエストを処理する。
  // fraud-mcp-server(ADR 0029)と同じく、healthz等の全ルートに一律で適用する。
  if (!checkHandshake(req)) {
    res.writeHead(403);
    res.end("handshake verification failed");
    return;
  }

  if (req.method === "GET" && req.url === "/healthz") {
    const body = JSON.stringify({ status: "ok" });
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
    res.end(body);
    return;
  }

  if (req.method === "POST" && req.url === "/chat") {
    const authorizationHeader = req.headers["authorization"];
    const authorization = Array.isArray(authorizationHeader) ? authorizationHeader[0] : authorizationHeader;
    if (!authorization) {
      const body = JSON.stringify({ error: "missing Authorization header on inbound request" });
      res.writeHead(400, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
      res.end(body);
      return;
    }

    const rawBody = await readBody(req);
    const input = buildRunAgentInput(rawBody);

    // fraud-mcp-serverへのMCP接続はリクエストごとに新しいAdapterインスタンスを作ることで
    // 都度差し替える(headersはquery呼び出し単位で設定可能。実機のTypeScript型定義で確認済み)。
    // egressのtoken-exchangeサイドカーが既存パターン通りこれをsubject_tokenとして扱う。
    const mcpServers: Record<string, McpHttpServerConfig> = {
      [MCP_SERVER_NAME]: {
        type: "http",
        url: FRAUD_MCP_SERVER_URL,
        headers: { Authorization: authorization },
      },
    };

    const adapter = new ClaudeAgentAdapter({
      agentId: "fraud-agent",
      systemPrompt: SYSTEM_PROMPT,
      mcpServers,
      tools: [], // 組み込みツール(Bash/Read/Write等)を全て無効化する
      allowedTools: ALLOWED_TOOLS, // fraud-mcp-serverの3ツールのみ確認無しで許可する
      permissionMode: "dontAsk", // 許可リスト外は確認無しで拒否(fail close)
      maxTurns: 10,
    });

    const acceptHeader = req.headers["accept"];
    const encoder = new EventEncoder({
      accept: Array.isArray(acceptHeader) ? acceptHeader[0] : acceptHeader,
    });
    res.writeHead(200, {
      "Content-Type": encoder.getContentType(),
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      // Envoy/プロキシがSSEレスポンスをバッファしてしまわないようにする慣例的なヘッダー
      // (nginx由来だが広く尊重される)。
      "X-Accel-Buffering": "no",
    });

    const subscription = adapter.run(input).subscribe({
      next: (event) => {
        res.write(encoder.encodeSSE(event));
      },
      error: (err: unknown) => {
        // account-service/fraud-mcp-serverと同じfail-close方針だが、AG-UIはエラーも
        // イベントストリームの一部として表現する(RUN_ERROR)。詳細を漏らさない一律のメッセージ。
        console.error("adapter.run failed:", err);
        try {
          res.write(`data: ${JSON.stringify({ type: "RUN_ERROR", message: "fraud-agent processing failed" })}\n\n`);
        } catch {
          // 接続が既に切れている場合は何もできない
        }
        res.end();
      },
      complete: () => {
        res.end();
      },
    });

    req.on("close", () => {
      subscription.unsubscribe();
    });
    return;
  }

  res.writeHead(404);
  res.end();
});

server.listen(APP_PORT, BIND_HOST, () => {
  console.log(`fraud-agent listening on ${BIND_HOST}:${APP_PORT}`);
});
