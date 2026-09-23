<script setup lang="ts">
// 監査画面(ADR 0040/0041/0042)：account-serviceの自己申告(承認/実行)とKeycloak/Envoyの
// 第三者記録をaudit-serviceが突合した結果を表示する。senior analyst限定(判定はaudit-service
// 側でanalyst-attribute-serviceに照会して行う。ここでは表示するだけで、権限自体の判定はしない)。
definePageMeta({ layout: "authenticated" });

interface UnverifiedRecord {
  kind: "decision" | "execution";
  proposalId: string;
  accountId: string;
  sub: string;
  at: string;
}

interface CategoryResult {
  total: number;
  verified: number;
  unverified: UnverifiedRecord[];
}

interface ReconcileResult {
  since: string;
  until: string;
  toleranceSeconds: number;
  decisions: CategoryResult;
  executions: CategoryResult;
}

// server: false固定(pages/dashboard.vueと同じ理由。Envoyのlua filterが付与する
// x-gekko-handshakeヘッダーを経由させるため)。
const { data, pending, refresh, error } = await useFetch<ReconcileResult>("/reconcile", {
  server: false,
});
</script>

<template>
  <section>
    <h1>監査：自己申告と第三者記録の突合</h1>
    <p v-if="pending">読み込み中...</p>
    <p v-else-if="error?.statusCode === 403" class="error">
      この画面はsenior analyst限定です。
    </p>
    <p v-else-if="error" class="error">突合結果の取得に失敗しました。</p>
    <template v-else-if="data">
      <p class="meta">
        対象期間: {{ data.since }} 〜 {{ data.until }}(許容時間差: {{ data.toleranceSeconds }}秒)
        <button :disabled="pending" @click="refresh()">再読み込み</button>
      </p>

      <h2>承認・却下(decisions)</h2>
      <p>
        {{ data.decisions.total }}件中 {{ data.decisions.verified }}件が第三者記録
        (Keycloakイベントログ)と一致しました。
      </p>
      <table v-if="data.decisions.unverified.length">
        <thead>
          <tr>
            <th>口座ID</th>
            <th>提案ID</th>
            <th>sub</th>
            <th>時刻</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in data.decisions.unverified" :key="`${r.kind}-${r.proposalId}-${r.at}`">
            <td>{{ r.accountId }}</td>
            <td>{{ r.proposalId }}</td>
            <td>{{ r.sub }}</td>
            <td>{{ r.at }}</td>
          </tr>
        </tbody>
      </table>

      <h2>凍結解除実行(executions)</h2>
      <p>
        {{ data.executions.total }}件中 {{ data.executions.verified }}件が第三者記録
        (Keycloakイベントログ)と一致しました。
      </p>
      <table v-if="data.executions.unverified.length">
        <thead>
          <tr>
            <th>口座ID</th>
            <th>提案ID</th>
            <th>sub</th>
            <th>時刻</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in data.executions.unverified" :key="`${r.kind}-${r.proposalId}-${r.at}`">
            <td>{{ r.accountId }}</td>
            <td>{{ r.proposalId || "-" }}</td>
            <td>{{ r.sub }}</td>
            <td>{{ r.at }}</td>
          </tr>
        </tbody>
      </table>

      <p v-if="!data.decisions.unverified.length && !data.executions.unverified.length" class="ok">
        不整合は検知されませんでした。
      </p>
    </template>
  </section>
</template>

<style scoped>
table {
  border-collapse: collapse;
  width: 100%;
  margin-bottom: 1.5rem;
}
th,
td {
  border: 1px solid #ddd;
  padding: 0.5rem;
  text-align: left;
}
.meta {
  color: #555;
  font-size: 0.9rem;
}
.error {
  color: #b00020;
}
.ok {
  color: #2e7d32;
}
</style>
