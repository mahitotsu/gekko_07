# ADR 0028: 共有PostgresインスタンスへのアクセスをEnvoyのtcp_proxyでmTLS化する

- **Status**: Accepted
- **Date**: 2026-09-18

## Context

[ADR 0018](0018-network-policy-default-deny.md)は「共有PostgresインスタンスはmTLS適用対象外」と明記し、NetworkPolicy(L3/4のdefault-deny)を代替の境界防御として導入した。以来、keycloak・account-service・analyst-attribute-service・fraud-detection-engineの各appコンテナはEnvoyを介さず直接Postgresへ平文接続してきた（[ADR 0008](0008-per-service-datastore-strategy.md)・[0026](0026-account-service-analyst-attribute-service-implementation.md)・[0027](0027-fraud-detection-engine-implementation.md)）。一方[ADR 0012](0012-spiffe-spire-mtls-single-hop.md)以降、他の全ホップはSPIRE発行の短命X.509-SVIDによるmTLSへ横展開済みであり、Postgresだけが取り残されたギャップになっていた。今回、このギャップを閉じる。

### 検討した選択肢

**1. PostgresネイティブTLS＋spiffe-helper（不採用）**：SPIRE公式の`spiffe-helper`でSVID/秘密鍵/信頼バンドルをファイルへ書き出し、Postgresの`ssl_cert_file`等（`SIGHUP`コンテキストのためreloadで反映可能）をローテーションのたびに再読み込みさせる方式。技術的には可能だが、このリポジトリが全ホップで一貫して守ってきた「秘密鍵に触れるのはEnvoyのみ、appコンテナは触れない」という原則を破る（Postgres接続はappコンテナがEnvoyを介さず直接行う構成のため、appコンテナ自身がWorkload APIソケットにアクセスする必要が生じる）。加えてファイルreloadのタイミング管理という新しい運用上の複雑さを持ち込む。

**2. Envoyの`postgres_proxy`フィルタ（不採用）**：SQL統計（セッション・ステートメント・トランザクション数等）を取るL7観測用フィルタ。公式ドキュメントに「セッションが暗号化されていることを検知すると、メッセージは無視されデコードされない」と明記されており、mTLS/暗号化には一切関与しない。加えてexperimentalであり構成が変わりうる。今回の目的（トランスポート層の暗号化・相互認証）には無関係な別の関心事（SQL単位の可観測性）であり、意図的に採用しない。

**3. 汎用`tcp_proxy`＋TLS transport socket（採用）**：Envoy公式の["Double proxy (with mTLS encryption)"](https://www.envoyproxy.io/docs/envoy/latest/start/sandboxes/double-proxy)サンドボックスと同じ、プロトコル非依存の構成。`envoy.filters.network.tcp_proxy`と`UpstreamTlsContext`/`DownstreamTlsContext`（SDS経由でSPIRE Agentから動的取得）の組み合わせで、ADR 0012以来の全ホップと同じSDS配線をそのまま流用できる。Postgresワイヤプロトコル自体はSSLRequestネゴシエーションを意識せず素のTCPのまま扱われる。

## Decision

**keycloak・account-service・analyst-attribute-service・fraud-detection-engineという常駐Deploymentのpostgres接続を、Envoyサイドカー間の`tcp_proxy`＋mTLSでラップする。**

### スコープ境界

**対象**：上記4常駐Deploymentのpostgres接続。

**対象外**：`keycloak-db-init`・`account-service-db-init`・`analyst-attribute-service-db-init`・`analyst-attribute-service-seed`・`fraud-detection-engine-db-init`という、psqlでsuperuser権限のまま直接接続する1回限りの初期化Job。理由：
1. 常駐アプリのmTLS化は、これまで6ホップに使ってきたEnvoyサイドカーパターンの単純な横展開である。
2. Jobは1回だけ動いて終わる処理であり、Envoyサイドカーを付けると、EnvoyがJobの終了を検知して自身も終了しないと、Jobがいつまでも完了しない。これを解決するKubernetesの仕組み（`restartPolicy: Always`のinitContainer＝ネイティブsidecar、1.29+でGA）はこのクラスタ（v1.35）で使えることを確認済みだが、このリポジトリでは一度も使ったことがないパターンである。
3. 「常駐アプリのmTLS化」と「Jobへの新しいK8sパターン導入」という性質の異なる2つの新規性を1つの変更に混ぜず、常駐アプリ側だけに絞る。db-init/seed Jobは引き続きNetworkPolicyのみで保護する（[docs/architecture.md](../architecture.md)に追加検討事項として記録）。

## Design Decisions

- **ポート設計**：Postgres本体の待受設定（`listen_addresses`等）は変更しない（共有インスタンスへリスクを持ち込まない）。postgres Podに新設したEnvoyサイドカーが`6432`でmTLSを終端し、同一Pod内の`127.0.0.1:5432`（実Postgres）へ平文`tcp_proxy`する。`k8s/postgres/service.yaml`に新しいポート`6432`を追加し、既存の`5432`（実Postgres直結。db-init/seed Job専用）はそのまま残した。
- **クライアント側**：4サービスとも`hostAliases`で`postgres`を`127.0.0.1`へ横取りし、自身のEnvoyサイドカーに新設したegressリスナー（`127.0.0.1:5432`、`tcp_proxy`）が`postgres.gekko.svc.cluster.local:6432`へmTLSで転送する。account-service→analyst-attribute-serviceの委任（ADR 0019/0020）と同じ透過リダイレクトパターンのため、appコンテナ側の環境変数（`DB_HOST=postgres`等）は一切変更不要。
- **単一filter_chain**：postgres側Envoyの`ingress-mtls`リスナーは、account-serviceが過去に必要としたTLS/plaintext分岐（ADR 0012 Consequences）を持たない。4呼び出し元全てが今回同時にmTLS化されるため、レガシーな平文呼び出し元が存在しないことによる。
- **NetworkPolicyの分割**：`k8s/postgres/networkpolicy.yaml`のingressルールを、ポート5432（db-init/seed Job専用）とポート6432（常駐4サービス専用）の2本に分割した。各常駐サービス自身のNetworkPolicyのegressルールもpostgres向けを5432→6432へ変更した（`*-db-init`/`*-seed`用の別NetworkPolicyリソースは5432のまま変更していない）。
- **SPIRE registration entry**：postgres Podのenvoyコンテナのみをselectorに持つentryを追加した（他の全サービスと同じ「Envoyコンテナのみ」パターン。postgresコンテナ自体は秘密鍵に一切触れない）。
- **Makefileのデプロイ順序変更**：postgres StatefulSet自身がEnvoyサイドカー（SPIRE Agent Workload APIソケットに依存）を持つようになったため、`deploy-spire`をpostgres StatefulSetの適用より前に移動した（旧順序では起動時にspire-agentが未起動でSDS接続のリトライ待ちが生じるため）。加えて、postgres/keycloak/account-service/analyst-attribute-service/fraud-detection-engineのNetworkPolicy（ポート変更を含む）を各Deploymentの適用より前に前倒し適用するようにした（[insights.md](../insights.md)に記録済みの「default-denyが既に有効な既存クラスタへの再デプロイでconnection refusedが起きる」パターンと同じ理由）。

## Consequences

- keycloak・account-service・analyst-attribute-service・fraud-detection-engineのPostgres接続は、他の全ホップと同じくSPIRE発行の短命SVIDによる相互認証・暗号化下に置かれる。
- **既知の限界（解消済み）**：db-init/seed Jobは引き続き平文でPostgresの5432へ直接接続し、NetworkPolicyのみで保護される、としていた。ネイティブsidecarコンテナ（`initContainers`に`restartPolicy: Always`。K8s 1.29+でGA、このクラスタのv1.35で利用可能と確認済み）を使うことで、5つのdb-init/seed Job（`keycloak-db-init`・`account-service-db-init`・`analyst-attribute-service-db-init`・`analyst-attribute-service-seed`・`fraud-detection-engine-db-init`）にもEnvoyサイドカーを追加し、常駐4サービスと同じmTLS経路（6432）に統一した。各Jobのスクリプトが既に持っていた接続待機リトライループ（NetworkPolicy反映待ちのため導入済み）が、サイドカー起動直後のSDS配信待ちにもそのまま効いたため、新しいstartupProbe等は追加していない。結果、Postgres本体の5432への直接到達経路（`k8s/postgres/networkpolicy.yaml`のingressルール・`k8s/postgres/service.yaml`のポート）は完全に廃止し、全呼び出し元が6432のmTLS経路に統一された。
- Postgres本体（`k8s/postgres/statefulset.yaml`の`postgres`コンテナ）の設定・待受ポートは無変更のため、共有インスタンスの安定性へのリスクは追加していない。
- **既知の限界（解消済み）その2**：常駐4Deploymentは当初、Envoyサイドカーを通常の`containers`（appコンテナと並列起動）のまま追加していた。実機で`make up`/`make stop`+`make start`直後にaccount-service・analyst-attribute-serviceがCrashLoopBackOffする事象を確認した（appコンテナがEnvoyのSDS配信完了前に127.0.0.1:5432へ接続しに行き失敗する競合。詳細は[insights.md](../insights.md)）。db-init/seed Jobで確認済みだったネイティブsidecarパターン（`initContainers`の`restartPolicy: Always`）を常駐4Deployment（keycloak・account-service・analyst-attribute-service・fraud-detection-engine）のEnvoyにも適用し、その後ろに`wait-for-postgres`（`pg_isready`リトライループ）initContainerを追加してappコンテナの起動をPostgres疎通確認後まで遅らせる構成に変更した。あわせて、Postgres接続を持たないfraud-mcp-server・fraud-agent・frontendのEnvoy、およびpostgres本体のEnvoy（着信mTLS終端。自身の起動はこれに依存しないためwait-for-X initContainerは追加していない）もネイティブsidecar化し、全Deployment/StatefulSetでEnvoyサイドカーの実装方式を統一した（edge-proxyのみ、Envoy単体Podで`containers`を空にできないため対象外）。
