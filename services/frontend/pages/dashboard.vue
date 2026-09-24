<script setup lang="ts">
// UC1/UC2/UC4の「frontend直接」経路：凍結中口座一覧(account-serviceのGET /accounts/frozen、
// 表5のABAC判定済みの結果セット)と、「凍結解除を確定」ボタン(POST /accounts/{id}/unfreeze)。
// 「監査結果を見る」リンクは/audit?accountId=に遷移し、この口座に関する結果だけに絞り込んで
// 表示する(ADR 0044)。リンク自体は全ログインユーザーに表示し、閲覧可否の判定はaudit-service側
// (BR11、senior限定)に委ねる(ADR 0042と同じ考え方)。
definePageMeta({ layout: "authenticated" });

interface FrozenAccount {
  id: string;
  region: string;
  tier: string;
  freezeReason: string | null;
  proposalId: string | null;
  proposalStatus: "pending" | "approved" | "rejected" | null;
  proposalReasoning: string | null;
  // AIの精査結論("unfreeze"=解除推奨/"keep_frozen"=根拠なし)。proposalStatus(人間の判断)とは
  // 独立した軸(ADR 0039)。
  proposalRecommendation: "unfreeze" | "keep_frozen" | null;
}

// server: false固定。SSR側のuseFetchはevent.$fetch経由のプロセス内呼び出しになり、
// Envoy(0.0.0.0:8080)のlua filterが付与するx-gekko-handshakeヘッダーを経由しないため、
// server/middleware/0.security.tsのhandshake検証に必ず落ちる(実機で再現・確認済み)。
// クライアント側からのfetchはbrowser→edge-proxy→frontendのEnvoy ingressを経由するため
// 正しくhandshakeが付与される。
const { data: accounts, pending, refresh, error } = await useFetch<FrozenAccount[]>("/accounts/frozen", {
  server: false,
});
const unfreezingId = ref<string | null>(null);
const unfreezeError = ref<string | null>(null);

async function confirmUnfreeze(accountId: string, proposalId: string | null) {
  unfreezingId.value = accountId;
  unfreezeError.value = null;
  try {
    const res = await fetch(`/accounts/${accountId}/unfreeze`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ proposalId }),
    });
    if (res.status === 401) {
      window.location.href = "/login";
      return;
    }
    if (!res.ok) {
      unfreezeError.value = `凍結解除に失敗しました (HTTP ${res.status})`;
      return;
    }
    await refresh();
  } finally {
    unfreezingId.value = null;
  }
}
</script>

<template>
  <section>
    <div class="page-header">
      <h1>凍結中口座</h1>
      <p>担当範囲内で凍結中の口座と、AIによる精査状況を確認できます。</p>
    </div>
    <p v-if="pending" class="text-muted">読み込み中...</p>
    <p v-else-if="error" class="text-danger">口座一覧の取得に失敗しました。</p>
    <p v-if="unfreezeError" class="text-danger">{{ unfreezeError }}</p>
    <table v-if="!pending && accounts && accounts.length" class="table">
      <thead>
        <tr>
          <th>口座ID</th>
          <th>地域</th>
          <th>ティア</th>
          <th>凍結理由</th>
          <th>監査</th>
          <th>AIによる精査</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="account in accounts" :key="account.id">
          <td>{{ account.id }}</td>
          <td>{{ account.region }}</td>
          <td>{{ account.tier }}</td>
          <td>{{ account.freezeReason ?? "-" }}</td>
          <td>
            <NuxtLink :to="`/audit?accountId=${account.id}`" class="audit-link">監査結果を見る</NuxtLink>
          </td>
          <td class="action-cell">
            <NuxtLink
              v-if="!account.proposalStatus || account.proposalStatus === 'rejected'"
              class="btn btn-secondary"
              :to="`/chat?accountId=${account.id}`"
            >
              AIによる精査を依頼
            </NuxtLink>
            <template v-else-if="account.proposalStatus === 'pending'">
              <span class="badge badge-warning">精査中</span>
              <NuxtLink class="btn btn-secondary" :to="`/chat?accountId=${account.id}`">チャットで確認</NuxtLink>
            </template>
            <template v-else-if="account.proposalRecommendation === 'keep_frozen'">
              <span class="badge badge-muted">精査済み(凍結維持)</span>
              <NuxtLink class="btn btn-secondary" :to="`/chat?accountId=${account.id}`">再度精査を依頼</NuxtLink>
            </template>
            <button
              v-else
              class="btn btn-primary"
              :disabled="unfreezingId === account.id"
              @click="confirmUnfreeze(account.id, account.proposalId)"
            >
              凍結解除を確定
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-else-if="!pending && !error" class="text-muted">担当範囲内に凍結中の口座はありません。</p>
  </section>
</template>

<style scoped>
.audit-link {
  font-size: 0.85rem;
  color: var(--color-text-muted);
}
.action-cell {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  flex-wrap: wrap;
}
</style>
