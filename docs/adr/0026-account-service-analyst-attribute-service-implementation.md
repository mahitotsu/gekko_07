# ADR 0026: account-service・analyst-attribute-serviceを本実装し、ビルド・配布パイプラインを新設する

- **Status**: Partially superseded by [0027](0027-fraud-detection-engine-implementation.md)
- **Date**: 2026-09-18

## Context

`README.md`の最終未着手項目は「各サービスの実装（本実装）」だった。[docs/services.md](../services.md)でaccount-serviceは「今回の主役」と位置付けられ、fraud-mcp-server・fraud-detection-engine・frontendの依存の中心にあるため、本実装に着手する際の最有力候補だった。

account-serviceのABAC判定（[access-control-design.md](../access-control-design.md) 表5：担当地域・権限レベルによるアクセス可否）はanalyst-attribute-serviceから取得するアナリスト属性が前提になる。しかし同サービスは「受け取ったヘッダーをそのまま返すだけ」のスタブで、実際の属性データ（表6：yamada-analyst/suzuki-senior/tanaka-junior）を一切持っていなかった。account-serviceだけを本実装しても、ABACの主要な分岐（BR1・BR2・BR3）は実機検証できないままになるため、analyst-attribute-serviceも同時に本実装することにした。

このリポジトリでは初めてコンパイルを要するサービスであり、ビルド・イメージ配布パイプライン（Dockerfile・イメージのクラスタへの持ち込み）が一切存在しなかった。全サービスがPythonインラインスクリプト（ConfigMapマウント）のスタブだったため、今回新規に設計する必要があった。

## Decision

### ビルド・配布パイプラインを新設する（レジストリは使わない）

`services/account-service/`（Maven、Java 21/Spring Boot 3.3）・`services/analyst-attribute-service/`（Go modules、Go 1.24）を新設した。各々にマルチステージDockerfile（ビルド専用イメージ→軽量実行イメージ）を置き、`Makefile`の`build-account-service`・`build-analyst-attribute-service`ターゲットが`docker build`後に`k3d image import`でローカルビルド成果物をそのままクラスタへ持ち込む。レジストリ（ローカルも含め）は導入せず、`k3d/cluster-config.yaml`への変更は不要にした。`deploy`ターゲットの中で、Postgres・Keycloak・edge-proxyのデプロイ後・db-init完了後に呼ぶ。

### account-service（`services/account-service/`）

Spring MVCのコントローラ1つ（`AccountController`）と、JDBC直叩き（`NamedParameterJdbcTemplate`、ORMは導入しない）のリポジトリ1つで構成する。スキーマ管理はFlyway（`src/main/resources/db/migration/`にV1__init.sql・V2__seed.sql）を採用した。

- エンドポイントは[access-control-design.md](../access-control-design.md) 表2のパスパターンをそのまま実装し、`scripts/verify-hop.sh`が既に使っていたパス（`/accounts/{id}/transactions`・`/accounts/{id}/unfreeze-proposals`・`/accounts/{id}/freeze`・`/accounts/{id}/unfreeze`）を維持したため、Envoyのrbac設定（`k8s/account-service/envoy-configmap.yaml`）は変更不要だった。新たに一覧用`GET /accounts/frozen`を追加した（get_frozen_accounts用、表2の`GET /accounts/**`許可に収まる）
- スコープ（account:read/propose/freeze/unfreeze）の検証はEnvoy rbacの責務のまま変更していない（ADR 0009 §1）。account-serviceのアプリ内で行うのは表5のABAC判定（業務データ依存）のみ
- ABAC判定は`AccessControl`クラスに集約した：属性未登録・地域不一致は常にDENY、地域一致ならstandardはjunior/senior問わずALLOW、high-valueはsenior限定ALLOW
- ABAC拒否の表現は操作種別で使い分けた：単一リソース読み取り（`GET /accounts/{id}/transactions`）は404（口座の存在自体を秘匿）、単一リソースへの操作（propose/unfreeze）は403（呼び出し元は既に口座の存在を知っている前提のため）、一覧（`GET /accounts/frozen`）は結果セットからの除外（use-cases.md UC3/UC4の想定通り）
- `POST /accounts/{id}/unfreeze`は口座が凍結中でない場合409を返す（多層防御としてのABAC再照会はキャッシュせず毎回analyst-attribute-serviceへ問い合わせる）
- account-service→analyst-attribute-serviceの呼び出し経路（自身のegress Envoy 127.0.0.1:80、hostAliasesで宛先を横取り、token-exchangeサイドカーがAuthorizationヘッダーをsubject_tokenに交換）はスタブ時代のパターンをそのまま踏襲した

### analyst-attribute-service（`services/analyst-attribute-service/`）

ADR 0007の「Go標準ライブラリ」方針を踏襲し、`net/http`（Go 1.22+のパターンルーティング`GET /analysts/{sub}`）のみで実装した。DB接続には`jackc/pgx/v5/stdlib`のみを追加依存とし、Postgresのtext[]配列パースも専用ライブラリを足さずに自前の`sql.Scanner`実装で済ませた。スキーマはFlywayのようなフレームワークを使わず、アプリ起動時に`CREATE TABLE IF NOT EXISTS`を自前実行する（テストデータは投入しない。後述のseed-jobが担当）。呼び出し元の`x-auth-sub`ヘッダーとURLパスの`{sub}`が一致しない場合は404にする（account-serviceが委任元と別人の属性を覗き見できないための業務データレベルの防御）。

### DB・ロールのプロビジョニング（既知の実装漏れパターンを2度再発見・修正）

`k8s/keycloak/db-init-configmap.yaml`+`db-init-job.yaml`と同一パターンで、両サービスの`db-init-{configmap,job}.yaml`を新設した。実装の過程で、`k8s/keycloak/networkpolicy.yaml`に既に記録されていた「default-denyはPod単位でingress/egress双方に適用されるため、接続元（Job）側にも自分自身のegress許可ポリシーが要る（宛先側のingress許可だけでは不十分）」という実装漏れパターンを、`account-service-db-init`・`analyst-attribute-service-db-init`・`analyst-attribute-service-seed`の3つのJobについて再び踏んだ（実機で「postgres/edge-proxy側は許可済みなのにconnection refusedになる」という同一の症状で発覚）。`k8s/account-service/networkpolicy.yaml`・`k8s/analyst-attribute-service/networkpolicy.yaml`にそれぞれ専用のegress許可NetworkPolicyを追加して解消した。

### テストアナリスト属性の投入（`k8s/analyst-attribute-service/seed-job.yaml`）

`x-auth-sub`（`analysts.id`の一致キー）はKeycloakが発行するユーザーUUIDであり、ユーザー名ではないため、`k8s/keycloak/test-fixtures-job.yaml`がKeycloak上にユーザーを作成した後でなければ実際のUUIDが確定しない。そのため、initContainer（`quay.io/keycloak/keycloak:26.7.0`のkcadm.shでedge-proxy経由に3アナリストのUUIDを解決し、emptyDirへ書き出す）→mainコンテナ（`postgres:17.11`のpsqlで表6の内容をUPSERTする）という2段構成にした。`k8s/keycloak/test-fixtures-configmap.yaml`も、従来のyamada-analystのみから表6の3アナリスト全員を作成するよう拡張した。口座データ（accounts/transactions）はKeycloak非依存のため、account-service本体のFlyway V2__seed.sqlに同梱した。

### account-service・analyst-attribute-serviceをbase trackへ格上げする

両サービスは実データ（Postgres）を持つため、SPIRE（ADR 0016）・edge-proxy（ADR 0017）と同じ理由で、スタブ検証専用の`make deploy-verify-hop`から`make deploy`（base track）へ移した。`deploy-verify-hop`にはテストアナリスト属性投入（seed-job）のみを残した。`undeploy`/`undeploy-verify-hop`もこの移動に合わせて対応させた。

### `scripts/verify-hop.sh`を実ビジネスデータでの検証に更新する

スタブ時代の「デバッグ用エコーレスポンス」（`analyst_attribute_service: {status: 200...}`等をgrepするだけの検証）を、実際のビジネスデータへのアサーションに置き換えた。加えて、表5のABAC分岐（BR1・BR2・BR3）を実機検証する新ステップを追加した：yamada-analyst（junior・東京）が東京のhigh-value口座・大阪の口座にアクセスできないこと、suzuki-senior（senior・東京/大阪）とtanaka-junior（junior・大阪）がそれぞれの担当範囲内にアクセスできること、`GET /accounts/frozen`がアナリストごとに異なる結果セットを返すこと。POSTリクエストに`Content-Type: application/json`ヘッダーが必要になった（Spring MVCの`@RequestBody`はデバッグスタブと異なりContent-Typeを要求する）ため、`call_account_service`ヘルパー関数と、frontendスタブの`forward()`関数（Content-Typeヘッダーを転送していなかった）の両方を修正した。

## Consequences

- **[0027](0027-fraud-detection-engine-implementation.md)により一部Superseded**：本ADRのFlyway `V2__seed.sql`は、fraud-detection-engineが未実装だったためデモ用の4口座を`frozen=TRUE`・`freeze_records`付きであらかじめ投入していた。fraud-detection-engineの本実装（ADR 0027）により、この凍結状態はfraud-detection-engine自身の自動検知・凍結実行で再現されるようになったため、V2の凍結シードは`V3__remove_demo_freeze_seed.sql`で取り消した（本ADRのV2本文自体は書き換えていない。歴史的経緯として保持）
- `docs/backlog.md`の「`proposal_id`のaccount-service側実装（DB永続化）」を解消した
- `docs/services.md`のaccount-service・analyst-attribute-serviceの記述を「未着手（設計段階）」から実装済みへ更新した
- README.mdの「各サービスの実装（本実装）」チェックリストが2/6サービス完了に進んだ。残るfraud-mcp-server・fraud-detection-engine・fraud-agent・frontendは引き続きスタブのまま
- account-serviceのデータモデル（accounts/transactions/freeze_records/unfreeze_proposals/unfreeze_executions）はデモ・実機検証用の簡略化されたものであり、実際の銀行システムが持つであろう項目（取引種別、通貨、複数口座間送金の表現等）は持たない。実装を進める中で必要になれば拡張する
- NetworkPolicyの「接続元Job自身にもegress許可ポリシーが要る」という実装漏れパターンを2度目に踏んだことで、このプロジェクトにおける再発防止策（新しいJobを追加するたびに、宛先側のingress許可だけでなく接続元側のegress許可も併せて確認する）の重要性が再確認された
- frontend/fraud-mcp-server/fraud-detection-engine/fraud-agentの本実装に着手する際、それぞれがaccount-serviceの実際のAPI（表2のパスパターン、JSONレスポンス形状）を踏まえた実装になる
