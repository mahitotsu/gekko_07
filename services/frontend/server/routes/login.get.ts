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

// 失敗理由(state不一致・PKCE検証失敗・id_token検証失敗等)はここでは一切区別しない
// (ADR 0009の「詳細を漏らさない」fail close方針をUI表示でも維持する)。
// Pod再起動をまたいだ一過性の失敗(gekko_pkce・gekko_sessionの暗号鍵がPod内生成のため)
// でもユーザーがクリックし直す必要がないよう、3秒後に/loginへ自動的に戻す
// (meta refresh。このページ自体がfail close専用の生HTMLでVueを使っていないため、
// JS不要でブラウザ標準機能だけで完結するmeta refreshを採用した)。
//
// 文言は「もう一度ログインする」ではなく「再試行する」にする。KeycloakのSSOセッションが
// 生きている場合、/loginへ戻ると認証情報の再入力なしでそのままダッシュボードへ進むことが
// あり(OIDC SSOの通常の挙動)、「ログインする」という予告と実際の遷移が食い違って
// ユーザーを混乱させるため。
const ERROR_PAGE = `<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <title>ログインエラー</title>
  <meta http-equiv="refresh" content="3;url=/login">
  <style>
    body {
      font-family: system-ui, sans-serif;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      background: #f7f7f8;
      color: #222;
    }
    .card {
      background: #fff;
      border: 1px solid #ddd;
      border-radius: 8px;
      padding: 2rem 2.5rem;
      text-align: center;
      max-width: 26rem;
    }
    .card p {
      margin: 0.5rem 0;
    }
    .card a {
      display: inline-block;
      margin-top: 1rem;
      padding: 0.5rem 1.25rem;
      background: #2563eb;
      color: #fff;
      text-decoration: none;
      border-radius: 4px;
    }
    .hint {
      color: #666;
      font-size: 0.875rem;
    }
  </style>
</head>
<body>
  <div class="card">
    <p>ログイン処理を完了できませんでした。</p>
    <p class="hint">お手数ですが、もう一度お試しください。</p>
    <a href="/login">再試行する</a>
    <p class="hint">3秒後に自動的に再試行します…</p>
  </div>
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
