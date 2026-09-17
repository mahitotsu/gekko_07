package com.gekko.accountservice.domain;

import java.time.OffsetDateTime;

public record UnfreezeProposal(String id, String accountId, String reasoning, String proposedBySub, OffsetDateTime createdAt) {
}
