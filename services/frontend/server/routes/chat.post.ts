// POST /chat を fraud-agent へプロキシする(egress、Host: fraud-agent)。ADR 0030でfraud-agentが
// AG-UIプロトコルのSSEストリームを返すようになったため、フロントエンド側のスタブ
// (k8s/frontend/app-configmap.yamlのstream_forward())と同じ理由で、レスポンスを読み切らず
// 都度書き込むストリーミング転送にする(Envoyのidle_timeout設計、ADR 0030を踏襲)。
// 401はthrow createError()ではなくsetResponseStatus+JSONで直接返す(server/routes/me.get.tsの
// コメント参照。createError()はNitroの/__nuxt_error内部再ディスパッチを誘発し、loopback
// 再チェックに引っかかって403で上書きされることを実機で確認した)。
import { defineEventHandler, getRequestHeader, readRawBody, setHeader, setResponseStatus } from "h3";
import { readSession } from "../utils/session";

const FRAUD_AGENT_URL = process.env.FRAUD_AGENT_URL ?? "http://fraud-agent";

export default defineEventHandler(async (event) => {
  const session = readSession(event);
  if (!session) {
    setResponseStatus(event, 401);
    return { error: "no active session" };
  }

  const body = await readRawBody(event);

  const upstream = await fetch(`${FRAUD_AGENT_URL}/chat`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session.accessToken}`,
      "Content-Type": getRequestHeader(event, "content-type") ?? "application/json",
    },
    body,
  });

  setResponseStatus(event, upstream.status);
  const contentType = upstream.headers.get("content-type");
  if (contentType) {
    setHeader(event, "Content-Type", contentType);
  }
  setHeader(event, "Cache-Control", "no-cache");
  setHeader(event, "X-Accel-Buffering", "no");

  if (!upstream.body) {
    event.node.res.end();
    return;
  }

  const reader = upstream.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      event.node.res.write(value);
    }
  } finally {
    event.node.res.end();
  }
});
