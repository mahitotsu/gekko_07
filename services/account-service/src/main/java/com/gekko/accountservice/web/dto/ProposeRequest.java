package com.gekko.accountservice.web.dto;

// fraud-agentがfraud-mcp-server経由で記録する凍結解除提案(UC1手順7)。
public record ProposeRequest(String reasoning) {
}
