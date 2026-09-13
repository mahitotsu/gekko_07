# gekko_07

Token Exchange (RFC 8693) をEnvoyサイドカーへ移し、マイクロサービス群にAIエージェントを組み込むサンプル。**現在は設計段階**（k3dクラスタの土台のみ実装済み）。目的・背景・要求水準は[docs/requirements.md](docs/requirements.md)を参照。

前作[gekko_05](../gekko_05)はToken Exchangeをアプリ層に実装する学習用サンプルだった。本リポジトリはその発展として、(1) Token Exchangeをサービスの実装言語に依存しないEnvoyサイドカーへ移す、(2) マイクロサービス群にAIエージェントを組み込み、エージェントの権限をスコープで厳格に制限しつつ最終判断は人間の決定論的操作で確定する設計を示す、の2点を新たに実演する（gekko_05との違いは[docs/requirements.md](docs/requirements.md)の対比表を参照）。

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
- [docs/architecture.md](docs/architecture.md) — 現在有効なアーキテクチャの断面（どう構築するか）
- [docs/adr/](docs/adr/) — 個々の設計判断の根拠・選択経緯
- [docs/services.md](docs/services.md) — 各サービスの存在意義・提供機能・保有データ
- [docs/permission-matrix.md](docs/permission-matrix.md) — 認可のディシジョンテーブル
- [docs/use-cases.md](docs/use-cases.md) — 具体的な業務シナリオとトークンチェーンの流れ
- [docs/insights.md](docs/insights.md) — 実装中に見つかった罠・気づき（k3d/WSL2のcgroup v1問題など）
- [docs/backlog.md](docs/backlog.md) — 未着手の改善項目・未決定事項

## License

[MIT](LICENSE)
