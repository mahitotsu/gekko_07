<script setup lang="ts">
// ダッシュボード・チャット画面で共有するヘッダー。ログイン中のsub表示とログアウトボタン。
// ログアウトは<form method="post">での実送信にする(ADR 0031 設計判断4)。fetch()経由だと
// Keycloakのend_session_endpointへのリダイレクトをJSが自動追従して結果を捨てるだけの
// 無駄なラウンドトリップになるため、素直なブラウザナビゲーションに任せる。
// server: false固定。理由はpages/dashboard.vueのuseFetchコメント、および
// server/routes/me.get.tsのコメント(実TCP接続を伴わない内部呼び出しでremoteAddressが
// 空になりserver/middleware/0.security.tsのhandshake検証に落ちる)を参照。
const { data: me } = await useFetch<{ sub: string }>("/me", { server: false });
</script>

<template>
  <div class="page">
    <header class="topbar">
      <nav>
        <NuxtLink to="/dashboard">ダッシュボード</NuxtLink>
        <NuxtLink to="/chat">AIアシスタント</NuxtLink>
      </nav>
      <div class="session">
        <span v-if="me">{{ me.sub }} としてログイン中</span>
        <form method="post" action="/logout">
          <button type="submit">ログアウト</button>
        </form>
      </div>
    </header>
    <main>
      <slot />
    </main>
  </div>
</template>

<style scoped>
.topbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid #ddd;
  font-family: system-ui, sans-serif;
}
nav a {
  margin-right: 1rem;
}
.session {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}
main {
  padding: 1rem;
  font-family: system-ui, sans-serif;
}
</style>
