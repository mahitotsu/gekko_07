import { createHash, randomBytes } from "node:crypto";

// 32バイト→base64url(パディング無し)で43文字。RFC 7636のcode_verifier要件(43〜128文字)を満たす。
export function randomUrlSafe(byteLength: number): string {
  return randomBytes(byteLength).toString("base64url");
}

export function codeChallengeS256(verifier: string): string {
  return createHash("sha256").update(verifier).digest("base64url");
}
