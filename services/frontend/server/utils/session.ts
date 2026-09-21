// gekko_session（ログイン後のセッション本体）・gekko_pkce（/login〜/callback間だけ生きる
// 短命の一時状態）2種類のCookieの読み書き。ADR 0031 設計判断2・3・5参照。
//
// gekko_sessionの中身にはaccess_token・id_tokenを含む（前者はaccount-service/fraud-agentへの
// Token Exchangeのsubject_token、後者はログアウト時のid_token_hintに使う）が、暗号化されており
// ブラウザからは不透明なバイト列にしか見えない(BFFパターン、ADR 0031 設計判断0)。
import type { H3Event } from "h3";
import { deleteCookie, getCookie, setCookie } from "h3";
import { decryptJSON, encryptJSON, signJSON, verifyJSON } from "./crypto";

export const SESSION_COOKIE = "gekko_session";
export const PKCE_COOKIE = "gekko_pkce";

// ローカルk3d port-forward経由の運用がhttpのため secure:false固定
// (本番相当環境対応時の検討事項。docs/backlog.md参照)。
const COOKIE_BASE = { httpOnly: true, sameSite: "lax" as const, secure: false, path: "/" };

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

export interface Session {
  sub: string;
  username: string;
  accessToken: string;
  idToken: string;
  exp: number; // access_tokenのexp(unix seconds)。リフレッシュトークンは扱わない(設計判断3)。
}

export function setSessionCookie(event: H3Event, session: Session): void {
  const maxAge = Math.max(session.exp - nowSeconds(), 0);
  setCookie(event, SESSION_COOKIE, encryptJSON(session), { ...COOKIE_BASE, maxAge });
}

// 復号失敗・exp超過のいずれもnullを返す(fail close)。
export function readSession(event: H3Event): Session | null {
  const raw = getCookie(event, SESSION_COOKIE);
  if (!raw) {
    return null;
  }
  const session = decryptJSON<Session>(raw);
  if (!session || session.exp <= nowSeconds()) {
    return null;
  }
  return session;
}

export function clearSessionCookie(event: H3Event): void {
  deleteCookie(event, SESSION_COOKIE, { path: "/" });
}

export interface PkceState {
  state: string;
  nonce: string;
  codeVerifier: string;
  exp: number; // 10分の短命Cookie
}

const PKCE_TTL_SECONDS = 600;

export function setPkceCookie(event: H3Event, pkce: Omit<PkceState, "exp">): void {
  const value: PkceState = { ...pkce, exp: nowSeconds() + PKCE_TTL_SECONDS };
  setCookie(event, PKCE_COOKIE, signJSON(value), { ...COOKIE_BASE, maxAge: PKCE_TTL_SECONDS });
}

export function readPkceCookie(event: H3Event): PkceState | null {
  const raw = getCookie(event, PKCE_COOKIE);
  if (!raw) {
    return null;
  }
  const pkce = verifyJSON<PkceState>(raw);
  if (!pkce || pkce.exp <= nowSeconds()) {
    return null;
  }
  return pkce;
}

export function clearPkceCookie(event: H3Event): void {
  deleteCookie(event, PKCE_COOKIE, { path: "/" });
}
