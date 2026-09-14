# バックログ

未着手の改善項目・未決定事項。着手時はこのファイルから該当項目を削除し、必要ならarchitecture.md/services.md/insights.mdへ結果を記録する。

## Token Exchange / Envoyサイドカー

- **client_credentials発行・素通し・トークンを値として取得する3パターンの実機検証**：[ADR 0010](adr/0010-egress-listener-granularity.md)でEnvoy標準機能のみで実現できる設計（②`allowed_upstream_headers`は①と共通、③はext_authzを呼ばない単純プロキシ、④`direct_response`+`allowed_client_headers_on_success`）まで固めたが、実機での動作確認はこれから（特に④のext_authz+direct_responseの組み合わせは実機で挙動を要確認）。パターン①（Token Exchange、fraud-mcp-server→account-service）は実機検証済み（[insights.md](insights.md)参照）
- **ext-authzサービスの呼び出し元汎用化（複数クライアント対応）**：[k8s/ext-authz/](../k8s/ext-authz/)は1ホップ先行検証のため`fraud-mcp-server`のToken Exchange資格情報のみを固定で持つ。残りのホップ（frontend→account-service/fraud-mcp-server、payment-service→account-service、account-service→analyst-attribute-service）へ横展開する際、呼び出し元ごとに資格情報を切り替える仕組みが要る
- **frontendのdirectAccessGrantsEnabled一時許可の後始末**：[k8s/keycloak/test-fixtures-job.yaml](../k8s/keycloak/test-fixtures-job.yaml)は、フロントエンド未実装でもブラウザなしでログインし1ホップ先行検証を行うため、`frontend`クライアントの`directAccessGrantsEnabled`を一時的にtrueにしている。frontend実装時に、自動テストで使い続けるか、Authorization Code + PKCEのみに戻すかを判断する
- **合言葉ヘッダー名・env var名の確定**：1ホップ先行検証でヘッダー名`x-gekko-handshake`・env var名`HANDSHAKE_TOKEN_FILE`を採用し、Python実装のスタブ間で統一した（[k8s/account-service/app-configmap.yaml](../k8s/account-service/app-configmap.yaml)等）。Java/TypeScript/Rust/Go等、他言語での本実装時にも同じ命名を踏襲する
- **Unixドメインソケット化の再検討**：[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)でTCP loopback+合言葉方式を採用しUnixドメインソケット化は見送ったが、「同一Pod内でアプリが侵害された場合」まで守る要求が出てきたら再検討する
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

- **`standard.token.exchange.enabled`属性の機能的検証**：1ホップ先行検証（frontend→fraud-mcp-server、fraud-mcp-server→account-service）でRFC 8693トークン交換リクエストが実際に通ることを確認済み（[insights.md](insights.md)参照）。ただしaudience解決には対象audience向けの`oidc-audience-mapper`がclient scope側に必要という追加の前提が判明した（同insights.md）。account-service→analyst-attribute-serviceの経路（analyst-attribute-serviceはまだKeycloakクライアントとして未定義）は未検証のまま
- **標準client scope（profile/email/roles等）の要否**：`--import-realm`での直接importでは自動生成されないため現状未定義（詳細はrealm-configmap.yamlのコメント参照）。ログイントークンに`preferred_username`等が必要になった時点でclientScopesに明示定義を追加する

## インフラ

- **k3dクラスタの複数ノード化**：現状`servers: 1, agents: 0`（k3d/cluster-config.yaml）。スケジューリングの検証が必要になった場合はagentノードを追加するか検討
- **WSL2 cgroup v2化の恒久性**：`.wslconfig`の`kernelCommandLine = cgroup_no_v1=all`で対応済み（insights.md参照）だが、Windows Update等で設定が失われないかは未検証
