# ADR 0029: fraud-mcp-serverを本実装し、account-serviceの読み取り・提案系機能をMCPツールとして公開する

- **Status**: Accepted
- **Date**: 2026-09-19

## Context

[ADR 0027](0027-fraud-detection-engine-implementation.md)でfraud-detection-engineを本実装した時点で、README.mdの残り未着手項目はfraud-mcp-server・fraud-agent・frontendの3サービスだった。[docs/services.md](../services.md)の記述順・[architecture.md](../architecture.md) §3の実装順序（1ホップ先行検証の順）のいずれでもfraud-mcp-server→account-serviceが残り3サービス中もっとも先頭に位置し、かつaccount-serviceのみに依存する（fraud-agent・frontend未実装への依存が無い）ため本実装に着手する最有力候補だった。ロジックもMCPツール3本をaccount-serviceへ中継するだけで、fraud-detection-engineの自律検知ループより単純である。

fraud-mcp-serverは[ADR 0011](0011-scenario-ai-assisted-unfreeze.md)・[use-cases.md](../use-cases.md)で「account-serviceの読み取り・提案系機能をMCPツールとして公開し、AIエージェント（fraud-agent）とaccount-serviceの間に立ってMCPプロトコルとREST/gRPCの変換を担う」役割と定義されている。scope設計（[access-control-design.md](../access-control-design.md) 表2）は既にfraud-agent→fraud-mcp-server（`account:read`固定、[ADR 0023](0023-fraud-agent-fraud-mcp-server-hop.md)）・fraud-mcp-server→account-service（`account:read`/`account:propose`）の両ホップとも1ホップ先行検証済みで、Envoy/token-exchangeサイドカー（[ADR 0019](0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)）は無変更のまま使い回せる。本実装のスコープは`app`コンテナ（MCPサーバー本体）のみであり、fraud-agent・frontend自体は引き続きスタブのままとした。

## Decision

### `services/fraud-mcp-server/`（Python/FastMCP、[ADR 0007](0007-per-service-language-selection.md)の言語選定を踏襲）

MCPツール3本を実装した。いずれもaccount-serviceへの単純な中継で、業務ロジックは持たない。

| ツール | 呼び出し先 |
|---|---|
| `get_frozen_accounts()` | `GET /accounts/frozen` |
| `get_account_history(account_id)` | `GET /accounts/{account_id}/transactions` |
| `propose_unfreeze(account_id, reasoning="")` | `POST /accounts/{account_id}/unfreeze-proposals` |

- FastMCP（`fastmcp==4.0.5`）の`http_app(path="/mcp")`が返すStarlette ASGIアプリを`Starlette(routes=[...], lifespan=mcp_app.lifespan)`でマウントし`uvicorn`で直接runする。`lifespan`を明示的に共有しないとMCPセッション管理が機能しないこと、`BaseHTTPMiddleware`がMCPのSSEストリーミングと相性が悪くASGIミドルウェアを素で書く必要があることは実機検証で判明した（詳細は[insights.md](../insights.md)「fraud-mcp-server本実装」節）
- FastMCP自体の認証機能（`auth=`）は設定しない。Envoy ingress（`jwt_authn`+`rbac`、`forward: true`で元のAuthorizationヘッダーも保持）が既にscope検証を完了させているため、アプリはそれを信頼するだけ（account-serviceの`AccountController`と同じ責務分担）
- 多層防御（ADR 0009 §2、account-serviceの`SecurityHeadersFilter.java`と同じ2点：①接続元loopback再チェック、②合言葉ヘッダー検証）を素のASGIミドルウェアとして移植した。既存のPythonスタブのロジック・環境変数名（`APP_BIND_HOST`/`APP_PORT`/`HANDSHAKE_HEADER_NAME`/`HANDSHAKE_TOKEN_FILE`）をそのまま踏襲した（backlog.mdの命名統一方針を継続）
- 各ツール内で`fastmcp.server.dependencies.get_http_headers(include={"authorization"})`（例外を投げない安全なAPI）で受信した元のAuthorizationヘッダーをそのままaccount-serviceへのリクエストに転送する。アプリ自身はToken Exchangeを一切行わない。egressのtoken-exchangeサイドカー（ADR 0019。無変更）がこれをsubject_tokenとして横取りし、新しいトークンへ差し替えてから実際のaccount-serviceへ転送する（account-serviceの`AnalystAttributeClient.java`と同型のパターン）
- account-service呼び出しは`httpx.AsyncClient(base_url=ACCOUNT_SERVICE_URL)`（既定`http://account-service/`、hostAliasesで127.0.0.1へ横取りされる。新規env var、account-serviceの`ANALYST_ATTRIBUTE_SERVICE_URL`と同型）。非200・接続失敗はいずれも`ToolError`に変換し、account-service側のレスポンス本文（存在秘匿の404・権限不足の403等）をそのまま漏らさない一律のfail-close（ADR 0009の思想を踏襲）
- 診断用に`GET /healthz`（プレーンJSON 200固定、Envoy ingressの同じscope検証配下）を追加した。理由は後述

### `services/fraud-mcp-server/Dockerfile`

このリポジトリ初のPython本実装Dockerfile。`python:3.12-slim`（Debian/glibc。musl由来のwheel互換性リスクを避けるためalpineは使わない）でビルダー段が`/opt/venv`へpip install、実行段は同じベースイメージへ`/opt/venv`だけコピーし非rootユーザー（`useradd`）で実行するマルチステージ構成にした。`requirements.txt`はビルド後の`pip freeze`で依存関係グラフ全体を完全ピン留めした（Cargo.lock/go.sumと同じ再現性の考え方）。実行イメージが`python:3.12-slim`（distrolessではない）であるため`python3`バイナリが残り、`scripts/verify-hop.sh`の既存の`kubectl exec -c app -- python3 -c '...'`によるaccount-serviceへの手動リクエスト送信ステップは無変更で動作した（fraud-detection-engineがRust静的バイナリ化でシェルを失い診断用ループバックAPIへの置き換えが必要になったのとは異なる。ADR 0027対比）。

### `k8s/fraud-mcp-server/`の変更

- `app-configmap.yaml`：削除（ConfigMap embedded scriptからビルド済みイメージへ置き換わったため）
- `deployment.yaml`：`app`コンテナのみ変更（`gekko07/fraud-mcp-server:local`イメージ・`imagePullPolicy: IfNotPresent`・`ACCOUNT_SERVICE_URL`env var追加・ConfigMapボリューム削除）。Deployment名を`fraud-mcp-server-stub`→`fraud-mcp-server`へリネームした（account-service等の昇格済みサービスと同じ命名）
- `envoy-configmap.yaml`・`token-exchange-app-configmap.yaml`・`networkpolicy.yaml`・`service.yaml`：無変更（app_upstreamクラスタは既に`127.0.0.1:9000`固定であり、実装がスタブから実アプリに変わってもEnvoy設定に影響しない）

### `k8s/fraud-agent/app-configmap.yaml`の疎通確認先を`/healthz`へ変更

fraud-agent-stubは元々fraud-mcp-serverのスタブ実装への疎通確認として素のGETを送っていたが、FastMCP実装後はMCPプロトコル外の素のGETは`/mcp`で200を返さない。fraud-agent自体は本実装のスコープ外のため、`FRAUD_MCP_SERVER_URL`の既定値を`http://fraud-mcp-server/healthz`に変更する1行だけの最小限の編集で対応した（詳細は[insights.md](../insights.md)参照）。

### Makefileをbase trackへ格上げする

fraud-mcp-serverは自身のDBを持たないため、account-service・fraud-detection-engine等と違いdb-init Job・NetworkPolicy前倒し適用は不要（NetworkPolicyは元々`deploy-network-policy`で全サービス分をまとめて適用済み）。`build-fraud-mcp-server`ターゲットを新設し、`deploy`/`undeploy`へ組み込み、`deploy-verify-hop`/`undeploy-verify-hop`からは除外した。クリーンな状態からの`make deploy && make deploy-verify-hop && make verify-hop`を実機で確認し、既存アサーションが警告ゼロで通ることを確認した。

## Consequences

- README.md・docs/services.mdの進捗を「account-service・analyst-attribute-service・fraud-detection-engineが本実装済み」から「fraud-mcp-serverも本実装済み」へ更新した。残るfraud-agent・frontendは引き続きスタブのまま
- `scripts/verify-hop.sh`のstep 2a/2b/2cはfraud-mcp-serverの`app`コンテナへの`kubectl exec`による手動HTTPリクエストという検証方法自体を変えずに済んだ（前述の通り`python:3.12-slim`が`python3`を残すため）。実際にaccount-serviceの実データ（口座123の取引履歴・凍結解除案の記録）が返ることを実機確認した
- fraud-agentの本実装に着手する際は、MCPクライアントとして`http://fraud-mcp-server/mcp`（Streamable HTTP transport、`initialize`から始まる正規のMCPセッション）を使う必要がある。詳細は[insights.md](../insights.md)参照
- 残るfraud-agent・frontendの本実装は引き続きbacklog外（README.mdのチェックリストで追跡）
