package com.gekko.accountservice.client;

import java.util.List;

public record AnalystAttributes(String analystId, List<String> regions, String level) {
}
