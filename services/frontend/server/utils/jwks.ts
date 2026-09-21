// login時に受け取るid_tokenの検証（ADR 0031 設計判断1）。frontendは今回初めてOIDCの
// Relying Partyになるため、Keycloakが返すid_tokenの署名・iss・aud・exp・nonceを自前で
// 検証する義務を負う（Envoyのjwt_authnが担ってきた「リソースサーバー向けBearerトークン検証」
// とは別物）。自前でRS256検証を書かず、実績のある`jose`を使う（AG-UI公式SDKをそのまま使う
// fraud-agentの方針=プロトコル/暗号処理は自前実装しないを踏襲）。
//
// JWKS取得先はappの egress Envoy（k8s/frontend/envoy-configmap.yamlの`keycloak`ドメイン
// ルート。token-exchangeサイドカー自身のKeycloak宛て通信と同じくext_authzが無効化済み）を
// そのまま使う。appはplaintextで投げるだけで実際のmTLS終端はEnvoyが行う
// （証明書はappに一切触れさせないADR 0009 §2の原則を維持する）。
import { createRemoteJWKSet, jwtVerify } from "jose";

const ISSUER = process.env.OIDC_ISSUER ?? "http://localhost:3000/realms/gekko";
const AUDIENCE = "frontend";
const JWKS_URL = process.env.KEYCLOAK_JWKS_URL ?? "http://keycloak/realms/gekko/protocol/openid-connect/certs";

const jwks = createRemoteJWKSet(new URL(JWKS_URL));

export interface VerifiedIdentity {
  sub: string;
  username: string;
  exp: number;
}

// 検証失敗時はnullを返す(fail close。詳細を漏らさない。ADR 0009の思想を踏襲)。
export async function verifyIdToken(idToken: string, expectedNonce: string): Promise<VerifiedIdentity | null> {
  try {
    const { payload } = await jwtVerify(idToken, jwks, { issuer: ISSUER, audience: AUDIENCE });
    if (typeof payload.sub !== "string" || typeof payload.exp !== "number") {
      return null;
    }
    if (typeof payload.preferred_username !== "string") {
      return null;
    }
    if (payload.nonce !== expectedNonce) {
      return null;
    }
    return { sub: payload.sub, username: payload.preferred_username, exp: payload.exp };
  } catch {
    return null;
  }
}
