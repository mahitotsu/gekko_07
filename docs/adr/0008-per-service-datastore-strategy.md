# ADR 0008: サービスごとのデータストア戦略（Keycloakを含む）

- **Status**: Accepted
- **Date**: 2026-09-13

## Context

[services.md](../services.md)で「保有データ」を持つサービス（frontend / account-service / fraud-detection-engine / analyst-attribute-service）について、データストアの方針が未定義だった。加えて、Keycloak（[k8s/keycloak/](../../k8s/keycloak/)）も現状はstart-devモードの埋め込みH2データベースのままで、永続化方針が未定だった（architecture.md「Keycloakの永続化」）。検討すべき軸は3つある。

1. **論理的なデータ所有権**：他サービスがテーブルを直接見られる構成にするか
2. **物理的なインフラ共有**：サービスごとに専用インスタンスを持つか、インスタンスを共有し内部で分けるか
3. **エンジン選定**：RDB/NoSQLのどちらを、どのサービスに使うか

ローカル実行環境はk3d/WSL2で、空きメモリ枯渇を実機で経験済みという既知の制約がある（[insights.md](../insights.md)）。

## Decision

### 1. 論理的なデータ所有権：サービスごとに専有する（MUST）

各サービスは自分のデータの唯一の番人であり、他サービスは直接テーブル・コレクションを見ない。他サービスからのアクセスは必ずそのサービスのAPI（スコープ付きトークン経由）を通す。これは後述の物理インフラ共有とは独立した原則であり、物理共有はこの原則を破らない（別データベース・別認証情報とし、DBエンジン側の権限でも強制する）。

このプロジェクトの核心は「サービス境界をスコープ付きトークンで越える」ことの実演である（architecture.md）。共有テーブルへの直接アクセスを許すと、サービス境界が名目上のものになり、Token Exchangeを挟んでいる意味そのものが崩れる。

### 2. 物理インフラ：PostgreSQLインスタンスを1つ共有し、サービスごとに論理DB・認証情報を分離する

1つのStatefulSet（1 pod）を共有インフラとして立て、account-service用・fraud-detection-engine用・analyst-attribute-service用・**Keycloak用**にそれぞれ別のデータベース（`account_service`db、`fraud_detection_engine`db、`analyst_attribute_service`db、`keycloak`db）と別のDBロールを作る。各ロールはGRANTで自分のデータベースにしかアクセスできない。

サービスごとに専用インスタンスを別々に立てるのが原則的には筋が良いが、ローカル/WSL2環境は既にメモリ逼迫を実機で経験済みのため、ここではリソース効率を優先する。論理的な所有権（1）はDBエンジン側の権限で担保されるため、物理共有そのものはこの原則に反しない。本番相当の環境を検証したくなった場合は、障害の伝播を避けるためサービスごとの専用インスタンスへ切り替える（[architecture.md](../architecture.md)に記録）。

Keycloakを含めるかどうかは別途検討したが、このシステムではどの操作も最終的にaccount-serviceへ到達する（トークンチェーンはarchitecture.md参照）ため、「Keycloakだけ生きていれば認証だけは機能する」という部分的縮退のシナリオはそもそも存在しない。account-service等3サービスが同一Postgres podを共有する時点で既に運命は共有されており、Keycloakを同じpodに加えても新しいリスクのカテゴリは生まれない。よって同一インスタンスに含める。

**DB・ロールのプロビジョニングも「自分のデータの唯一の番人」の対象にする**：当初は共有Postgres StatefulSet自身（k8s/postgres/）に全サービス分の初期化スクリプトを持たせる設計だったが、これは「サービスごとに専有」の原則をプロビジョニングの領域では破っていた（新しいサービスを追加するたびに共有インフラ側を編集する必要があり、postgres/が全消費者の存在を知っている状態になる）。そこで、共有Postgres StatefulSetは素のエンジンのみ提供し、各サービスが自分のDB・ロールを自分のディレクトリに置いたJob（例：[k8s/keycloak/db-init-job.yaml](../../k8s/keycloak/db-init-job.yaml)）で、Postgresのsuperuser権限を一度だけ借りてプロビジョニングする方式にする。副次的な利点として、docker-entrypoint-initdb.d方式（PVCが空の初回起動時にしか実行されない）と違い冪等なJobなので、後から新しいサービスのDBを追加する際にPVCを作り直す（＝他サービスのデータを巻き添えにする）必要がなくなる。

**GRANTによる分離の実装**：`CREATE DATABASE ... OWNER ...`だけでは、Postgresの既定でPUBLIC（全ロール）にそのデータベースへのCONNECT権限が残ってしまい、「他サービスのデータベースには接続すらできない」が実際には保証されない。そのためデータベース作成後に`REVOKE CONNECT ... FROM PUBLIC`＋オーナーロールへの`GRANT CONNECT`を明示的に行う（db-init-configmap.yaml参照）。実機で`keycloak`ロールが意図通り`keycloak`データベースにのみ接続できることを確認済み。ただしPostgresの既定メンテナンスデータベース（`postgres`）自体へは全ロールが引き続き接続できる（実データを持たないため実害はないが、完全な分離ではない。[architecture.md](../architecture.md)に記録）。

### 3. エンジン選定：データの形状ではなく、正データかどうかで判断する

当初はanalyst-attribute-serviceを「`analyst_id`で引いて`{担当地域の配列, 権限レベル}`を返すだけの純粋なキーバリュー形状」という理由でRedisにする案があったが、これは撤回した。「キー単体で引ける」というアクセスパターンはRDBの主キー検索でも同様に処理でき、Redisを選ぶ積極的な理由にはならない。一方でこのデータはアクセス制御の根拠になる正データ（キャッシュや派生データではない）であり、Redisの本来の強み（速度・揮発性）が活きる場面もない（呼び出し頻度はaccount-serviceからの内部照会のみで低い）。永続化を頑張らせてRedisをDB相当に仕立てるくらいなら、最初からRDBの方が素直。よって全サービスPostgreSQLに統一する。

| サービス | エンジン | 理由 |
|---|---|---|
| account-service | PostgreSQL | 口座・取引履歴・凍結記録・凍結解除提案・凍結解除実行記録が相互に参照整合性を持つ（凍結解除実行は`proposal_id`で提案に紐づく。[architecture.md](../architecture.md) §9）。ACIDトランザクションと外部キー制約が意味を持つ、典型的な台帳データ |
| fraud-detection-engine | PostgreSQL（account-serviceと同じインスタンス内の別データベース） | 検知ルール・しきい値の設定自体は単純だが、どのルールがいつ発火し凍結に至ったかという監査証跡として耐久性・一貫性を優先する |
| analyst-attribute-service | PostgreSQL（同じインスタンス内の別データベース） | アクセス制御の根拠になる正データであり、耐久性を優先。アクセスパターンは主キー検索のみで、RDBの単一テーブルで過不足なく表現できる |
| frontend | なし（下記4参照） | |
| Keycloak（6サービス外・プラットフォーム基盤） | PostgreSQL（同じインスタンス内の別データベース） | Keycloak公式が最も実績を持つ本番用DB。realm・クライアント・セッション等の永続化に使う。上記3サービスと同じ共有インスタンスに含める理由は上記2参照 |

### 4. frontendはサーバー側データストアを持たない

ログインセッション（アナリストのログイントークン）は、サーバー側ストアではなく暗号化・署名付きのhttpOnly Cookieに保持する（ステートレスセッション）。

- ログイントークン自体の有効期限は短く設計する前提（[architecture.md](../architecture.md)「交換後トークンのアクセストークン有効期間」）であり、サーバー側の即時失効機能の必要性が薄い
- サーバー側の状態を持たないためスケールしやすく、依存コンポーネント（Redis等）を増やさずに済む
- 「サービスごとに専用データストア」の原則に対し、frontendのためだけに追加インフラ（セッションストア）を持ち込まずに済む

即時失効（例：インシデント対応での強制ログアウト）が要件として必要になった場合は、Keycloakのセッション管理機能（Admin REST APIでのセッションrevoke）を使う想定とし、frontend側に独自のセッションストアを持たせる方向へは広げない。

## Consequences

- 新規に追加するステートフルなpodはPostgreSQL×1のみ。Keycloakもこのインスタンスに含めるため、k8s/keycloak/deployment.yamlをstart-dev + 埋め込みH2からPostgres接続に変更し、実機でPod再作成・WSL2再起動をまたいだ永続化を確認済み
- account-service・fraud-detection-engine・analyst-attribute-service・Keycloakが同じPostgresインスタンスを共有するため、いずれかの負荷や再起動が他に影響しうる。ローカル検証目的では許容する
- 本ADRの結果、6サービス中データストアを持つのは3つ（account-service/fraud-detection-engine/analyst-attribute-service）全てPostgreSQLとなり、RDB/NoSQLの使い分け自体は今回のサービス構成では発生しなかった。NoSQLが適所になるサービスが将来増えた場合はその時点で個別に判断する
- サービスが増えるたびに、そのサービス自身のディレクトリに db-init-configmap.yaml / db-init-job.yaml 相当を追加する運用になる。共有Postgres（k8s/postgres/）は変更不要
- frontendの暗号化Cookieセッションの実装詳細（暗号鍵の管理・ローテーション）は実装時に決定
