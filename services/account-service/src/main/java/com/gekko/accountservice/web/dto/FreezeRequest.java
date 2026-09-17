package com.gekko.accountservice.web.dto;

import java.math.BigDecimal;

// fraud-detection-engineが自動凍結時に送る判定根拠(UC0)。account:freezeはBR7によりABAC対象外。
public record FreezeRequest(String reason, String ruleFired, BigDecimal score) {
}
