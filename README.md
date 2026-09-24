# gekko_07

誰のどんな課題を解決し、どんな利益を提供するプロジェクトかは[docs/prfaq.md](docs/prfaq.md)を参照。

OAuth 2.0 Token Exchange (RFC 8693) をEnvoyサイドカー（ext_authz）に実装し、マイクロサービス群とAIエージェントが連携するローカル実行可能なサンプル。全7サービス（frontend・fraud-agent・fraud-mcp-server・account-service・analyst-attribute-service・fraud-detection-engine・audit-service）が本実装済みで、インフラ・セキュリティ層（Token Exchange・SPIFFE/SPIRE mTLS・NetworkPolicy・監査ログ集約）を含めk3d上で実機検証している。目的・背景・要求水準は[docs/requirements.md](docs/requirements.md)を参照。

想定ユースケースは金融の不正検知・口座凍結解除（[ADR 0011](docs/adr/0011-scenario-ai-assisted-unfreeze.md)）。取引パターンから自動検知エンジンが口座を自動的に凍結し、AIエージェントが凍結の妥当性を分析して解除を提案、アナリストが確認の上で決定論的な操作を行って初めて解除が確定する。エージェントの権限はKeycloakのスコープ設計で読み取り・提案のみに制限し、実行権限（凍結解除）は一切持たせない。

## クイックスタート

前提：Docker・k3d・kubectl・make・python3（`make network-status`用）。WSL2で動かす場合はcgroup v2化が必要（[docs/insights.md](docs/insights.md)「k3d / WSL2」）。fraud-agent用に`claude setup-token`で取得したOAuthトークンを用意する（下記）。

```
make up                   # k3dクラスタを作成し、アプリ層一式をデプロイする
make deploy-verify-hop    # テストアナリスト（yamada-analyst・suzuki-senior・tanaka-junior）を投入する
make keycloak-forward     # localhost:3000 -> edge-proxyへport-forward（フォアグラウンドで動き続ける）
```

この状態で`http://localhost:3000`を開くと、Keycloakのログイン画面へリダイレクトされる（ログイン後はfrontendのダッシュボード）。テストアナリストのパスワードは`.secrets/<アナリスト名>-password`（例：`.secrets/yamada-analyst-password`）にある。各アナリストの担当地域・権限レベルは[docs/architecture.md](docs/architecture.md) 表6を参照（監査画面はsenior analystの`suzuki-senior`のみ閲覧できる）。

`make deploy`はfraud-agent（[ADR 0030](docs/adr/0030-fraud-agent-implementation.md)）向けに`CLAUDE_CODE_OAUTH_TOKEN`（`claude setup-token`で取得したOAuthトークン）を要求する。未設定の場合は明確なエラーで停止するので、`echo -n 'sk-ant-oat01-...' > .secrets/claude-code-oauth-token`として保存するか、環境変数として渡してから実行すること（他のシークレットと同じく`.secrets/`に保存され、以後の`make deploy`では同じ値を再利用する）。

Keycloakの管理コンソールも同じ`http://localhost:3000/admin/`で開ける。管理者ユーザー名・パスワードは`make deploy`実行時に標準出力へ表示される（`.secrets/`にも保存される。ただしPostgresへの永続化後は初回ブートストラップ時の値だけが有効。詳細はMakefileのコメント参照）。

## makeターゲット

| 分類 | ターゲット | 内容 |
|---|---|---|
| クラスタ | `make up` | k3dクラスタを作成し、`make deploy`を実行する（クラスタが既に存在すれば作成をスキップ） |
| | `make stop` / `make start` | クラスタを停止（状態は保持）／再開 |
| | `make down` | クラスタを完全削除 |
| | `make status` | クラスタ・ノード・各namespaceのPodの状態確認 |
| | `make network-status` | NetworkPolicy（通信許可）とEnvoyサイドカーの実プロトコル（mTLS/plaintext）を突き合わせて表示 |
| アプリ層 | `make deploy` | アプリ層一式（Postgres・SPIRE・Keycloak・edge-proxy・全サービス・監査ログ集約基盤・NetworkPolicy）を（再）デプロイ（クラスタ起動済み前提） |
| | `make undeploy` | アプリ層だけを削除（クラスタは残す。PostgresのPVCも削除する） |
| | `make sync` | 全サービスを再ビルドし、イメージが変わったサービスだけrollout restartする（開発ループ用） |
| | `make keycloak-reimport-realm` | `k8s/keycloak/realm-configmap.yaml`の変更をKeycloakへ反映する（realmを削除して再import。実行後は`make deploy-verify-hop`が必要） |
| アクセス | `make keycloak-forward` | `localhost:3000` → edge-proxy（frontend・Keycloak） |
| | `make grafana-forward` | `localhost:3000` → Grafana（otel-lgtm）。`keycloak-forward`とローカルポートが競合するため同時利用不可 |
| 検証 | `make deploy-verify-hop` / `make undeploy-verify-hop` | テストアナリスト（Keycloakユーザー＋業務属性）を投入／削除 |
| | `make verify-hop` | 委任チェーン全ホップのToken Exchange・mTLS・NetworkPolicyを検証する（`deploy-verify-hop`実行済み前提） |
| | `make verify-observability` | 監査ログ集約基盤を検証する（`deploy-verify-hop`実行済み前提） |
| | `make verify-audit-service` | audit-serviceの突合とsenior限定ゲートを検証する（`verify-hop`実行済み前提） |

## ドキュメントの読み方

| 文書 | 内容 |
|---|---|
| [docs/prfaq.md](docs/prfaq.md) | 誰のどんな課題を解決し、どんな利益を提供するか（PR/FAQ、最初に読むべき一枚） |
| [docs/requirements.md](docs/requirements.md) | 目的・背景・要求水準（何を・なぜ実現するか）。業務要件（BR0〜BR11） |
| [docs/architecture.md](docs/architecture.md) | 現在有効なアーキテクチャの断面（どう実現するか）。ディシジョンテーブル（§6）・実行時シナリオ（§10）・既知の制約と未着手事項（§11）を含む |
| [docs/adr/](docs/adr/) | 個々の設計判断の根拠・選択経緯（[テーマ別索引](docs/adr/README.md)） |
| [docs/services.md](docs/services.md) | 各サービスの存在意義・提供機能・保有データの参照カタログ |
| [docs/insights.md](docs/insights.md) | 実装・実機検証で見つかった罠（症状/原因/対応） |

文書間の依存関係・優先順位（矛盾時にどちらを正とするか）と更新ルールは[CLAUDE.md](CLAUDE.md)を参照。

## License

[MIT](LICENSE)
