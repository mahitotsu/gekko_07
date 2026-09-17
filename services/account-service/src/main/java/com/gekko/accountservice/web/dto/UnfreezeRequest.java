package com.gekko.accountservice.web.dto;

// proposalIdは任意(BR8:AIの提案に基づかないアナリスト独自の実行も許す)。
public record UnfreezeRequest(String proposalId) {
}
