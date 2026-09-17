package com.gekko.accountservice.domain;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

public record Transaction(long id, String accountId, BigDecimal amount, OffsetDateTime occurredAt, String description) {
}
