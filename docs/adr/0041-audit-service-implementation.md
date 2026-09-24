# ADR 0041: audit-serviceを本実装し、account-serviceの自己申告とKeycloakの第三者記録の突合を実機で成立させる

- **Status**: Partially superseded by [0042](0042-audit-service-senior-gate.md)（ingressのmTLS+jwt_authn+rbac追加、senior限定閲覧ゲート、`client-credentials`サイドカーの`egress-auth`への改称・統合）・[0044](0044-audit-service-per-request-report.md)（突合ロジックを`sub`+時刻近接からjti+Envoyアクセスログの完全一致判定へ置き換え）
- **Date**: 2026-09-24

## Context

[ADR 0040](0040-audit-service-reconciliation.md)で、account-service自身の自己申告（`unfreeze_proposals`/`unfreeze_executions`）とKeycloak/Envoyの第三者記録（[ADR 0025](0025-audit-log-aggregation.md)でLokiへ集約済み）を突き合わせる独立した監査サービス(audit-service)を新設する方針を決定した。ステートレス・決定的なキー突合のみ（LLM不使用）という制約は決めたが、実装（言語選定、account-service側の新規API、Keycloak/SPIRE/NetworkPolicyへの横展開、実機検証）は同ADRのスコープ外として残していた。本ADRはその実装を扱う。

## Decision

### audit-serviceを新規実装する（Go標準ライブラリ）

analyst-attribute-serviceと同じ理由（単一の役割に対してフレームワークを持ち込む理由がない、ビルドが速くイメージも小さい）に加え、「検証者自身が決定的で再現可能である」というADR 0040の前提を体現する構成として、外部依存パッケージを一切持たない構成にした（`go.mod`に`require`行が無い）。

- `GET /reconcile?since=<RFC3339>`（省略時は直近24時間）が唯一の業務エンドポイント。呼び出しの都度、(a) account-serviceの`/audit/*`から自己申告を、(b) Lokiの`/loki/api/v1/query_range`から第三者記録（Keycloakイベントログ、`container="keycloak"` かつ `account:unfreeze`を含む行）を取得し、突合する。永続化は一切しない（ADR 0040のステートレス方針）
- 突合ロジック（`hasMatch`）は「自己申告の`sub`と第三者記録の`sub`が一致し、かつ時刻差が許容範囲（既定60秒、`TOLERANCE_SECONDS`で変更可）以内」という決定的なキー一致判定のみ。LLMは一切使わない〔[ADR 0044](0044-audit-service-per-request-report.md)で訂正：この`sub`+時刻近接による近似一致は、トークン識別子(jti)とaccount-service自身のEnvoyアクセスログによる完全一致判定に置き換えられた〕
- 突合対象は`decided_at`（提案の承認/却下）・`executed_at`（凍結解除実行）の2つのみ、いずれも`account:unfreeze`スコープを要求する操作（表2）。`account:propose`（提案の新規作成、可逆・低リスク）は対象外——不可逆・高リスクな操作の実在性を裏付けることが本来の目的のため
- **片方向のみの突合**：自己申告→第三者記録の対応（「対応する第三者記録が見つからない自己申告」の検知）のみを実装し、逆方向（「対応する自己申告が無い第三者記録」の検知）は実装しなかった。account:unfreezeスコープのToken Exchange自体は、account-service側が403/409等で拒否した試行（例：承認されていない提案の実行試行）でも発生するため、逆方向を素朴に実装すると通常運用の拒否ケースを大量に「不整合」として検出してしまい、ノイズになる。片方向のみでも「自己申告側の改ざん・欠落」は検知できるため、ADR 0040の核心の主張（一方だけの改ざんは不整合として検知できる）は損なわれない
- ingressにjwt_authn/rbacを持たせていない。「誰が突合結果を閲覧できるか」はADR 0040で未決定のまま残した将来課題であり（architecture.md §11参照）、今回は`kubectl port-forward`での到達のみを前提にする（`k8s/observability/`のGrafanaと同じ位置づけ）。ADR 0009 §2の多層防御のうち①②（loopback限定bind・接続元loopbackチェック）は引き継いだが、③（合言葉ヘッダー）は「rbac通過後にのみ付与」という前提自体が成立しない（検知すべきバイパス対象がそもそも無い）ため見送った。認証・認可を追加する際に③も追加する〔[ADR 0042](0042-audit-service-senior-gate.md)で訂正：senior限定閲覧ゲートのためmTLS+jwt_authn+rbac（`audit:read`）+③を追加し、`kubectl port-forward`前提から変更〕

### account-serviceに監査専用の読み取り専用API（`/audit/*`）を追加する

`GET /audit/unfreeze-proposals?since=`・`GET /audit/unfreeze-executions?since=`を新設した。fraud-detection-engineの`freeze()`と同じ機械間認証パターン（`x-auth-sub`を要求しない、analyst-attribute-serviceへの照会は行わない）を踏襲する。新しいDB migrationは不要（既存の`unfreeze_proposals`/`unfreeze_executions`テーブルへの読み取り専用クエリを`AccountRepository`に追加しただけ）。レスポンスは既存の`UnfreezeProposal`/`UnfreezeExecution`ドメインレコードをそのまま返す（`freeze()`/`unfreeze()`が既にこのパターンを採用している）。

`k8s/account-service/envoy-configmap.yaml`のingress rbacに`audit`ポリシー（`GET /audit/**`、`account:audit`スコープ要求）を追加し、mTLSのSAN許可リストにaudit-serviceのSPIFFE IDを追加した。

### Keycloak: `audit-service`クライアント・`account:audit`スコープを新設する

fraud-detection-engineと同じ構成（confidential、`serviceAccountsEnabled: true`、`clientAuthenticatorType: federated-jwt`、client_credentials。standard token exchangeは使わない）。`account:audit`スコープは対象audience=account-serviceの単一audienceスコープで、`audit-service`のみに`optionalClientScopes`として付与する。

### SPIRE: audit-serviceのSPIFFE ID登録

fraud-detection-engineと同じ2entry構成（`k8s:container-name:envoy`と`k8s:container-name:client-credentials`）。client_credentialsサイドカーの実装（`k8s/audit-service/client-credentials-app-configmap.yaml`）自体もfraud-detection-engineのものをそのまま流用し、`CLIENT_ID`/`FIXED_SCOPE`のみを差し替えた。〔[ADR 0042](0042-audit-service-senior-gate.md)で訂正：analyst-attribute-service向けToken Exchangeも扱うようになったため、コンテナ名・SPIRE entry selectorを`egress-auth`に改称し、実装ファイルも`k8s/audit-service/egress-auth-app-configmap.yaml`へ統合した〕

### NetworkPolicy

audit-service自身のegress（account-service:8080、keycloak:8443、`observability` namespaceのotel-lgtm:3100）を新設した。LokiはKeycloakクライアント登録が無くOAuth/mTLSのメッシュに参加していない（Token Exchangeもmtlsも介さないプレーンHTTP）ため、宛先制御はNetworkPolicyのみで行う。`k8s/observability/networkpolicy.yaml`のotel-lgtm向けingressルールに、`namespaceSelector`（`kubernetes.io/metadata.name: gekko`）+`podSelector`（`app: audit-service`）の組み合わせで許可を追加した（`gekko` namespaceからの越境ingressはこれが初めて）。ingress自体は無し（`kubectl port-forward`のみを前提にする。Grafanaと同じ理由でNetworkPolicyのingressルールは不要）。

### 実機検証で発覚した2件の抜け（このADRのコミットで是正）

いずれも「呼び出し元を1つ追加する際は、影響を受ける全ての許可リストを更新する」という既存の運用パターン（ADR 0017/0018が既に確立していたもの）の実装漏れであり、決定内容自体の変更ではないため新規のAmendsは起こさず、本ADRのコミットでその場で是正した。

1. **KeycloakのNetworkPolicy ingress許可リスト漏れ**：`k8s/keycloak/networkpolicy.yaml`のingress許可（fraud-mcp-server・fraud-detection-engine・account-service等の名指しallowlist）にaudit-serviceを追加し忘れており、client-credentialsサイドカーからのToken取得リクエストが`Connection refused`（`k8s/keycloak/networkpolicy.yaml`末尾のkeycloak-db-init/keycloak-test-fixturesの回で既に記録されていたのと同種の症状）で失敗した
2. **KeycloakのEnvoy mTLS SAN許可リスト漏れ**：`k8s/keycloak/envoy-configmap.yaml`の`match_typed_subject_alt_names`にaudit-serviceのSPIFFE IDを追加し忘れており、1を修正した後も`SSLV3_ALERT_CERTIFICATE_UNKNOWN`でTLSハンドシェイク自体が拒否された

### k3d docker networkサブネットのドリフトを是正（このADRの実機検証中に発覚、副次的な修正）

本ADRの実機検証（Lokiへの実データ投入確認）の過程で、`k8s/observability/networkpolicy.yaml`・`k8s/edge-proxy/networkpolicy.yaml`が参照するk3dノードCIDRが、実際のdocker networkサブネット（`172.18.0.0/16`。当時の記録値は`172.19.0.0/16`）とずれており、監査ログ集約パイプライン自体（[ADR 0025](0025-audit-log-aggregation.md)）が機能停止していたことを発見した。[ADR 0018](0018-network-policy-default-deny.md)のContext自身が「別のdocker network構成でクラスタを再作成した場合は実機で再確認が必要」と明記していた通りの環境ドリフトであり、決定の変更ではないため当該ADR本文は書き換えず、両ファイルの値のみ実環境に合わせて修正した。詳細は[insights.md](../insights.md)「k3d docker networkサブネットのドリフト」節を参照。

### 検証

`scripts/verify-hop.sh`（UC1の直接実行パス、`proposalId`省略の凍結解除実行）を実行して`unfreeze_executions`に実データを作った上で、`scripts/verify-audit-service.sh`（新設）で`kubectl port-forward svc/audit-service`経由の`GET /reconcile`を実機で確認した。自己申告4件（`executions.total=4`）全てについて対応するKeycloakの`TOKEN_EXCHANGE`（`account:unfreeze`）イベントが見つかり、`verified=4`・`unverified=[]`であることを確認した。

承認/却下（`decided_at`）経路は、現行の`scripts/verify-hop.sh`のシナリオが`approve`/`reject`エンドポイントを呼ばないため実機データが無く、ライブでは確認できなかった。同一の決定的ロジック（`hasMatch`）を使う経路のため、`services/audit-service/main_test.go`で「対応する第三者記録が第三者記録側に一切無い自己申告はunverifiedとして検知される」ことをユニットテストで決定的に検証した（自己申告のみを改ざんしたケースの実機再現は、account-serviceのDB認証情報を直接操作する必要があり本ADRのスコープ外とした）。

## Consequences

- 影響範囲：`services/audit-service/`（新設）、`services/account-service/`（`AccountController`/`AccountRepository`に`/audit/*`追加）、`k8s/audit-service/`（新設）、`k8s/account-service/envoy-configmap.yaml`・`networkpolicy.yaml`、`k8s/keycloak/realm-configmap.yaml`・`envoy-configmap.yaml`・`networkpolicy.yaml`、`k8s/spire/entries-configmap.yaml`、`k8s/observability/networkpolicy.yaml`、`k8s/edge-proxy/networkpolicy.yaml`（CIDRドリフト是正）、`Makefile`、`scripts/sync.sh`、`scripts/verify-audit-service.sh`（新設）
- `docs/architecture.md` §4（クライアント/スコープ表）・§8（データストア表）・§9（監査。突合の実装詳細に更新）・§11（該当項目を削除）、`docs/services.md`（audit-service節を新設）を本コミットで更新した
- 監査サービス自身の突合結果を誰が閲覧できるか（認可設計・frontendからの見せ方）は引き続き未決定のまま`architecture.md` §11に残した
- `account:propose`（提案の新規作成）は突合対象に含めていない。将来この操作も含めたくなった場合、`propose`は元々`account:propose`スコープでありToken Exchangeの相関キー自体は既に取得可能なため、`fetchDecidedProposals`と同様の追加で対応できる
