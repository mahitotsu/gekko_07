// GET /callback：response_mode=form_post(server/routes/login.get.ts参照)採用後、正規の
// フローは常にPOST(callback.post.ts)でここへ到達する。GETで来るのはブックマーク・
// 戻る/進む・リロード等で古いcallback URLが再訪された場合のみで、その時点でstateは
// gekko_pkce Cookie(短命)と一致しない・codeは使用済みのいずれかであり成立し得ないため、
// 中身を見ずにfail closeで/login?error=1へ戻す。
import { defineEventHandler, sendRedirect } from "h3";

export default defineEventHandler((event) => {
  return sendRedirect(event, "/login?error=1", 302);
});
