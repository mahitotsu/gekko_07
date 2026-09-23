# audit-serviceの本実装イメージ(ADR 0007:Go標準ライブラリ。ADR 0040/0041)。
# 外部依存パッケージを持たない(go.sumが存在しない)ため、`go mod download`は不要。
# レジストリは使わず、`k3d image import`でローカルビルド成果物をそのままクラスタへ持ち込む
# (Makefileのbuild-audit-serviceターゲット参照)。
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /out/audit-service .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/audit-service /audit-service
ENTRYPOINT ["/audit-service"]
