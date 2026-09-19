<script setup lang="ts">
// UC1/UC2/UC4の「frontend直接」経路：凍結中口座一覧(account-serviceのGET /accounts/frozen、
// 表5のABAC判定済みの結果セット)と、「凍結解除を確定」ボタン(POST /accounts/{id}/unfreeze)。
definePageMeta({ layout: "authenticated" });

interface FrozenAccount {
  id: string;
  region: string;
  tier: string;
  freezeReason: string | null;
}

const { data: accounts, refresh, error } = await useFetch<FrozenAccount[]>("/accounts/frozen");
const unfreezingId = ref<string | null>(null);
const unfreezeError = ref<string | null>(null);

async function confirmUnfreeze(accountId: string) {
  unfreezingId.value = accountId;
  unfreezeError.value = null;
  try {
    const res = await fetch(`/accounts/${accountId}/unfreeze`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
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
    <h1>凍結中口座</h1>
    <p v-if="error">口座一覧の取得に失敗しました。</p>
    <p v-if="unfreezeError" class="error">{{ unfreezeError }}</p>
    <table v-if="accounts && accounts.length">
      <thead>
        <tr>
          <th>口座ID</th>
          <th>地域</th>
          <th>ティア</th>
          <th>凍結理由</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="account in accounts" :key="account.id">
          <td>{{ account.id }}</td>
          <td>{{ account.region }}</td>
          <td>{{ account.tier }}</td>
          <td>{{ account.freezeReason ?? "-" }}</td>
          <td>
            <button :disabled="unfreezingId === account.id" @click="confirmUnfreeze(account.id)">
              凍結解除を確定
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-else-if="!error">担当範囲内に凍結中の口座はありません。</p>
  </section>
</template>

<style scoped>
table {
  border-collapse: collapse;
  width: 100%;
}
th,
td {
  border: 1px solid #ddd;
  padding: 0.5rem;
  text-align: left;
}
.error {
  color: #b00020;
}
</style>
