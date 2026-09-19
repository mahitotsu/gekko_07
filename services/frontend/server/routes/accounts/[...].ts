// GET/POST /accounts/** を account-service へプロキシする(egress、Host: account-service。
// hostAliasesでの横取りは他サービスと同じ、k8s/frontend/deployment.yaml参照)。egressの
// token-exchangeサイドカーがAuthorizationヘッダーをsubject_tokenとしてToken Exchangeし、
// account-service向けの新しいトークンへ置き換える(ADR 0019〜0021/0023と同じパターン)。
// 401はthrow createError()ではなくsetResponseStatus+JSONで直接返す(server/routes/me.get.tsの
// コメント参照。createError()はNitroの/__nuxt_error内部再ディスパッチを誘発し、loopback
// 再チェックに引っかかって403で上書きされることを実機で確認した)。
import { defineEventHandler, getRequestHeader, readRawBody, send, setHeader, setResponseStatus } from "h3";
import { readSession } from "../../utils/session";

const ACCOUNT_SERVICE_URL = process.env.ACCOUNT_SERVICE_URL ?? "http://account-service";

export default defineEventHandler(async (event) => {
  const session = readSession(event);
  if (!session) {
    setResponseStatus(event, 401);
    return { error: "no active session" };
  }

  const path = event.path;
  const method = event.method;
  const hasBody = method !== "GET" && method !== "HEAD";
  const body = hasBody ? await readRawBody(event) : undefined;

  const upstream = await fetch(`${ACCOUNT_SERVICE_URL}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${session.accessToken}`,
      ...(hasBody ? { "Content-Type": getRequestHeader(event, "content-type") ?? "application/json" } : {}),
    },
    body,
  });

  setResponseStatus(event, upstream.status);
  const contentType = upstream.headers.get("content-type");
  if (contentType) {
    setHeader(event, "Content-Type", contentType);
  }
  return send(event, Buffer.from(await upstream.arrayBuffer()));
});
