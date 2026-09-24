package com.gekko.accountservice.domain;

import java.time.OffsetDateTime;

// recommendation: AIの精査結論("unfreeze"=解除推奨、"keep_frozen"=根拠なし)。
// status: その結論に対する人間の判断("pending"/"approved"/"rejected")。この2つは独立した軸
// (ADR 0039)。
// decidedJti: 承認/却下に使われたトークンのjti(x-auth-jtiヘッダー)。audit-serviceがKeycloakの
// イベントログ・account-service自身のEnvoyアクセスログと完全一致で突合するための識別子
// (ADR 0044)。decidedBySub/decidedAtと同様、決定前はnull。
public record UnfreezeProposal(String id, String accountId, String reasoning, String proposedBySub,
        OffsetDateTime createdAt, String status, String decidedBySub, OffsetDateTime decidedAt,
        String decidedJti, String recommendation) {
}
