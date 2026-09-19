# frontend本実装(TypeScript/Nuxt.js、ADR 0007・0031)。fraud-agent(services/fraud-agent/Dockerfile、
# ADR 0030)と同じくマルチステージ・非rootで統一する。distrolessにせず-slim(Debian/glibc)を
# 選ぶ理由もfraud-agentと同じ:scripts/verify-hop.shのkubectl exec診断で引き続きシェル・
# ランタイムを使えるようにするため。
FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY nuxt.config.ts tsconfig.json app.vue ./
COPY server ./server
COPY layouts ./layouts
COPY pages ./pages
RUN npm run build

# fraud-agentと違い実行段でnode_modulesを別途コピーしない:Nitro(`nuxt build`)は
# .output/server/配下に依存関係込みの自己完結バンドルを生成するため、.outputだけで動く。
FROM node:22-slim
WORKDIR /app
COPY --from=build /app/.output ./.output
USER node
ENTRYPOINT ["node", "/app/.output/server/index.mjs"]
