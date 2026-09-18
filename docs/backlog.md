# バックログ

未着手の改善項目・未決定事項。着手時はこのファイルから該当項目を削除し、必要ならarchitecture.md/services.md/insights.mdへ結果を記録する。

## Token Exchange / Envoyサイドカー

- **合言葉ヘッダー名・env var名の確定**：1ホップ先行検証でヘッダー名`x-gekko-handshake`・env var名`HANDSHAKE_TOKEN_FILE`を採用し、Python実装のスタブ間で統一した（[k8s/account-service/app-configmap.yaml](../k8s/account-service/app-configmap.yaml)等）。Java/TypeScript/Rust/Go等、他言語での本実装時にも同じ命名を踏襲する
- **frontendの簡易ログイン（ROPC）を本物のAuthorization Code + PKCEブラウザフローへ置き換える**：[ADR 0024](adr/0024-frontend-edge-proxy-and-simplified-login.md)で、`/login`エンドポイント（ROPCのHTTPエンドポイント化）と`directAccessGrantsEnabled=true`の恒久化を暫定実装として採用した。本実装（TypeScript/Nuxt.js）時に、本物のリダイレクト・code_verifier管理・Cookieによるセッション管理へ置き換え、`directAccessGrantsEnabled`をfalseに戻すかどうかを判断する
- **Unixドメインソケット化の再検討**：[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)でTCP loopback+合言葉方式を採用しUnixドメインソケット化は見送ったが、「同一Pod内でアプリが侵害された場合」まで守る要求が出てきたら再検討する
- **DPoPの適用範囲**：[ADR 0013](adr/0013-dpop-sender-constraining.md)でfraud-mcp-server→account-serviceの1ホップに導入したが、[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)で撤去した（mTLSとの実利の重複が大きい一方、制約だけが残るため）。実機検証で得た知見は下記「DPoP」節に残す
- **Token Exchange結果のキャッシュ**：`(subject jti, audience)`単位でのキャッシュを検討しているが、各サイドカー内に閉じるか、どの範囲で共有するかは未決定。キャッシュTTLは性能とのトレードオフを意図的に選んだ短い値にする
- **交換後トークンのアクセストークン有効期間**：[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)は、トークン漏洩・誤用時の被害範囲を抑える多層防御として交換後トークンの有効期間を短く設定する方針を前提にしている。ログイントークンとは別に、各クライアント（frontend/fraud-mcp-server/account-service）が交換で得るトークンのAccess Token Lifespanを具体的に何秒にするかは未決定

## DPoP

[ADR 0013](adr/0013-dpop-sender-constraining.md)でfraud-mcp-server→account-serviceの1ホップに実装・実機検証したが、[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)で撤去した（このホップは既にSPIRE mTLSで身元を限定済みのため実利の重複が大きく、投資に見合わないと判断）。コードは無いが、将来DPoPを再検討する際に効く実機知見として残す。

- **「拘束のスロット」は委任チェーンに1箇所、終端ホップのみ**：subject_tokenに既存の拘束が無ければ要求者は自分の鍵で新しく拘束できるが、既存の拘束がある場合は別クライアント・別鍵での再exchangeがKeycloakに拒否される（`400: Sender-constrained token exchange rejected as the token was not issued for the requesting client`。実機検証済み）。このため一度どこかのホップでDPoPを有効化すると、そこから先(例：account-service→analyst-attribute-service)への拡張はできない
- **frontendへの適用は限定的**：frontend→fraud-mcp-server向けのexchangeには上記制約により適用できない（そもそもtable 1でDENY、正しい経路はfraud-agent経由のみ）。frontend→account-serviceへの直接exchange（pattern②、確定パス。それ自体が委任チェーンの終端となる）であれば理論上は可能だが、[ADR 0024](adr/0024-frontend-edge-proxy-and-simplified-login.md)でfrontendを実装した際もDPoPは有効化しなかった（SPIRE JWT-SVIDクライアント認証のみ採用）ため、依然として未検証
- **Keycloakの`dpop.bound.access.tokens`が有効なクライアントは、トークンリクエスト全般（ROPCログイン等も含む）で常にDPoP proofが必須になる**点、**proof lifetime/clock skew windowが固定**（`DEFAULT_PROOF_LIFETIME=10秒`・`DEFAULT_ALLOWED_CLOCK_SKEW=15秒`、Keycloak 26.7.0でハードコード）である点も、再検討時の制約として記録
- **Keycloak issue #51205（DPoP bound tokenとdelegation/actor tokenの衝突）**：26.7.0に対して未解決のまま提出されている。今回遭遇した「既存の拘束を持つsubject_tokenの再exchange失敗」と同種の問題を指摘しており、将来Keycloak側の挙動が変わればこのプロジェクトの制約も変わる可能性がある

## mTLS / SPIFFE / SPIRE

fraud-mcp-server・fraud-detection-engine・account-service・analyst-attribute-service・fraud-agent・frontend・edge-proxy・Keycloak間の全ホップ、常駐4サービス(keycloak/account-service/analyst-attribute-service/fraud-detection-engine)とPostgres間、および5つのdb-init/seed Job(1回限りの初期化Job。ネイティブsidecarコンテナでEnvoyを持つ)とPostgres間にSPIRE mTLSを導入済み（[ADR 0012](adr/0012-spiffe-spire-mtls-single-hop.md)/[0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)/[0017](adr/0017-edge-proxy-full-keycloak-mtls.md)/[0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)/[0020](adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)/[0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)/[0023](adr/0023-fraud-agent-fraud-mcp-server-hop.md)/[0024](adr/0024-frontend-edge-proxy-and-simplified-login.md)/[0028](adr/0028-postgres-mtls-tcp-proxy.md)）。Postgres本体の平文5432への直接到達経路は全て廃止された。全ホップへの横展開は完了し、残るのは以下の明示的スコープ外項目のみ。

- **NetworkPolicyのspire namespaceへの横展開**：[ADR 0018](adr/0018-network-policy-default-deny.md)で`gekko` namespaceにL3/4のdefault-denyを導入したが、`spire` namespace（spire-server/spire-agent）は対象外とした。spire-agentが`hostNetwork: true`で動作しており、kube-router netpolがhostNetwork Podに対してどう振る舞うかが未検証なため。加えて`spire-entries` Job（`kubectl exec`でspire-serverへ接続する）等、`gekko` namespaceとは異なる接続パターンを持つ点も要考慮
- **ワークロードPod（account-service/fraud-mcp-server等）自体への`hostPID`/`hostNetwork`付与**：SPIRE agentには必要だが、ワークロードPod側はカーネルのPID名前空間の性質上不要なはずという推測のもとで見送った。属性解決が実機で失敗した場合（SDS呼び出しがタイムアウトする、spire-serverのログに"no selectors found after max poll attempts"が出る等）のみ再検討する
- **`spiffe-csi`ドライバ・`spire-controller-manager`**：新規可動部を増やさないため、hostPathでのソケット共有・`spire-server entry create` CLIでの手動登録を選んだ。本番相当の運用を検証したくなった場合に再評価する

## 属性・アクセス制御の粒度

- **口座属性の拡張要否**：現状は地域(`region`)とティア(`standard`/`high-value`)の2軸のみ（access-control-design.md 表5）。実装を進める中でさらに軸が必要になるか要検討

## fraud-detection-engine

- **実際の取引イベントストリームとの連携**：[ADR 0027](adr/0027-fraud-detection-engine-implementation.md)で本実装した監視ループは、上流の取引イベント基盤が存在しないため観測シグナル（口座ID・発火ルール・スコア・理由）を起動時の固定シードで代用している。実際の取引ストリームと連携したくなった場合、BR7（fraud-detection-engineはaccount:readを持たない。access-control-design.md表4）とどう両立させるか（account-serviceからの何らかのイベント供給の形を取るのか等）を含めて再検討が必要
- **スキャン間隔のチューニング**：既定5秒はデモの応答性優先の値であり実運用相当ではない。実運用を想定した値・可変間隔（負荷に応じた調整等）が必要になった場合に見直す

## 監査

- **otel-lgtmの同梱コンポーネント（Prometheus/Tempo/Pyroscope/OTel Collector）を無効化できるか**：ADR 0025で採用した`grafana/otel-lgtm`はGrafana+Lokiのみ使う想定だが、残り4コンポーネントも起動している。個別に無効化できるかは未調査（動くが未使用として許容している）
- **`k8s/keycloak/test-fixtures-job.yaml`のパスワード設定の再現性問題**：realm再import直後にジョブを実行すると、作成直後のユーザーでログインが401になることがある（kcadmでset-passwordを打ち直すと直る）。原因未特定（[insights.md](insights.md)参照）

## データストア

- **本番相当環境でのインスタンス分離**：現状はローカルのメモリ制約を理由にaccount-service/fraud-detection-engine/analyst-attribute-service/KeycloakのPostgreSQLを共有インスタンスにしている（ADR 0008）。本番相当の構成を検証したくなった場合、サービスごとの専用インスタンスへの切り替えを検討する
- **既定メンテナンスDB（`postgres`）への接続が全ロールに残っている**：[k8s/keycloak/db-init-configmap.yaml](../k8s/keycloak/db-init-configmap.yaml)で`keycloak`データベースはPUBLICのCONNECT権限を剥奪したが、Postgresの既定メンテナンスデータベース自体は未対応。実データを持たないため実害はないが、完全な分離ではない

## Keycloak

- **`standard.token.exchange.enabled`属性の機能的検証**：1ホップ先行検証（frontend→fraud-mcp-server、fraud-mcp-server→account-service、account-service→analyst-attribute-service）でRFC 8693トークン交換リクエストが実際に通ることを確認済み（[insights.md](insights.md)・[ADR 0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)参照）。ただしaudience解決には対象audience向けの`oidc-audience-mapper`がclient scope側に必要という追加の前提が判明した（同insights.md）
- **標準client scope（profile/email/roles等）の要否**：`--import-realm`での直接importでは自動生成されないため現状未定義（詳細はrealm-configmap.yamlのコメント参照）。ログイントークンに`preferred_username`等が必要になった時点でclientScopesに明示定義を追加する

## インフラ

- **k3dクラスタの複数ノード化**：現状`servers: 1, agents: 0`（k3d/cluster-config.yaml）。スケジューリングの検証が必要になった場合はagentノードを追加するか検討
- **WSL2 cgroup v2化の恒久性**：`.wslconfig`の`kernelCommandLine = cgroup_no_v1=all`で対応済み（insights.md参照）だが、Windows Update等で設定が失われないかは未検証
