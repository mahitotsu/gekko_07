# fraud-agent本実装（TypeScript/Claude Agent SDK、ADR 0007・0030）。fraud-mcp-server
# （services/fraud-mcp-server/Dockerfile、ADR 0029）と同じくマルチステージ・非rootで統一する。
# distrolessにせず-slim（Debian/glibc）を選ぶ理由もfraud-mcp-serverと同じ：
# scripts/verify-hop.shのkubectl exec診断で引き続きシェル・ランタイムを使えるようにするため。
FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-slim
WORKDIR /app
COPY package.json package-lock.json ./
# 本番実行に不要なtypescript等のdevDependenciesはここで落とす(fraud-mcp-serverのビルダー段のみ
# pip installし実行段は/opt/venvだけコピーするのと同じ考え方)。
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist
# node公式イメージ組み込みのnode(uid 1000)ユーザーを使う(fraud-mcp-serverの`useradd -r -u 1000 app`
# と同じ非root方針。distroless系と違いこのイメージは既にビルトインの非rootユーザーを持つ)。
USER node
ENTRYPOINT ["node", "/app/dist/app.js"]
