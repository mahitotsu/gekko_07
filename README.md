# gekko_07

誰のどんな課題を解決し、どんな利益を提供するプロジェクトかは[docs/prfaq.md](docs/prfaq.md)を参照。

OAuth 2.0 Token Exchange (RFC 8693) をEnvoyサイドカー（ext_authz）に実装し、マイクロサービス群とAIエージェントが連携するローカル実行可能なサンプル。**全サービス（account-service・analyst-attribute-service・fraud-detection-engine・fraud-mcp-server・fraud-agent・frontend）の本実装が完了し、インフラ・セキュリティ層（Token Exchange・SPIFFE/SPIRE mTLS・NetworkPolicy・監査ログ集約）を含め実機検証済みの段階**。目的・背景・要求水準は[docs/requirements.md](docs/requirements.md)を参照。

想定ユースケースは金融の不正検知・口座凍結解除（[ADR 0001](docs/adr/0001-scenario-fraud-detection-with-agent-assist.md)・[ADR 0011](docs/adr/0011-scenario-ai-assisted-unfreeze.md)）。取引パターンから自動検知エンジンが口座を自動的に凍結し、AIエージェントが凍結の妥当性を分析して解除を提案、アナリストが確認の上で決定論的な操作を行って初めて解除が確定する。エージェントの権限はKeycloakのスコープ設計で読み取り・提案のみに制限し、実行権限（凍結解除）は一切持たせない。

各サービスの実装詳細・技術スタックは[docs/services.md](docs/services.md)、実装の経緯は[docs/adr/](docs/adr/)を参照。

## クイックスタート

```
make up               # k3dクラスタを作成し、アプリ層一式をデプロイする（既に存在すれば作成をスキップ）
make status            # クラスタ・ノード・アプリPodの状態確認
make network-status     # NetworkPolicy(通信許可)とEnvoyサイドカーの実プロトコル(mTLS/plaintext)を突き合わせて確認
make keycloak-forward   # localhost:3000 -> edge-proxy経由でKeycloakへport-forward（フォアグラウンドで動き続ける）
make deploy             # アプリ層一式（Postgres・SPIRE・Keycloak・edge-proxy・全マイクロサービス・frontend・監査ログ集約基盤・NetworkPolicy）を再デプロイ（クラスタは起動済み前提）
make undeploy           # アプリ層だけを削除（クラスタは残す）
make stop               # クラスタを停止（状態は保持）
make start              # 停止したクラスタを再開
make down               # クラスタを完全削除

make deploy-verify-hop  # テスト用Keycloakフィクスチャ(表6のテストアナリスト属性等)をデプロイ（make deploy実行済み前提）
make verify-hop         # 上記の検証スクリプトを実行
make undeploy-verify-hop # 上記のテストフィクスチャを削除
make grafana-forward    # localhost:3000 -> Grafana(otel-lgtm)へport-forward（keycloak-forwardとローカルポートが競合するため同時利用不可）
make verify-observability # 監査ログ集約基盤の検証スクリプトを実行（deploy-observability・deploy-verify-hop実行済み前提）
```

`make keycloak-forward`を実行した状態で`http://localhost:3000`にアクセスすると管理コンソールに到達できる。管理者ユーザー名・パスワードは`make deploy`実行時に標準出力へ表示される（`.secrets/`にも保存され、以後の`make deploy`では同じ値。ただしPostgresへの永続化後は初回ブートストラップ時のみ有効な値になる点に注意。詳細はMakefileのコメント参照）。

`make deploy`はfraud-agent（[ADR 0030](docs/adr/0030-fraud-agent-implementation.md)）向けに`CLAUDE_CODE_OAUTH_TOKEN`（`claude setup-token`で取得したOAuthトークン）を要求する。未設定の場合は明確なエラーで停止するので、`echo -n 'sk-ant-oat01-...' > .secrets/claude-code-oauth-token`として保存するか、環境変数として渡してから実行すること（他のシークレットと同じく`.secrets/`に保存され、以後の`make deploy`では同じ値を再利用する）。

## ドキュメントの読み方

文書間の依存関係・優先順位（矛盾時にどちらを正とするか）は[CLAUDE.md](CLAUDE.md)「文書の依存関係と優先順位」を参照。

- [docs/prfaq.md](docs/prfaq.md) — 誰のどんな課題を解決し、どんな利益を提供するか（PR/FAQ、最初に読むべき一枚）
- [docs/requirements.md](docs/requirements.md) — 目的・背景・要求水準（何を・なぜ実現するか）。誰が何をできて何をできてはいけないかという業務要件（BR番号）を含む
- [docs/architecture.md](docs/architecture.md) — 現在有効なアーキテクチャの断面（どう構築するか）。業務要件をどう実現しているかのディシジョンテーブル（§6）・具体的なリクエストフローのend-to-end検証ウォークスルー（§10）・未着手の改善項目（§11）を含む
- [docs/adr/](docs/adr/) — architecture.mdの個々の決定の根拠・選択経緯（[索引](docs/adr/README.md)）
- [docs/services.md](docs/services.md) — 各サービスの存在意義・提供機能・保有データの参照カタログ
- [docs/insights.md](docs/insights.md) — 実装中に見つかった罠・気づき（k3d/WSL2のcgroup v1問題など）

## License

[MIT](LICENSE)
