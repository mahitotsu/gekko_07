// GET /reconcile を audit-service へプロキシする(egress、Host: audit-service。ADR 0042)。
// account-service向け(server/routes/accounts/[...].ts)と同じパターン:egressの
// token-exchangeサイドカーがAuthorizationヘッダーをsubject_tokenとしてToken Exchangeし、
// audit-service向け(scope=audit:read)の新しいトークンへ置き換える。senior限定の閲覧ゲート
// 判定自体はaudit-service側(analyst-attribute-serviceへの照会)で行うため、ここでは行わない。
// 401はthrow createError()ではなくsetResponseStatus+JSONで直接返す(server/routes/me.get.tsの
// コメント参照)。
import { defineEventHandler, send, setHeader, setResponseStatus } from "h3";
import { readSession } from "../utils/session";

const AUDIT_SERVICE_URL = process.env.AUDIT_SERVICE_URL ?? "http://audit-service";

export default defineEventHandler(async (event) => {
  const session = readSession(event);
  if (!session) {
    setResponseStatus(event, 401);
    return { error: "no active session" };
  }

  const upstream = await fetch(`${AUDIT_SERVICE_URL}${event.path}`, {
    headers: {
      Authorization: `Bearer ${session.accessToken}`,
    },
  });

  setResponseStatus(event, upstream.status);
  const contentType = upstream.headers.get("content-type");
  if (contentType) {
    setHeader(event, "Content-Type", contentType);
  }
  return send(event, Buffer.from(await upstream.arrayBuffer()));
});
