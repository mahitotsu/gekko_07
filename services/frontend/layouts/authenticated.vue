<script setup lang="ts">
// ダッシュボード・チャット画面で共有するヘッダー。ログイン中のusername表示(ADR 0034。
// Keycloak内部識別子のsubではなくログインに使った読める名前を出す)とログアウトボタン。
// ログアウトは<form method="post">での実送信にする(ADR 0031 設計判断4)。fetch()経由だと
// Keycloakのend_session_endpointへのリダイレクトをJSが自動追従して結果を捨てるだけの
// 無駄なラウンドトリップになるため、素直なブラウザナビゲーションに任せる。
// server: false固定。理由はpages/dashboard.vueのuseFetchコメント、および
// server/routes/me.get.tsのコメント(実TCP接続を伴わない内部呼び出しでremoteAddressが
// 空になりserver/middleware/0.security.tsのhandshake検証に落ちる)を参照。
const { data: me } = await useFetch<{ username: string }>("/me", { server: false });
</script>

<template>
  <div class="page">
    <header class="topbar">
      <div class="topbar__brand">gekko</div>
      <nav class="topbar__nav">
        <NuxtLink to="/dashboard">ダッシュボード</NuxtLink>
        <NuxtLink to="/audit">監査</NuxtLink>
      </nav>
      <div class="session">
        <span v-if="me" class="session__user">{{ me.username }} としてログイン中</span>
        <form method="post" action="/logout">
          <button type="submit" class="btn btn-secondary">ログアウト</button>
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
  align-items: center;
  gap: var(--space-6);
  padding: var(--space-3) var(--space-5);
  background: var(--color-surface);
  border-bottom: 1px solid var(--color-border);
  box-shadow: var(--shadow-sm);
}
.topbar__brand {
  font-weight: 700;
  font-size: 1.1rem;
  color: var(--color-primary-dark);
}
.topbar__nav {
  display: flex;
  gap: var(--space-2);
  flex: 1;
}
.topbar__nav a {
  padding: 0.4rem 0.9rem;
  border-radius: var(--radius-sm);
  color: var(--color-text-muted);
  text-decoration: none;
  font-size: 0.9rem;
}
.topbar__nav a:hover {
  background: var(--color-bg);
}
.topbar__nav a.router-link-active {
  background: var(--color-primary-bg);
  color: var(--color-primary-dark);
  font-weight: 600;
}
.session {
  display: flex;
  align-items: center;
  gap: var(--space-3);
}
.session__user {
  color: var(--color-text-muted);
  font-size: 0.9rem;
}
main {
  max-width: 72rem;
  margin: 0 auto;
  padding: var(--space-5);
}
</style>
