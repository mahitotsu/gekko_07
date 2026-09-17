package com.gekko.accountservice.domain;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

public record FreezeRecord(long id, String accountId, String reason, String ruleFired, BigDecimal score, OffsetDateTime createdAt) {
}
