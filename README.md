# gekko_07

OAuth 2.0 Token Exchange (RFC 8693) をEnvoyサイドカー（ext_authz）に実装し、マイクロサービス群とAIエージェントが連携するローカル実行可能なサンプル。**現在は設計段階**（k3dクラスタの土台のみ実装済み）。目的・背景・要求水準は[docs/requirements.md](docs/requirements.md)を参照。

想定ユースケースは金融の不正検知・口座凍結（[ADR 0001](docs/adr/0001-scenario-fraud-detection-with-agent-assist.md)）。AIエージェントが取引パターンから凍結を提案し、アナリストが確認の上で決定論的な操作を行って初めて確定する。エージェントの権限はKeycloakのスコープ設計で読み取り・提案のみに制限し、実行権限（凍結）は一切持たせない。

## 現在の進捗

- [x] k3dクラスタの土台（[k3d/cluster-config.yaml](k3d/cluster-config.yaml)、[Makefile](Makefile)）
- [x] シナリオ・サービス構成・権限設計・各サービスの技術スタック（本READMEの「ドキュメントの読み方」参照）
- [x] Keycloak realm・クライアント設定（[k8s/keycloak/](k8s/keycloak/)。PostgreSQLへ永続化（[k8s/postgres/](k8s/postgres/)、[ADR 0008](docs/adr/0008-per-service-datastore-strategy.md)）。実機検証内容・未検証事項は[docs/insights.md](docs/insights.md)・[docs/backlog.md](docs/backlog.md)参照）
- [ ] 各サービスの実装
- [ ] Envoyサイドカー・ext_authzサービス
- [ ] MCPサーバー・AIエージェント

## クイックスタート

```
make up               # k3dクラスタを作成し、Keycloakをデプロイする（既に存在すれば作成をスキップ）
make status            # クラスタ・ノード・アプリPodの状態確認
make keycloak-forward   # localhost:3000 -> Keycloakへport-forward（フォアグラウンドで動き続ける）
make deploy             # アプリ層（Keycloak）だけを再デプロイ（クラスタは起動済み前提）
make undeploy           # アプリ層だけを削除（クラスタは残す）
make stop               # クラスタを停止（状態は保持）
make start              # 停止したクラスタを再開
make down               # クラスタを完全削除
```

`make keycloak-forward`を実行した状態で`http://localhost:3000`にアクセスすると管理コンソールに到達できる。管理者ユーザー名・パスワードは`make deploy`実行時に標準出力へ表示される（`.secrets/`にも保存され、以後の`make deploy`では同じ値。ただしPostgresへの永続化後は初回ブートストラップ時のみ有効な値になる点に注意。詳細はMakefileのコメント参照）。

## ドキュメントの読み方

- [docs/requirements.md](docs/requirements.md) — 目的・背景・要求水準（何を・なぜ実現するか）
- [docs/access-control-requirements.md](docs/access-control-requirements.md) — 誰が何をできて何をできてはいけないか（実装手段に触れない業務要件）
- [docs/architecture.md](docs/architecture.md) — 現在有効なアーキテクチャの断面（どう構築するか）
- [docs/adr/](docs/adr/) — 個々の設計判断の根拠・選択経緯
- [docs/services.md](docs/services.md) — 各サービスの存在意義・提供機能・保有データ
- [docs/access-control-design.md](docs/access-control-design.md) — 業務要件をどう実現しているかのディシジョンテーブル
- [docs/use-cases.md](docs/use-cases.md) — 具体的な業務シナリオとトークンチェーンの流れ
- [docs/insights.md](docs/insights.md) — 実装中に見つかった罠・気づき（k3d/WSL2のcgroup v1問題など）
- [docs/backlog.md](docs/backlog.md) — 未着手の改善項目・未決定事項

## License

[MIT](LICENSE)
