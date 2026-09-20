# ADR 0027: fraud-detection-engineを本実装し、デモ用凍結データの発生源をaccount-serviceのシードから切り替える

- **Status**: Accepted
- **Date**: 2026-09-18

## Context

[ADR 0026](0026-account-service-analyst-attribute-service-implementation.md)でaccount-service・analyst-attribute-serviceを本実装した時点で、README.mdの残り未着手項目はfraud-mcp-server・fraud-detection-engine・fraud-agent・frontendの4サービスだった。[docs/services.md](../services.md)の記述順・[architecture.md](../architecture.md) §3の実装順序（1ホップ先行検証の順）のいずれでも、fraud-detection-engine→account-serviceはfraud-mcp-server→account-serviceに次ぐ位置にあり、かつaccount-serviceのみに依存する（他の未実装サービスへの依存が無い）ため本実装に着手する最有力候補だった。

fraud-detection-engineは[ADR 0011](0011-scenario-ai-assisted-unfreeze.md)・[UC0](../architecture.md)で「取引パターンを監視し、疑わしい取引を検知した口座を自動的に凍結する」役割と定義されているが、[architecture.md](../architecture.md) 表4によりaccount-serviceに対して`account:freeze`のみを持ち`account:read`を一切持たない（BR7）。つまりfraud-detection-engineは構造的にaccount-serviceの取引データを読み返すことができない。この設計は意図的なもの（機械間認証の経路をユーザー委任チェーンの読み取り権限から完全に分離する）であり、覆さない。そのため「何を監視するか」の実データは、account-serviceの取引ではなく、fraud-detection-engine自身が保有する観測シグナルとして独自にモデル化する必要がある。

これまでaccount-serviceのFlyway `V2__seed.sql`が、デモ用の4口座（123/456/789/999）を`frozen=TRUE`かつ対応する`freeze_records`付きであらかじめ投入していた。これは「fraud-detection-engineが未実装だったための一時的な代用」であり、UC0が想定する「fraud-detection-engineの自動凍結が既に起きている」という前提を、本来の実行者（fraud-detection-engine自身のclient_credentials呼び出し）ではなくaccount-service起動時のシードデータで代用していたものだった。fraud-detection-engineを本実装する以上、この代用は解消し、実際にfraud-detection-engineが起動後まもなく能動的に凍結を実行する形に置き換える。

## Decision

### fraud-detection-engineの観測データを自身のPostgreSQLに持たせる

`services/fraud-detection-engine/`（Rust 2021 / Axum。[ADR 0007](0007-per-service-language-selection.md)の言語選定を踏襲）を新設した。自身のPostgreSQLデータベース（account-service・analyst-attribute-serviceと同一インスタンス内の別データベース。[ADR 0008](0008-per-service-datastore-strategy.md)）に3テーブルを持つ：

- `detection_rules`（ルール名→しきい値）：account-serviceの旧`freeze_records`シードが使っていたルール名（`RULE_RAPID_TRANSFER`・`RULE_GEO_ANOMALY`・`RULE_NEW_PAYEE`）をそのまま踏襲し、しきい値を紐付けた
- `signals`（account_id→発火ルール・スコア・理由）：本来は取引ストリームから供給されるべきデータだが、このプロジェクトの範囲では上流の取引イベント基盤自体が存在しない（account-serviceが取引の正典であり、BR7によりfraud-detection-engineはそこへ読み取りアクセスできない）ため、デモ用の固定シグナルとして自身のスキーマ初期化時に投入する。値は account-service旧`V2__seed.sql`の`freeze_records`と同じ4件（口座ID・ルール・スコア・理由）を移送した
- `detections`（account_id→凍結実行済みマーク）：同じ口座を毎スキャン周期ごとに繰り返し凍結依頼しないための冪等性マーカー

起動時にスキーマを`CREATE TABLE IF NOT EXISTS`で用意し、上記シード（`detection_rules`・`signals`）を`ON CONFLICT DO NOTHING`で冪等投入する（analyst-attribute-serviceと同じくFlyway等は導入せず、Go実装が確立した「アプリ自身が起動時にスキーマを用意する」方針をRustでも踏襲。DBアクセスは`tokio-postgres`のみを使い、ORM・マイグレーションフレームワークは追加しない）。

### 監視ループ（ポーリング、固定間隔）

バックグラウンドタスクが`SCAN_INTERVAL_SECONDS`（既定5秒）ごとに`signals ⋈ detection_rules WHERE score >= threshold AND account_idがdetections未登録`を評価し、該当があればaccount-serviceの`POST /accounts/{id}/freeze`を呼ぶ（自身のPod内client-credentialsサイドカー・Envoy egressは[ADR 0020](0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)のスタブ実装をそのまま使う。呼び出し先URLは`http://account-service/...`とアプリが実サービス名を直接使う原則をそのまま踏襲。Authorizationヘッダーはアプリが持たず、Envoy ext_authzが透過的に付与する）。成功したら`detections`にマークして以後スキャン対象から外す。失敗時はマークせず次周期で再試行する（フェイルオープンにしない）。

一括バッチ処理ではなくポーリングにした理由：このプロジェクトには実際の取引イベントストリームが存在せず「イベント駆動で起動する」入力が無い。ポーリング間隔はデモの応答性（数秒で凍結が観測できること）を優先して短くしたが、実運用相当の値ではない（architecture.mdに残す）。

### 診断用ループバックAPI（セキュリティ境界外、Envoy ingressなし）

`GET /healthz`・`GET /detections`を`127.0.0.1:9000`にのみbindするAxumサーバーとして追加した。fraud-detection-engineは[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)以来一貫してingressの受け口を持たないサービス（services.mdの通り、他サービスから着信呼び出しを受ける経路が無い）であり、この方針は変えていない——このAPIはEnvoy ingressにもService/NetworkPolicy ingressにも一切繋がっておらず、`kubectl exec`でPod内から直接叩く診断専用の口である（`scripts/verify-hop.sh`が「fraud-detection-engineが自律的に検知・凍結したこと」を確認する手段として使う。後述）。

### account-serviceのデモ凍結シードをfraud-detection-engineの自動凍結に置き換える

account-serviceの`V2__seed.sql`から`frozen=TRUE`・`freeze_records`の投入を削除する新規マイグレーション`V3__remove_demo_freeze_seed.sql`を追加した（Flywayは一度適用したマイグレーションのchecksumを検証するため、`V2__seed.sql`自体は書き換えず追記専用で対応する。実機のk3dクラスタは既にADR 0026のV2を適用済みのPostgres PVCを保持しているため、この制約が実際に効く）。結果として4口座は起動直後は未凍結（`frozen=FALSE`、取引データのみ保持）になり、fraud-detection-engineが実際に検知・凍結を実行して初めて凍結状態になる。UC0が想定する順序（fraud-detection-engineの自動凍結が先に起き、それ以降のUC1〜UC5が成立する）が、シードによる代用ではなく実際のサービス間呼び出しで再現されるようになった。

[ADR 0026](0026-account-service-analyst-attribute-service-implementation.md)の「デモ用口座データをFlyway seedに同梱した」という決定はこの点で覆るため、同ADRのStatusを`Partially superseded by 0027`に更新する（Context/Decision本文は書き換えず、Consequencesへの短い追記のみで対応。[CLAUDE.md](../../CLAUDE.md)のドキュメント運用ルールに従う）。

### base trackへ格上げする

fraud-detection-engineは自身のPostgreSQL（実データ）を持つため、account-service・analyst-attribute-service（ADR 0026）と同じ理由で、スタブ検証専用の`make deploy-verify-hop`から`make deploy`（base track）へ格上げした。`db-init-{configmap,job}.yaml`はaccount-serviceと同一パターンで新設し、Makefileの`build-fraud-detection-engine`ターゲットが`docker build`後に`k3d image import`でイメージを持ち込む。`deploy-verify-hop`には残る3スタブ（fraud-mcp-server・fraud-agent・frontend）のみが残る。実装の過程で、既知の実装漏れパターン（[insights.md](../insights.md)「接続元Job自身のegress許可漏れ」）を踏まないよう、`fraud-detection-engine-db-init` Job自身のegress許可NetworkPolicyを最初から用意した。

### `scripts/verify-hop.sh`をfraud-detection-engineの実際の自律動作の検証に更新する

旧パターン②の検証は、fraud-detection-engine-stub Pod内の`app`コンテナ（Pythonスタブ）から手動でfreezeリクエストを組み立てて送るものだった。本実装後は`app`コンテナが（Pythonではなく）コンパイル済みのRustバイナリになりシェル・curlを持たないため、この手動呼び出し自体を廃止し、代わりに「fraud-detection-engineが起動後まもなく自律的にデモ用4口座を検知・凍結したこと」を、上記の診断用ループバックAPI（`GET 127.0.0.1:9000/detections`、`client-credentials`コンテナ内のPythonから`kubectl exec`で叩く。Pod内は全コンテナがネットワーク名前空間を共有するため到達できる）で確認する形に置き換えた。「account:freezeスコープしか持たないためGETは拒否される」という異常系の検証（旧4b）は、実行元コンテナを`app`から`client-credentials`（Python環境が残る）に変えた上でそのまま維持した。

実機検証で判明した副作用：`detections`テーブルは一度凍結を依頼した口座を二度と再依頼しない設計（意図通り。人間が確定解除した口座を毎スキャン周期で勝手に再凍結してはならない）のため、`verify-hop.sh`を（再デプロイを挟まず）2回連続実行すると、1回目のステップ6（確定パスでの凍結解除）で既にaccount 123が未凍結になっており、2回目の実行ではステップ6が`409 Conflict`で失敗するようになった。UC0自体の検証はステップ4で完結しているため、ステップ6直前にテストフィクスチャとして（`client-credentials`コンテナから同じ手動freeze呼び出しの技法で）account 123を確実に凍結状態へ戻すステップ（4c）を追加し、2回連続実行しても警告ゼロで完走することを確認した（ADR 0026が検証していた性質を維持）。

## Consequences

- README.mdの「各サービスの実装（本実装）」進捗が3/6になった。残るfraud-mcp-server・fraud-agent・frontendは引き続きスタブのまま
- docs/services.mdのfraud-detection-engineの記述を「未着手（設計段階）」から実装済みへ更新し、保有データの記述を実際のスキーマ（detection_rules/signals/detections）に合わせて具体化した
- account-serviceのデモ用凍結データの発生源がFlyway seedからfraud-detection-engineの実際の自動実行に変わったことで、`make deploy`直後は口座が未凍結状態になり、fraud-detection-engineのスキャン間隔（既定5秒）分だけ遅れて凍結される。`scripts/verify-hop.sh`はこの遅延を待ち合わせる
- 「取引イベントストリームが存在せず、fraud-detection-engineの観測シグナルは固定シードで代用している」という簡略化は残ったままである。実際の取引ストリーム連携（account-serviceからの何らかのイベント供給）を実装したくなった場合は、BR7（fraud-detection-engineはaccount:readを持たない）とどう両立させるかを含めて再検討が必要（architecture.mdに残す）
- ポーリング間隔（既定5秒）はデモの応答性優先の値であり実運用相当ではない（architecture.mdに残す）
