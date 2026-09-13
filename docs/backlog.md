# バックログ

未着手の改善項目・未決定事項。着手時はこのファイルから該当項目を削除し、必要ならarchitecture.md/services.md/insights.mdへ結果を記録する。

## Token Exchange / Envoyサイドカー

- **先行検証するホップの確定**：[ADR 0002](adr/0002-token-exchange-in-envoy-sidecar.md)で「1ホップ先行検証→横展開」の方針は決めたが、対象ホップ（fraud-mcp-server→account-service想定）の具体的な実装（Envoy bootstrap設定、ext_authzサービスのプロトコル：HTTPモード想定）はこれから
- **scope検証をサイドカー側（受信側）に寄せるか**：[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)の通り、scopeの検証（表2）はトークン単体で完結するためEnvoyの`jwt_authn`＋`rbac`フィルタ等でaccount-serviceのアプリコードに到達する前に判定できる余地がある。ABAC判定（表5）はアプリ内に残さざるを得ないため、scope検証だけを切り出すかどうかは未定
- **DPoPの適用範囲**：フロントエンド接点（ブラウザ〜frontend間）のみに適用するか、Envoyサイドカー化に伴いDPoP検証もサイドカー側（ext_authzまたは別フィルタ）に寄せるかは未決定
- **Token Exchange結果のキャッシュ**：`(subject jti, audience)`単位でのキャッシュを検討しているが、ext_authzサービス側に持たせるか、どの範囲で共有するかは未決定。キャッシュTTLは性能とのトレードオフを意図的に選んだ短い値にする
- **交換後トークンのアクセストークン有効期間**：[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)は、トークン漏洩・誤用時の被害範囲を抑える多層防御として交換後トークンの有効期間を短く設定する方針を前提にしている。ログイントークンとは別に、各クライアント（frontend/fraud-mcp-server/account-service）が交換で得るトークンのAccess Token Lifespanを具体的に何秒にするかは未決定

## 属性・アクセス制御の粒度

- **口座属性の拡張要否**：現状は地域(`region`)とティア(`standard`/`high-value`)の2軸のみ（access-control-design.md 表5）。実装を進める中でさらに軸が必要になるか要検討
- **アナリストの担当地域が複数ある場合の表現**：配列で持つ想定（access-control-design.md 表6）だが、Keycloakロール/属性のどちらに載せるかは未定

## 監査

- **`proposal_id`とOpenTelemetryトレース・Keycloakイベントログの統合方式**：architecture.md §8で要件のみ決めた。監査ツールを別途作るか、突合方法の詳細は未定
- **サンプリング率を下げた場合の`trace_id`保持**：サンプリング率を1.0未満に下げた状態でも`sampled=false`のリクエストのtrace_idがログに残ることを実機で確認する必要がある（未検証）

## データストア

- **本番相当環境でのインスタンス分離**：現状はローカルのメモリ制約を理由にaccount-service/payment-service/analyst-attribute-service/KeycloakのPostgreSQLを共有インスタンスにしている（ADR 0008）。本番相当の構成を検証したくなった場合、サービスごとの専用インスタンスへの切り替えを検討する
- **既定メンテナンスDB（`postgres`）への接続が全ロールに残っている**：[k8s/keycloak/db-init-configmap.yaml](../k8s/keycloak/db-init-configmap.yaml)で`keycloak`データベースはPUBLICのCONNECT権限を剥奪したが、Postgresの既定メンテナンスデータベース自体は未対応。実データを持たないため実害はないが、完全な分離ではない

## Keycloak

- **`standard.token.exchange.enabled`属性の機能的検証**：[k8s/keycloak/realm-configmap.yaml](../k8s/keycloak/realm-configmap.yaml)でfrontend/fraud-mcp-server/account-serviceに設定した属性キー。Admin REST APIで値が保持されていることは確認済みだが（`GET /admin/realms/gekko/clients`で属性が返ってくる）、実際にRFC 8693トークン交換リクエストが通ることまでは未検証（ログインフローを持つ実サービスがまだ無いため）。frontendの実装時、最初のToken Exchange検証と合わせて確認する
- **標準client scope（profile/email/roles等）の要否**：`--import-realm`での直接importでは自動生成されないため現状未定義（詳細はrealm-configmap.yamlのコメント参照）。ログイントークンに`preferred_username`等が必要になった時点でclientScopesに明示定義を追加する

## インフラ

- **k3dクラスタの複数ノード化**：現状`servers: 1, agents: 0`（k3d/cluster-config.yaml）。スケジューリングの検証が必要になった場合はagentノードを追加するか検討
- **WSL2 cgroup v2化の恒久性**：`.wslconfig`の`kernelCommandLine = cgroup_no_v1=all`で対応済み（insights.md参照）だが、Windows Update等で設定が失われないかは未検証
