// POST /logout：ローカルCookie削除＋RP-Initiated LogoutでKeycloakのSSOセッションも終了する
// （ADR 0031 設計判断4）。ローカルCookieを消すだけではKeycloak側のSSOセッションが残り、
// 再度/loginに来ると同じユーザーで自動的に認可コードが発行されてしまい別ユーザーへ切り替え
// られないため。POST専用にしているのはCSRF対策（SameSite=LaxはGETのトップレベル
// ナビゲーションでは送信されるがPOSTには送信されないため、他サイトからは呼べない）。
// UI側は<form method="post">での送信を想定しており、ブラウザの通常のナビゲーションとして
// このハンドラ→Keycloakのend_session_endpoint→/loginという一連のリダイレクトを辿らせる
// （fetch()経由だと自動追従したリダイレクト結果を捨てるだけの無駄なラウンドトリップになる）。
//
// end_session_endpointへはGETではなくPOST（Form Serialization）で遷移する（ADR 0032
// 設計判断）。OpenID Connect RP-Initiated Logout 1.0はid_token_hintを使う場合にPOSTを
// 推奨している（Webサーバーのアクセスログ・ブラウザのアドレスバー/履歴にid_tokenが残る
// ことを防ぐため）。client_id方式（id_token_hint省略）も仕様上の代替だが、Keycloakは
// id_token_hint省略時に「ログアウトしますか」という確認画面を挟む（実機・仕様の両方で
// 確認済み）ため、UXを保ったまま露出だけを塞げるPOST方式を採用した。
import { defineEventHandler, sendRedirect, setHeader } from "h3";
import { clearPkceCookie, clearSessionCookie, readSession } from "../utils/session";

const EDGE_PROXY_BASE_URL = process.env.EDGE_PROXY_BASE_URL ?? "http://localhost:3000";

function escapeHtmlAttr(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
}

export default defineEventHandler((event) => {
  const session = readSession(event);
  clearSessionCookie(event);
  clearPkceCookie(event);

  if (!session) {
    return sendRedirect(event, "/login", 302);
  }

  const endSessionUrl = `${EDGE_PROXY_BASE_URL}/realms/gekko/protocol/openid-connect/logout`;
  const postLogoutRedirectUri = `${EDGE_PROXY_BASE_URL}/login`;

  // JWTのcompact serialization(RFC 7519)はbase64urlアルファベット+'.'のみで構成されるため
  // HTML特殊文字を含み得ないが、念のためエスケープする。
  setHeader(event, "Content-Type", "text/html; charset=utf-8");
  setHeader(event, "Referrer-Policy", "no-referrer");
  return `<!doctype html>
<html lang="ja">
<head><meta charset="utf-8"><title>ログアウト中...</title></head>
<body onload="document.forms[0].submit()">
  <form method="POST" action="${escapeHtmlAttr(endSessionUrl)}">
    <input type="hidden" name="id_token_hint" value="${escapeHtmlAttr(session.idToken)}">
    <input type="hidden" name="post_logout_redirect_uri" value="${escapeHtmlAttr(postLogoutRedirectUri)}">
    <noscript><button type="submit">ログアウトを続ける</button></noscript>
  </form>
</body>
</html>`;
});
