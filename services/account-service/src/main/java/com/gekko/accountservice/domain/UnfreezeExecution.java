package com.gekko.accountservice.domain;

import java.time.OffsetDateTime;

public record UnfreezeExecution(long id, String accountId, String proposalId, String executedBySub, OffsetDateTime executedAt) {
}
