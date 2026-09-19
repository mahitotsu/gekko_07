// POST /logout：ローカルCookie削除＋RP-Initiated LogoutでKeycloakのSSOセッションも終了する
// （ADR 0031 設計判断4）。ローカルCookieを消すだけではKeycloak側のSSOセッションが残り、
// 再度/loginに来ると同じユーザーで自動的に認可コードが発行されてしまい別ユーザーへ切り替え
// られないため。POST専用にしているのはCSRF対策（SameSite=LaxはGETのトップレベル
// ナビゲーションでは送信されるがPOSTには送信されないため、他サイトからは呼べない）。
// UI側は<form method="post">での送信を想定しており、ブラウザの通常のナビゲーションとして
// このハンドラ→Keycloakのend_session_endpoint→/loginという一連のリダイレクトを辿らせる
// （fetch()経由だと自動追従したリダイレクト結果を捨てるだけの無駄なラウンドトリップになる）。
import { defineEventHandler, sendRedirect } from "h3";
import { clearPkceCookie, clearSessionCookie, readSession } from "../utils/session";

const EDGE_PROXY_BASE_URL = process.env.EDGE_PROXY_BASE_URL ?? "http://localhost:3000";

export default defineEventHandler((event) => {
  const session = readSession(event);
  clearSessionCookie(event);
  clearPkceCookie(event);

  if (!session) {
    return sendRedirect(event, "/login", 302);
  }

  const endSessionUrl = new URL(`${EDGE_PROXY_BASE_URL}/realms/gekko/protocol/openid-connect/logout`);
  endSessionUrl.searchParams.set("id_token_hint", session.idToken);
  endSessionUrl.searchParams.set("post_logout_redirect_uri", `${EDGE_PROXY_BASE_URL}/login`);

  return sendRedirect(event, endSessionUrl.toString(), 302);
});
