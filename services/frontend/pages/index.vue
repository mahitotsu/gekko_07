<script setup lang="ts">
// GET / はserver/middleware/1.auth.tsで既にセッション必須になっているため、ここに
// 到達した時点でログイン済みであることが保証されている。ダッシュボードへ流すだけの薄いページ。
await navigateTo("/dashboard", { redirectCode: 302 });
</script>

<template>
  <div />
</template>
