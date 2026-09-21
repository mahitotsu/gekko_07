// GET /me：ログイン中のアナリストのusernameだけを返す(画面ヘッダー表示用、ADR 0034)。
// トークン自体は返さない(BFFパターン、ADR 0031 設計判断0。ブラウザはトークンに一切触れない)。
//
// 401はthrow createError()ではなくsetResponseStatus+JSONで直接返す。createError()を投げると
// NitroがNuxtのエラーページを描画するため内部的に/__nuxt_error へ再ディスパッチし、その仮想
// リクエストがserver/middleware/0.security.tsのloopback再チェックに引っかかって403で
// 上書きされてしまうことを実機で確認した(実TCP接続を伴わないためremoteAddressが空になる)。
import { defineEventHandler, setResponseStatus } from "h3";
import { readSession } from "../utils/session";

export default defineEventHandler((event) => {
  const session = readSession(event);
  if (!session) {
    setResponseStatus(event, 401);
    return { error: "no active session" };
  }
  return { username: session.username };
});
