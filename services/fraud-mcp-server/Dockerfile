# fraud-mcp-serverの本実装イメージ(ADR 0007:Python/FastMCP)。このリポジトリ初のPython本実装
# Dockerfile。musl由来のwheel互換性リスクを避けるためalpineではなくpython:3.12-slim(Debian/glibc)
# を両段で使う。マルチステージビルドでビルド専用の仮想環境(/opt/venv)を作り、実行専用イメージへ
# コピーするだけにしてビルドツール・pipキャッシュを最終イメージへ持ち込まない。レジストリは使わず、
# `k3d image import`でローカルビルド成果物をそのままクラスタへ持ち込む
# (Makefileのbuild-fraud-mcp-serverターゲット参照)。
FROM python:3.12-slim AS build
WORKDIR /src
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
RUN useradd -r -u 1000 app
COPY --from=build /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /app
COPY app.py ./
USER app
ENTRYPOINT ["python", "/app/app.py"]
