package com.gekko.accountservice.web.dto;

public record AccountView(String id, String region, String tier, boolean frozen) {
}
