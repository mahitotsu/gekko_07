# gekko_07

OAuth 2.0 Token Exchange (RFC 8693) をEnvoyサイドカー（ext_authz）に実装し、マイクロサービス群とAIエージェントが連携するローカル実行可能なサンプル。**現在は設計段階**（k3dクラスタの土台のみ実装済み）。目的・背景・要求水準は[docs/requirements.md](docs/requirements.md)を参照。

想定ユースケースは金融の不正検知・口座凍結（[ADR 0001](docs/adr/0001-scenario-fraud-detection-with-agent-assist.md)）。AIエージェントが取引パターンから凍結を提案し、アナリストが確認の上で決定論的な操作を行って初めて確定する。エージェントの権限はKeycloakのスコープ設計で読み取り・提案のみに制限し、実行権限（凍結）は一切持たせない。

## 現在の進捗

- [x] k3dクラスタの土台（[k3d/cluster-config.yaml](k3d/cluster-config.yaml)、[Makefile](Makefile)）
- [x] シナリオ・サービス構成・権限設計（本READMEの「ドキュメントの読み方」参照）
- [ ] Keycloak realm・クライアント設定
- [ ] 各サービスの実装
- [ ] Envoyサイドカー・ext_authzサービス
- [ ] MCPサーバー・AIエージェント

## クイックスタート（クラスタのみ）

```
make up      # k3dクラスタを作成（既に存在すれば何もしない）
make status  # クラスタ・ノードの状態確認
make stop    # クラスタを停止（状態は保持）
make start   # 停止したクラスタを再開
make down    # クラスタを完全削除
```

## ドキュメントの読み方

- [docs/requirements.md](docs/requirements.md) — 目的・背景・要求水準（何を・なぜ実現するか）
- [docs/access-control-requirements.md](docs/access-control-requirements.md) — 誰が何をできて何をできてはいけないか（実装手段に触れない業務要件）
- [docs/architecture.md](docs/architecture.md) — 現在有効なアーキテクチャの断面（どう構築するか）
- [docs/adr/](docs/adr/) — 個々の設計判断の根拠・選択経緯
- [docs/services.md](docs/services.md) — 各サービスの存在意義・提供機能・保有データ
- [docs/permission-matrix.md](docs/permission-matrix.md) — 業務要件をどう実現しているかのディシジョンテーブル
- [docs/use-cases.md](docs/use-cases.md) — 具体的な業務シナリオとトークンチェーンの流れ
- [docs/insights.md](docs/insights.md) — 実装中に見つかった罠・気づき（k3d/WSL2のcgroup v1問題など）
- [docs/backlog.md](docs/backlog.md) — 未着手の改善項目・未決定事項

## License

[MIT](LICENSE)
