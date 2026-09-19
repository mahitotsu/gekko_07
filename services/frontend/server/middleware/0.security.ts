// 多層防御（ADR 0009 §2）。fraud-agent（services/fraud-agent/src/app.ts、ADR 0030）と同型：
// ①loopback限定bind（deployment.yamlのHOST=127.0.0.1）②接続元loopback再チェック③合言葉ヘッダー
// 検証。検証ロジックは環境によらず単一（テスト時だけ迂回するフラグは作らない。CWE-489）。
// Nitroのミドルウェアはファイル名の辞書順で実行されるため、"0."を付けて最初に走らせる。
import { readFileSync } from "node:fs";
import { defineEventHandler, getRequestHeader, send, setResponseStatus } from "h3";

const HANDSHAKE_HEADER = (process.env.HANDSHAKE_HEADER_NAME ?? "x-gekko-handshake").toLowerCase();
const HANDSHAKE_FILE = process.env.HANDSHAKE_TOKEN_FILE ?? "/handshake/token";

function isLoopback(addr: string | undefined): boolean {
  return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1";
}

function readExpectedHandshake(): string | null {
  try {
    return readFileSync(HANDSHAKE_FILE, "utf8").trim();
  } catch {
    return null;
  }
}

export default defineEventHandler((event) => {
  if (!isLoopback(event.node.req.socket.remoteAddress)) {
    setResponseStatus(event, 403);
    return send(event, "forbidden");
  }

  const expected = readExpectedHandshake();
  const got = getRequestHeader(event, HANDSHAKE_HEADER);
  if (!expected || !got || got !== expected) {
    setResponseStatus(event, 403);
    return send(event, "handshake verification failed");
  }
});
