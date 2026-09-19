// gekko_session（本体、AES-256-GCM暗号化）・gekko_pkce（HMAC署名）両Cookieの暗号処理。
//
// 鍵はPod起動時にプロセス内でランダム生成し、Kubernetes Secretとしては永続化しない
// （ADR 0031）。services.mdが明言する「サーバー側データストアを持たないステートレスな
// セッション」という設計そのものが「Pod再起動でセッションが失われても構わない」ことを
// 前提にしているため、鍵の永続化は不要と判断した。
import { createCipheriv, createDecipheriv, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

const ENCRYPTION_KEY = randomBytes(32);
const SIGNING_KEY = randomBytes(32);

function base64url(input: Buffer): string {
  return input.toString("base64url");
}

export function encryptJSON(payload: unknown): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", ENCRYPTION_KEY, iv);
  const plaintext = Buffer.from(JSON.stringify(payload), "utf8");
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return base64url(Buffer.concat([iv, authTag, ciphertext]));
}

// 復号・認証タグ検証に失敗した場合はnullを返す（改ざん・鍵不一致・Pod再起動後の
// 古いCookie等、いずれもfail closeでログイン画面へ戻す。詳細をログに残さない。ADR 0009）。
export function decryptJSON<T>(token: string): T | null {
  try {
    const raw = Buffer.from(token, "base64url");
    const iv = raw.subarray(0, 12);
    const authTag = raw.subarray(12, 28);
    const ciphertext = raw.subarray(28);
    const decipher = createDecipheriv("aes-256-gcm", ENCRYPTION_KEY, iv);
    decipher.setAuthTag(authTag);
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    return JSON.parse(plaintext.toString("utf8")) as T;
  } catch {
    return null;
  }
}

export function signJSON(payload: unknown): string {
  const body = base64url(Buffer.from(JSON.stringify(payload), "utf8"));
  const mac = base64url(createHmac("sha256", SIGNING_KEY).update(body).digest());
  return `${body}.${mac}`;
}

export function verifyJSON<T>(token: string): T | null {
  const parts = token.split(".");
  if (parts.length !== 2) {
    return null;
  }
  const [body, mac] = parts;
  const expectedMac = base64url(createHmac("sha256", SIGNING_KEY).update(body).digest());
  const macBuf = Buffer.from(mac);
  const expectedBuf = Buffer.from(expectedMac);
  if (macBuf.length !== expectedBuf.length || !timingSafeEqual(macBuf, expectedBuf)) {
    return null;
  }
  try {
    return JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as T;
  } catch {
    return null;
  }
}
