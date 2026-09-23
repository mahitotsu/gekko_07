package com.gekko.accountservice.web.dto;

// GET /accounts/frozen の1件分。表5のABAC判定を通過した(=呼び出し元アナリストの担当範囲内の)
// 凍結中口座のみが結果セットに含まれる(use-cases.md UC3/UC4:個別のDENYではなく除外)。
// proposalXxxは直近の凍結解除提案(ADR 0036)。ダッシュボードのボタン出し分けと、chat.vueが
// accountId再訪時に提案内容を復元表示するために使う。proposalRecommendationはAIの精査結論
// ("unfreeze"/"keep_frozen"、ADR 0039)で、proposalStatus(人間の判断)とは独立した軸。
public record FrozenAccountView(String id, String region, String tier, String freezeReason,
        String proposalId, String proposalStatus, String proposalReasoning, String proposalRecommendation) {
}
