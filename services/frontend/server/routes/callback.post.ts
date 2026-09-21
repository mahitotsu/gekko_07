// POST /callback：Keycloakからの認可コードを受け取る(ADR 0031)。response_mode=form_post
// (server/routes/login.get.ts参照)により、Keycloakは認可コード・stateをクエリ文字列では
// なくPOST bodyで返す。ブラウザはまだ何のトークンも持たない状態でここに到達するため、
// multilayer defenseのhandshake検証以外は何も要求しない(k8s/frontend/envoy-configmap.yaml
// からjwt_authnを撤去した理由の一つ)。
//
// ①gekko_pkce Cookieのstateと突き合わせてCSRF/リプレイを防ぐ
// ②認可コード→トークン交換はtoken-exchangeサイドカー(ADR 0002：appはKeycloakと直接
//   通信しない)に委譲する
// ③受け取ったid_tokenをOIDC RPとして検証する(ADR 0031 設計判断1)。ここで初めて
//   「認証情報を取得するための検証」が行われる
// のいずれかに失敗した場合はfail closeで/login?error=1へ戻す(詳細を漏らさない。ADR 0009)。
import { defineEventHandler, readBody, sendRedirect } from "h3";
import { verifyIdToken } from "../utils/jwks";
import { clearPkceCookie, readPkceCookie, setSessionCookie } from "../utils/session";

const EDGE_PROXY_BASE_URL = process.env.EDGE_PROXY_BASE_URL ?? "http://localhost:3000";
const TOKEN_EXCHANGE_URL = process.env.TOKEN_EXCHANGE_URL ?? "http://127.0.0.1:9002";

interface TokenExchangeResponse {
  access_token: string;
  id_token: string;
  expires_in: number;
}

export default defineEventHandler(async (event) => {
  const body = await readBody<Record<string, unknown>>(event).catch(() => null);
  const code = typeof body?.code === "string" ? body.code : null;
  const state = typeof body?.state === "string" ? body.state : null;

  const pkce = readPkceCookie(event);
  clearPkceCookie(event);

  if (!code || !state || !pkce || pkce.state !== state) {
    return sendRedirect(event, "/login?error=1", 302);
  }

  let tokenResponse: TokenExchangeResponse;
  try {
    const res = await fetch(`${TOKEN_EXCHANGE_URL}/login/complete`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        code,
        redirectUri: `${EDGE_PROXY_BASE_URL}/callback`,
        codeVerifier: pkce.codeVerifier,
      }),
    });
    if (!res.ok) {
      return sendRedirect(event, "/login?error=1", 302);
    }
    tokenResponse = (await res.json()) as TokenExchangeResponse;
  } catch {
    return sendRedirect(event, "/login?error=1", 302);
  }

  const identity = await verifyIdToken(tokenResponse.id_token, pkce.nonce);
  if (!identity) {
    return sendRedirect(event, "/login?error=1", 302);
  }

  setSessionCookie(event, {
    sub: identity.sub,
    username: identity.username,
    accessToken: tokenResponse.access_token,
    idToken: tokenResponse.id_token,
    exp: identity.exp,
  });

  return sendRedirect(event, "/dashboard", 302);
});
