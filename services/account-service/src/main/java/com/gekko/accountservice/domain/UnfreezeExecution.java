package com.gekko.accountservice.domain;

import java.time.OffsetDateTime;

// executedJti: 実行に使われたトークンのjti(x-auth-jtiヘッダー)。audit-serviceがKeycloakの
// イベントログ・account-service自身のEnvoyアクセスログと完全一致で突合するための識別子
// (ADR 0044)。
public record UnfreezeExecution(long id, String accountId, String proposalId, String executedBySub,
        OffsetDateTime executedAt, String executedJti) {
}
