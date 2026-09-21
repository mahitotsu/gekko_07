// GET /login：本物のAuthorization Code + PKCEブラウザフローの起点（ADR 0031。
// ADR 0024の簡易ログイン=ROPCを置き換える）。code_verifier/state/nonceを生成し、
// 短命の gekko_pkce Cookie に控えてから、Keycloakの認可エンドポイントへブラウザをリダイレクト
// する。ここではKeycloakへ直接通信しない（PKCEパラメータの生成に秘密情報は不要なため、
// ADR 0002が制限する「クライアント認証を伴うKeycloak通信」には該当しない）。
import { defineEventHandler, getQuery, sendRedirect, setHeader } from "h3";
import { codeChallengeS256, randomUrlSafe } from "../utils/pkce";
import { setPkceCookie } from "../utils/session";

const EDGE_PROXY_BASE_URL = process.env.EDGE_PROXY_BASE_URL ?? "http://localhost:3000";
const CLIENT_ID = "frontend";

const ERROR_PAGE = `<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>ログインエラー</title></head>
<body>
  <p>ログインに失敗しました。</p>
  <p><a href="/login">もう一度ログインする</a></p>
</body>
</html>`;

export default defineEventHandler((event) => {
  const query = getQuery(event);
  if (query.error) {
    setHeader(event, "Content-Type", "text/html; charset=utf-8");
    return ERROR_PAGE;
  }

  const codeVerifier = randomUrlSafe(32);
  const codeChallenge = codeChallengeS256(codeVerifier);
  const state = randomUrlSafe(16);
  const nonce = randomUrlSafe(16);

  setPkceCookie(event, { state, nonce, codeVerifier });

  const authorizeUrl = new URL(`${EDGE_PROXY_BASE_URL}/realms/gekko/protocol/openid-connect/auth`);
  authorizeUrl.searchParams.set("client_id", CLIENT_ID);
  authorizeUrl.searchParams.set("response_type", "code");
  authorizeUrl.searchParams.set("redirect_uri", `${EDGE_PROXY_BASE_URL}/callback`);
  authorizeUrl.searchParams.set("scope", "openid");
  authorizeUrl.searchParams.set("code_challenge", codeChallenge);
  authorizeUrl.searchParams.set("code_challenge_method", "S256");
  authorizeUrl.searchParams.set("state", state);
  authorizeUrl.searchParams.set("nonce", nonce);
  // response_mode=form_post(OAuth 2.0 Form Post Response Mode)。既定のquery modeだと
  // 認可コード・stateがcallback URLのクエリ文字列としてブラウザのアドレスバー・履歴・
  // Refererヘッダーに残る(RFC 9700 §4.1.2が言及するリスク)。form_postではKeycloakが
  // これらをPOST bodyで返すため、/callbackのURLは常にクエリ無しの状態になる。
  authorizeUrl.searchParams.set("response_mode", "form_post");

  return sendRedirect(event, authorizeUrl.toString(), 302);
});
