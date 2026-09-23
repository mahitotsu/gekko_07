package com.gekko.accountservice.web.dto;

// fraud-agentがfraud-mcp-server経由で記録する精査結論(UC1手順7)。recommendationは
// "unfreeze"(解除推奨)または"keep_frozen"(根拠なし、ADR 0039)。未指定時は"unfreeze"
// (この列を追加する前の呼び出し元との後方互換)。
public record ProposeRequest(String reasoning, String recommendation) {
}
