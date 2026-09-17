# analyst-attribute-serviceの本実装イメージ(ADR 0007:Go標準ライブラリ)。
# このリポジトリで初めてコンパイルを要するサービスのため、マルチステージビルドで
# ビルド専用イメージ(golang)と実行専用イメージ(distroless、シェル無し)を分離する。
# レジストリは使わず、`k3d image import`でローカルビルド成果物をそのままクラスタへ持ち込む
# (Makefileのbuild-analyst-attribute-serviceターゲット参照)。
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /out/analyst-attribute-service .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/analyst-attribute-service /analyst-attribute-service
ENTRYPOINT ["/analyst-attribute-service"]
