# gekko_07

OAuth 2.0 Token Exchange (RFC 8693) をEnvoyサイドカー（ext_authz）に実装し、マイクロサービス群とAIエージェントが連携するローカル実行可能なサンプル。**現在はインフラ・セキュリティ層（Token Exchange・SPIFFE/SPIRE mTLS・NetworkPolicy）をスタブサービス相手に実機検証済みの段階**（各サービスの本実装・frontend・AIエージェントは未着手）。目的・背景・要求水準は[docs/requirements.md](docs/requirements.md)を参照。

想定ユースケースは金融の不正検知・口座凍結解除（[ADR 0001](docs/adr/0001-scenario-fraud-detection-with-agent-assist.md)・[ADR 0011](docs/adr/0011-scenario-ai-assisted-unfreeze.md)）。取引パターンから自動検知エンジンが口座を自動的に凍結し、AIエージェントが凍結の妥当性を分析して解除を提案、アナリストが確認の上で決定論的な操作を行って初めて解除が確定する。エージェントの権限はKeycloakのスコープ設計で読み取り・提案のみに制限し、実行権限（凍結解除）は一切持たせない。

## 現在の進捗

- [x] k3dクラスタの土台（[k3d/cluster-config.yaml](k3d/cluster-config.yaml)、[Makefile](Makefile)）
- [x] シナリオ・サービス構成・権限設計・各サービスの技術スタック（本READMEの「ドキュメントの読み方」参照）
- [x] Keycloak realm・クライアント設定（[k8s/keycloak/](k8s/keycloak/)。PostgreSQLへ永続化（[k8s/postgres/](k8s/postgres/)、[ADR 0008](docs/adr/0008-per-service-datastore-strategy.md)）。実機検証内容・未検証事項は[docs/insights.md](docs/insights.md)・[docs/backlog.md](docs/backlog.md)参照）
- [x] Envoy/ext_authzによるOAuth Token Exchange・client_credentialsの2パターン先行検証（パターン①fraud-mcp-server→account-service`account:read`/`account:propose`、パターン②fraud-detection-engine→account-service`account:freeze`。[k8s/fraud-mcp-server/](k8s/fraud-mcp-server/)・[k8s/fraud-detection-engine/](k8s/fraud-detection-engine/)・[k8s/account-service/](k8s/account-service/)、`make deploy-verify-hop && make verify-hop`。いずれもスタブ実装。詳細は[docs/insights.md](docs/insights.md)・[docs/backlog.md](docs/backlog.md)参照）
- [x] SPIFFE/SPIRE mTLS（fraud-mcp-server・fraud-detection-engine→account-service、fraud-mcp-server・fraud-detection-engine・account-service・edge-proxy↔Keycloak。[ADR 0012](docs/adr/0012-spiffe-spire-mtls-single-hop.md)・[0015](docs/adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)・[0016](docs/adr/0016-ext-authz-and-keycloak-mtls.md)・[0017](docs/adr/0017-edge-proxy-full-keycloak-mtls.md)。account-service・Keycloakのplaintext受け口は撤廃済み）
- [x] fraud-mcp-server→account-serviceのToken Exchange（[ADR 0019](docs/adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)）・fraud-detection-engine→account-serviceのclient_credentials（[ADR 0020](docs/adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)）のクライアント認証をいずれもclient_secretからSPIRE発行JWT-SVID（KeycloakネイティブのSPIFFE対応）へ移行し、実行主体を共有ext-authz-serviceから各呼び出し元自身のPod内サイドカーへ移した。Keycloakが検証する身元と主張するclient_idの不一致という身元検証上のギャップを解消し、共有ext-authz-serviceインスタンス方式は全廃した（account-service→analyst-attribute-serviceへの横展開は未着手、docs/backlog.md参照）
- [x] NetworkPolicyによるgekko namespace全体のL3/4 default-deny（[ADR 0018](docs/adr/0018-network-policy-default-deny.md)）
- [ ] 各サービスの実装（本実装。現状はスタブのみ）
- [ ] frontend・MCPサーバー・AIエージェント

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

make deploy-verify-hop  # Envoy/ext_authzの1ホップ先行検証用スタブ一式をデプロイ（make deploy実行済み前提）
make verify-hop         # 上記の検証スクリプトを実行
make undeploy-verify-hop # 1ホップ先行検証用スタブ一式を削除
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
