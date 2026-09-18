# gekko_07

OAuth 2.0 Token Exchange (RFC 8693) をEnvoyサイドカー（ext_authz）に実装し、マイクロサービス群とAIエージェントが連携するローカル実行可能なサンプル。**現在はインフラ・セキュリティ層（Token Exchange・SPIFFE/SPIRE mTLS・NetworkPolicy・監査ログ集約）の実機検証を終え、account-service・analyst-attribute-service（[ADR 0026](docs/adr/0026-account-service-analyst-attribute-service-implementation.md)）・fraud-detection-engine（[ADR 0027](docs/adr/0027-fraud-detection-engine-implementation.md)）の本実装が完了した段階**（残るfraud-mcp-server・fraud-agent・frontendの本実装は未着手で、検証用スタブのみ実装済み）。目的・背景・要求水準は[docs/requirements.md](docs/requirements.md)を参照。

想定ユースケースは金融の不正検知・口座凍結解除（[ADR 0001](docs/adr/0001-scenario-fraud-detection-with-agent-assist.md)・[ADR 0011](docs/adr/0011-scenario-ai-assisted-unfreeze.md)）。取引パターンから自動検知エンジンが口座を自動的に凍結し、AIエージェントが凍結の妥当性を分析して解除を提案、アナリストが確認の上で決定論的な操作を行って初めて解除が確定する。エージェントの権限はKeycloakのスコープ設計で読み取り・提案のみに制限し、実行権限（凍結解除）は一切持たせない。

## 現在の進捗

- [x] k3dクラスタの土台（[k3d/cluster-config.yaml](k3d/cluster-config.yaml)、[Makefile](Makefile)）
- [x] シナリオ・サービス構成・権限設計・各サービスの技術スタック（本READMEの「ドキュメントの読み方」参照）
- [x] Keycloak realm・クライアント設定（[k8s/keycloak/](k8s/keycloak/)。PostgreSQLへ永続化（[k8s/postgres/](k8s/postgres/)、[ADR 0008](docs/adr/0008-per-service-datastore-strategy.md)）。実機検証内容・未検証事項は[docs/insights.md](docs/insights.md)・[docs/backlog.md](docs/backlog.md)参照）
- [x] Envoy/ext_authzによるOAuth Token Exchange・client_credentialsの全6ホップ先行検証（fraud-mcp-server→account-service`account:read`/`account:propose`、fraud-detection-engine→account-service`account:freeze`、account-service→analyst-attribute-service`analyst:read`、fraud-agent→fraud-mcp-server`account:read`（[ADR 0023](docs/adr/0023-fraud-agent-fraud-mcp-server-hop.md)）、frontend→account-service`account:read`/`account:unfreeze`・frontend→fraud-agent`account:read`（[ADR 0024](docs/adr/0024-frontend-edge-proxy-and-simplified-login.md)）。[k8s/fraud-mcp-server/](k8s/fraud-mcp-server/)・[k8s/fraud-detection-engine/](k8s/fraud-detection-engine/)・[k8s/account-service/](k8s/account-service/)・[k8s/analyst-attribute-service/](k8s/analyst-attribute-service/)・[k8s/fraud-agent/](k8s/fraud-agent/)・[k8s/frontend/](k8s/frontend/)、`make deploy-verify-hop && make verify-hop`。当時はいずれもスタブ実装だったが、account-service・analyst-attribute-serviceはその後本実装に置き換わり（[ADR 0026](docs/adr/0026-account-service-analyst-attribute-service-implementation.md)）、fraud-detection-engineも本実装に置き換わった（[ADR 0027](docs/adr/0027-fraud-detection-engine-implementation.md)）。詳細は[docs/insights.md](docs/insights.md)・[docs/backlog.md](docs/backlog.md)参照）
- [x] 全ホップのSPIFFE/SPIRE mTLS化とKeycloakクライアント認証のSPIRE発行JWT-SVIDへの移行（[ADR 0012](docs/adr/0012-spiffe-spire-mtls-single-hop.md)・[0015](docs/adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)・[0017](docs/adr/0017-edge-proxy-full-keycloak-mtls.md)・[0019](docs/adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)・[0020](docs/adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)・[0021](docs/adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)・[0023](docs/adr/0023-fraud-agent-fraud-mcp-server-hop.md)・[0024](docs/adr/0024-frontend-edge-proxy-and-simplified-login.md)）。Token Exchange/client_credentials実行主体は各呼び出し元自身のPod内サイドカーに置き、Keycloakが検証する身元と主張するclient_idの不一致という身元検証上のギャップが生じない構成にした。共有ext-authz-serviceインスタンス方式は全廃済み。account-service・Keycloakのplaintext受け口も撤廃済み。fraud-agent・frontend方向への横展開も完了済み
- [x] NetworkPolicyによるgekko namespace全体のL3/4 default-deny（[ADR 0018](docs/adr/0018-network-policy-default-deny.md)）。Keycloakのkubelet向けhttp-mgmt(9000)はexecプローブ化しloopback限定に格上げ済み（[ADR 0022](docs/adr/0022-keycloak-mgmt-probe-exec.md)）
- [x] 監査ログ集約基盤（Alloy + otel-lgtm）によるBR8（事後追跡可能性）の実現（[ADR 0025](docs/adr/0025-audit-log-aggregation.md)。詳細は[docs/architecture.md](docs/architecture.md) §8参照）
- [x] account-service（Java/Spring Boot）・analyst-attribute-serviceの本実装（Go）。表2のAPI・表5のABAC判定を実データで実現し、Postgres永続化・Docker/k3d image importによるビルドパイプラインを新設した（[ADR 0026](docs/adr/0026-account-service-analyst-attribute-service-implementation.md)。[k8s/account-service/](k8s/account-service/)・[k8s/analyst-attribute-service/](k8s/analyst-attribute-service/)・[services/](services/)、`make deploy`側のbase trackに統合済み）
- [x] fraud-detection-engineの本実装（Rust/Axum）。自身のPostgreSQLに検知ルール・観測シグナルを持ち、定期スキャンでaccount-serviceへclient_credentials（`account:freeze`）による凍結を自律的に依頼する（UC0）。account-serviceのデモ用凍結シード（ADR 0026）はこの自動実行に置き換えた（[ADR 0027](docs/adr/0027-fraud-detection-engine-implementation.md)。[k8s/fraud-detection-engine/](k8s/fraud-detection-engine/)・[services/fraud-detection-engine/](services/fraud-detection-engine/)、`make deploy`側のbase trackに統合済み）
- [ ] 残るサービスの実装（本実装。fraud-mcp-server・fraud-agent・frontendはいずれも現状Envoy/SPIRE検証用スタブのみで、frontendのログインも簡易ログイン（ROPC）で代用中。詳細は[docs/services.md](docs/services.md)参照）

## クイックスタート

```
make up               # k3dクラスタを作成し、アプリ層一式をデプロイする（既に存在すれば作成をスキップ）
make status            # クラスタ・ノード・アプリPodの状態確認
make keycloak-forward   # localhost:3000 -> edge-proxy経由でKeycloakへport-forward（フォアグラウンドで動き続ける）
make deploy             # アプリ層（Postgres・SPIRE・Keycloak・edge-proxy・account-service・analyst-attribute-service・監査ログ集約基盤・NetworkPolicy）を再デプロイ（クラスタは起動済み前提）
make undeploy           # アプリ層だけを削除（クラスタは残す）
make stop               # クラスタを停止（状態は保持）
make start              # 停止したクラスタを再開
make down               # クラスタを完全削除

make deploy-verify-hop  # 残るスタブ一式(fraud-mcp-server等)とテストアナリスト属性をデプロイ（make deploy実行済み前提）
make verify-hop         # 上記の検証スクリプトを実行
make undeploy-verify-hop # 上記のスタブ一式を削除
make grafana-forward    # localhost:3000 -> Grafana(otel-lgtm)へport-forward（keycloak-forwardとローカルポートが競合するため同時利用不可）
make verify-observability # 監査ログ集約基盤の検証スクリプトを実行（deploy-observability・deploy-verify-hop実行済み前提）
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
