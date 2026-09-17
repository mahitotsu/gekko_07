package com.gekko.accountservice.domain;

public record Account(String id, String region, String tier, boolean frozen) {
}
