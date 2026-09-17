package com.gekko.accountservice.web.dto;

// GET /accounts/frozen の1件分。表5のABAC判定を通過した(=呼び出し元アナリストの担当範囲内の)
// 凍結中口座のみが結果セットに含まれる(use-cases.md UC3/UC4:個別のDENYではなく除外)。
public record FrozenAccountView(String id, String region, String tier, String freezeReason) {
}
