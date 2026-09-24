<script setup lang="ts">
// 監査画面(ADR 0040/0041/0042/0044)：account-serviceの自己申告とKeycloak/account-service自身の
// Envoyアクセスログ(いずれも第三者記録)をaudit-serviceが突合した結果を、凍結解除リクエスト
// (提案)単位で表示する。senior analyst限定(判定はaudit-service側。ここでは表示するだけで、
// 権限自体の判定はしない)。
// `?accountId=`が付いている場合(dashboard.vueの口座行から遷移してきた場合)、その口座の結果
// だけに絞り込む(ADR 0044)。
definePageMeta({ layout: "authenticated" });

interface CheckResult {
  sub: string;
  at: string;
  jti: string;
  tokenIssued: boolean;
  requestReachedAccountService: boolean;
  verified: boolean;
}

interface RequestAudit {
  proposalId: string;
  accountId: string;
  proposedBySub: string;
  status: "pending" | "approved" | "rejected";
  decision?: CheckResult;
  execution?: CheckResult;
}

interface DirectExecutionAudit {
  accountId: string;
  check: CheckResult;
}

interface ReconcileResult {
  since: string;
  until: string;
  requests: RequestAudit[];
  directExecutions: DirectExecutionAudit[];
}

// server: false固定(pages/dashboard.vueと同じ理由。Envoyのlua filterが付与する
// x-gekko-handshakeヘッダーを経由させるため)。
const { data, pending, refresh, error } = await useFetch<ReconcileResult>("/reconcile", {
  server: false,
});

// dashboard.vue/chat.vueの口座行から`?accountId=`付きで遷移してきた場合、その口座に関する
// 結果だけに絞り込む(全口座横断の一覧から該当口座を探す手間を無くすため)。
const route = useRoute();
const accountFilter = computed(() => {
  const v = route.query.accountId;
  return typeof v === "string" && v ? v : null;
});

const filteredRequests = computed(() => {
  if (!data.value) return [];
  return accountFilter.value
    ? data.value.requests.filter((r) => r.accountId === accountFilter.value)
    : data.value.requests;
});
const filteredDirectExecutions = computed(() => {
  if (!data.value) return [];
  return accountFilter.value
    ? data.value.directExecutions.filter((d) => d.accountId === accountFilter.value)
    : data.value.directExecutions;
});

const allChecks = computed<CheckResult[]>(() => {
  return [
    ...filteredRequests.value.flatMap((r) => [r.decision, r.execution].filter((c): c is CheckResult => !!c)),
    ...filteredDirectExecutions.value.map((d) => d.check),
  ];
});
const failedCount = computed(() => allChecks.value.filter((c) => !c.verified).length);

function formatTime(iso: string): string {
  return new Date(iso).toLocaleString("ja-JP");
}

function statusLabel(status: RequestAudit["status"]): string {
  return { pending: "未決定", approved: "承認", rejected: "却下" }[status] ?? status;
}
</script>

<template>
  <section>
    <h1>監査：凍結解除操作の裏付け確認</h1>
    <p v-if="pending">読み込み中...</p>
    <p v-else-if="error?.statusCode === 403" class="error">この画面はsenior analyst限定です。</p>
    <p v-else-if="error" class="error">突合結果の取得に失敗しました。</p>
    <template v-else-if="data">
      <div class="explain">
        <h2>何をチェックしているか</h2>
        <p>
          凍結解除の「承認/却下」と「実行」は、それぞれaccount-serviceが
          <strong>誰が・いつ・どのトークンで行ったか</strong>を自分のDBに記録しています（自己申告）。
          この記録が改ざん・捏造されていないかを、account-serviceの外側で独立に生成される2種類の
          記録（第三者記録）と突き合わせます。
        </p>
        <h2>判定基準（2点とも確認できて初めて「一致」）</h2>
        <ul>
          <li>
            <strong>① トークンの発行</strong>：自己申告に記録されたトークン識別子(jti)で、
            Keycloakが実際に凍結解除権限（<code>account:unfreeze</code>）のトークンを発行したログが残っているか
          </li>
          <li>
            <strong>② account-serviceへの到達</strong>：同じトークン識別子(jti)で、
            account-service自身のEnvoy（アプリとは別プロセス）のアクセスログに、対応する操作（承認/却下/実行）の
            APIへの成功リクエストが記録されているか
          </li>
        </ul>
        <p class="note">
          以前は「同じ人による近い時刻の記録があるか」という近似的な照合でしたが、
          トークン識別子(jti)の完全一致に切り替えました。同じ人が短時間に複数の操作をしても、
          無関係な記録を誤って裏付けとして採用することがなくなります。
          また②を追加したことで、トークンが発行されただけで実際には使われていない、といった
          中間状態も区別できます。
        </p>
        <p class="note">
          承認/却下と実行は別々のボタン操作なので、1つのリクエストにつき最大2回チェックします。
          却下したリクエストや、まだ「凍結解除を確定」を押していないリクエストには、実行のチェックはありません。
        </p>
      </div>

      <h2>結果</h2>
      <p class="meta">
        対象期間：{{ formatTime(data.since) }} 〜 {{ formatTime(data.until) }}
        <button :disabled="pending" @click="refresh()">再読み込み</button>
      </p>
      <p v-if="accountFilter" class="filter">
        口座「{{ accountFilter }}」の結果のみ表示中 — <NuxtLink to="/audit">全口座を表示</NuxtLink>
      </p>
      <p :class="failedCount ? 'error summary' : 'ok summary'">
        チェック{{ allChecks.length }}件中、不一致{{ failedCount }}件
        <template v-if="!failedCount">：すべての操作に第三者記録の裏付けがありました。</template>
      </p>

      <h3>凍結解除リクエストごとの結果（{{ filteredRequests.length }}件）</h3>
      <p v-if="!filteredRequests.length" class="note">
        {{ accountFilter ? "この口座には対象期間内に承認/却下されたリクエストはありません。" : "対象期間内に承認/却下されたリクエストはありません。" }}
      </p>
      <table v-else>
        <thead>
          <tr>
            <th>口座 / 提案ID</th>
            <th>① 承認/却下の裏付け</th>
            <th>② 凍結解除実行の裏付け</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in filteredRequests" :key="r.proposalId">
            <td>
              {{ r.accountId }}<br />
              <span class="sub">{{ r.proposalId }}</span><br />
              <span class="sub">提案者：{{ r.proposedBySub }}</span>
            </td>
            <td :class="r.decision && !r.decision.verified ? 'ng' : ''">
              <template v-if="r.decision">
                <div>自己申告：{{ r.decision.sub }} が {{ formatTime(r.decision.at) }} に{{ statusLabel(r.status) }}</div>
                <div :class="r.decision.tokenIssued ? 'ok' : 'error'">
                  {{ r.decision.tokenIssued ? "✓" : "✗" }} ①トークン発行(Keycloak)
                </div>
                <div :class="r.decision.requestReachedAccountService ? 'ok' : 'error'">
                  {{ r.decision.requestReachedAccountService ? "✓" : "✗" }} ②account-serviceへの到達(Envoyアクセスログ)
                </div>
              </template>
              <span v-else class="sub">未決定</span>
            </td>
            <td :class="r.execution && !r.execution.verified ? 'ng' : ''">
              <template v-if="r.execution">
                <div>自己申告：{{ r.execution.sub }} が {{ formatTime(r.execution.at) }} に実行</div>
                <div :class="r.execution.tokenIssued ? 'ok' : 'error'">
                  {{ r.execution.tokenIssued ? "✓" : "✗" }} ①トークン発行(Keycloak)
                </div>
                <div :class="r.execution.requestReachedAccountService ? 'ok' : 'error'">
                  {{ r.execution.requestReachedAccountService ? "✓" : "✗" }} ②account-serviceへの到達(Envoyアクセスログ)
                </div>
              </template>
              <span v-else class="sub">
                実行なし<template v-if="r.status === 'rejected'">（却下済みのため）</template>
                <template v-else-if="r.status === 'approved'">（未確定、または凍結維持の結論）</template>
              </span>
            </td>
          </tr>
        </tbody>
      </table>

      <h3>提案を経由しない凍結解除実行（{{ filteredDirectExecutions.length }}件）</h3>
      <p class="note">
        AIの提案・承認の手順を経ずに直接実行された凍結解除です。経路としては正常ですが、実行の裏付けは同じ基準でチェックします。
      </p>
      <table v-if="filteredDirectExecutions.length">
        <thead>
          <tr>
            <th>口座</th>
            <th>凍結解除実行の裏付け</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="d in filteredDirectExecutions" :key="`${d.accountId}-${d.check.at}`">
            <td>{{ d.accountId }}</td>
            <td :class="d.check.verified ? '' : 'ng'">
              <div>自己申告：{{ d.check.sub }} が {{ formatTime(d.check.at) }} に実行</div>
              <div :class="d.check.tokenIssued ? 'ok' : 'error'">
                {{ d.check.tokenIssued ? "✓" : "✗" }} ①トークン発行(Keycloak)
              </div>
              <div :class="d.check.requestReachedAccountService ? 'ok' : 'error'">
                {{ d.check.requestReachedAccountService ? "✓" : "✗" }} ②account-serviceへの到達(Envoyアクセスログ)
              </div>
            </td>
          </tr>
        </tbody>
      </table>
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
  vertical-align: top;
}
.explain {
  background: #f6f8fa;
  border: 1px solid #ddd;
  padding: 0.5rem 1rem;
  margin-bottom: 1.5rem;
}
.meta,
.sub,
.note {
  color: #555;
  font-size: 0.9rem;
}
.summary {
  font-weight: bold;
}
.filter {
  background: #fff8e1;
  border: 1px solid #ffe082;
  padding: 0.4rem 0.8rem;
  display: inline-block;
}
.ng {
  background: #fdecea;
}
.error {
  color: #b00020;
}
.ok {
  color: #2e7d32;
}
</style>
