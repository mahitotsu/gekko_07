// frontend本実装（TypeScript/Nuxt.js、ADR 0007・0031）。
//
// SSR既定のまま使う（ダッシュボード・チャット画面はサーバーレンダリング）。Nitroのnode-server
// プリセット（`nuxt build`の既定）で`.output/server/index.mjs`を生成し、Dockerfileで
// そのままエントリーポイントにする（fraud-agentのdist/app.jsと同じ考え方）。
export default defineNuxtConfig({
  compatibilityDate: "2025-01-01",
  devtools: { enabled: false },
  telemetry: false,
  ssr: true,
  nitro: {
    preset: "node-server",
  },
  app: {
    head: {
      title: "gekko - 不正検知アシスタント",
    },
  },
});
