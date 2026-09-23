// ページ読み込み(GET)のセッションゲート。/login・/callback・/logoutと静的アセット、
// および/accounts/**・/me・/reconcile（自前で401を返すAPIルート）以外の全GETリクエストに
// ログイン済みセッションを要求し、無ければ/loginへ302する。
// POST等の状態変更リクエストは各ルート自身がreadSession()で判定する（API的な401を返すため）。
//
// k8s/frontend/envoy-configmap.yamlのjwt_authnが担っていた「ログイン済みかどうか」の
// ゲートを、暗号化Cookieを復号できるアプリ層に引き継ぐ(ADR 0031 設計判断2)。
import { defineEventHandler, sendRedirect } from "h3";
import { readSession } from "../utils/session";

const PUBLIC_PATHS = new Set(["/login", "/callback", "/logout"]);

export default defineEventHandler((event) => {
  if (event.method !== "GET") {
    return;
  }

  const path = event.path.split("?")[0];
  if (
    PUBLIC_PATHS.has(path) ||
    path.startsWith("/_nuxt/") ||
    path === "/favicon.ico" ||
    path.startsWith("/accounts/") ||
    path === "/me" ||
    path === "/reconcile"
  ) {
    return;
  }

  const session = readSession(event);
  if (!session) {
    return sendRedirect(event, "/login", 302);
  }
});
