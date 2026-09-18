# fraud-detection-engineの本実装イメージ(ADR 0007:Rust/Axum、ADR 0027)。他サービス
# (account-service・analyst-attribute-service、ADR 0026)と同じくマルチステージビルドで
# ビルド専用イメージ(rust)と実行専用イメージ(distroless、シェル無し)を分離する。レジストリは
# 使わず、`k3d image import`でローカルビルド成果物をそのままクラスタへ持ち込む
# (Makefileのbuild-fraud-detection-engineターゲット参照)。
FROM rust:1.90-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /src/target/release/fraud-detection-engine /fraud-detection-engine
ENTRYPOINT ["/fraud-detection-engine"]
