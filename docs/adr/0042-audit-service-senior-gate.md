# ADR 0042: audit-serviceの突合結果閲覧をsenior analyst限定にし、frontendに監査画面を追加する

- **Status**: Accepted
- **Date**: 2026-09-24
- **Amends**: [0021](0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)（表3の呼び出し元をaccount-service単独からaccount-service・audit-serviceの2件へ拡張。「委任チェーンの終端」という性質自体、account-service以外のAIエージェント経由経路（fraud-mcp-server等）が到達できないという制約は変わらない）
- **Amends**: [0041](0041-audit-service-implementation.md)（ingressにjwt_authn/rbacが無く`kubectl port-forward`のみを前提にしていた構成を、mTLS+jwt_authn+rbac+senior限定ゲート付きへ変更。client_credentials単体だった`client-credentials`サイドカーを、Token Exchangeも扱う`egress-auth`サイドカーへ改称・統合）

## Context

[ADR 0040](0040-audit-service-reconciliation.md)/[0041](0041-audit-service-implementation.md)でaudit-serviceを実装したが、突合結果（`GET /reconcile`）は`kubectl port-forward`での到達のみを前提にしており、画面上のリンクも認可も無かった（`docs/architecture.md` §11に「誰が閲覧できるか」を未決定事項として残していた）。

BR1〜BR3（アナリストの担当地域・権限レベルに基づくアクセス制御）は口座単位の軸だが、audit-serviceの突合結果は特定の口座に閉じない全件横断のデータであり、この軸をそのまま適用できない。ユーザーと協議した結果、senior analystのみに閲覧を限定する方針（既存のjunior/senior区分をそのまま流用し、新しい役割・資格情報は増やさない）で合意した。

## Decision

### 閲覧をsenior analystに限定する（BR11新設）

[requirements.md](../requirements.md)にBR11を新設した。表5の口座別ABAC（地域・ティア）とは独立した単純な二値ゲートとし、閲覧できる場合は担当地域に関わらず全件が対象になる（口座ごとの絞り込みは行わない、意図的な簡略化）。

### frontend: 監査画面(`/audit`)とToken Exchange経路(`audience=audit-service, scope=audit:read`)を追加する

新設した`audit:read`スコープ（対象audience=audit-service）をfrontendの`optionalClientScopes`にのみ付与した。frontendの`SCOPE_RULES`（`k8s/frontend/token-exchange-app-configmap.yaml`）に`("audit-service", ^/reconcile$, GET, audit:read)`を追加し、他の委任パスと同じ形（Envoy egressのext_authzによる透過的Token Exchange）でaudit-serviceを呼べるようにした。`server/routes/reconcile.get.ts`（`server/routes/accounts/[...].ts`と同型のプロキシ）と`pages/audit.vue`を新設し、`layouts/authenticated.vue`のナビゲーションに「監査」リンクを追加した。画面へのリンク自体は全ログインユーザーに表示する（junior/seniorで出し分けない）——閲覧可否の強制はサーバー側（audit-service）で行い、frontend側での表示制御は権限の実効性に影響しないため、`/me`の拡張（levelを返す）は今回見送った。junior analystが開いた場合は403を受けてその旨を画面に表示する。

### audit-service: ingressにmTLS+jwt_authn+rbacを追加し、senior限定ゲートを実装する

`k8s/audit-service/envoy-configmap.yaml`のingressに、他サービスと同じ構成（mTLS、SAN許可リストはfrontendのみ／jwt_authn:audience=audit-service／rbac:`audit:read`保有のみ許可／lua合言葉）を追加した。ADR 0040/0041時点では「rbacが無いためバイパス対象が無い」としてADR 0009 §2③の合言葉層を省略していたが、rbacが実在するようになったため他サービスと同じ3層防御（handshake-init initContainer・lua付与・アプリ側検証）を揃えた。

アプリ（`services/audit-service/main.go`）に`seniorGate`を追加した。`GET /reconcile`ハンドラの前段に挟み、リクエストの`x-auth-sub`と`Authorization`ヘッダーを使ってanalyst-attribute-serviceの`GET /analysts/{sub}`へ照会し、`level == "senior"`でなければ403を返す。account-serviceへの自己申告取得（client_credentials、`account:audit`）とは完全に独立した経路であり、閲覧ゲートが失敗しても自己申告データの取得ロジック自体には触れない。

#### 技術的な制約: Envoyのext_authzは1リスナーにつき1つの宛先しか持てない

audit-serviceは今回、account-service向け（client_credentials、委任なし）とanalyst-attribute-service向け（Token Exchange、frontendから委任されたトークンの転送）という性質の異なる2種類のegress認証を、同じegressリスナー上で行う必要が生じた。EnvoyのExtAuthzPerRoute（`typed_per_filter_config`）は`disabled`と`check_settings`のみを上書き可能で、ext_authzの接続先（`http_service.server_uri`）自体はリスナー単位で1つに固定される（ルートごとに別のext_authzサーバーへ向けることはできない）。

このプロジェクトで2種類のegress認証パターンが同居するのはaudit-serviceが最初である。宛先ごとに別サイドカー・別リスナーへ分割する案も検討したが、hostAliasesは（ポートを指定しない限り）宛先ホスト名によらず同じ127.0.0.1へ横取りする仕組みのため、ポート単位で経路を分けるとアプリ側のURL（`http://analyst-attribute-service`等）に明示的なポート指定が必要になり、「実サービス名・実APIパスをそのまま使う」という原則（[ADR 0010](0010-egress-listener-granularity.md)）を崩す。代わりに、単一のサイドカー（`egress-auth`、`k8s/audit-service/egress-auth-app-configmap.yaml`）がext_authzのCheckRequestに自動転送される`Host`ヘッダーを見てgrant_typeを内部で出し分ける方式にした（fraud-detection-engine(ADR 0020、client_credentials単体)とaccount-service(表3、Token Exchange単体)の2つの既存パターンを1コンテナに統合した形）。

### analyst-attribute-service: audit-serviceを2件目の呼び出し元として許可する（表3拡張、ADR 0021 Amends）

`k8s/analyst-attribute-service/envoy-configmap.yaml`のmTLS SAN許可リストと`networkpolicy.yaml`のingress許可リストに、audit-serviceを追加した。account-service経由のAIエージェント系経路（fraud-mcp-server等）がanalyst-attribute-serviceへ直接到達できないという制約（BR4を支える不変条件）は変わらない——audit-serviceの追加は「AIエージェントの閲覧範囲」とは無関係な、senior限定閲覧ゲートという別目的の呼び出しであり、いずれもToken Exchangeでsubを元のアナリスト本人のまま維持し、analyst-attribute-service自身の`x-auth-sub`一致チェック（本人以外の属性照会を防ぐ、`services/analyst-attribute-service/main.go`）を通過する必要がある点は共通する。

### 検証

`scripts/verify-audit-service.sh`を全面的に書き換えた。ADR 0040/0041時点は`kubectl port-forward`への素のcurlで検証していたが、ingressにmTLSが必須になったため到達できなくなった（実機で確認：TLSハンドシェイクが無い接続は`healthz`ポーリングがタイムアウトするまで無応答）。`scripts/verify-hop.sh`と同じ実機ログイン手法（`login_via_frontend`、ヘッドレスブラウザなしでKeycloakのform_postログインフォームを直接POST）でfrontend経由の正規経路を通す形に更新し、以下を実機確認した：

- suzuki-senior（senior）でログイン→`GET /reconcile`が200、自己申告5件全てが第三者記録と一致（`verified=5/5`）
- yamada-analyst（junior）でログイン→同じ`GET /reconcile`が403

## Consequences

- 影響範囲：`docs/requirements.md`（BR11新設）、`docs/architecture.md`（§4クライアント/スコープ表・§5パス④新設・表3拡張・§9・§11該当項目削除）、`docs/services.md`（audit-service/analyst-attribute-service/frontend各節）、`k8s/keycloak/realm-configmap.yaml`（`audit:read`スコープ新設、audit-serviceクライアントにstandard token exchange有効化+`analyst:read`追加、frontendクライアントに`audit:read`追加）、`k8s/audit-service/`（ingressのmTLS+jwt_authn+rbac追加、`client-credentials-app-configmap.yaml`を`egress-auth-app-configmap.yaml`に統合・改称）、`k8s/analyst-attribute-service/`（呼び出し元許可リスト拡張）、`k8s/frontend/`（`audit-service`向けegress・SCOPE_RULES追加）、`services/audit-service/main.go`（senior gate、handshake検証）、`services/frontend/`（`server/routes/reconcile.get.ts`・`pages/audit.vue`・ナビゲーション新設）、`k8s/spire/entries-configmap.yaml`（`client-credentials`→`egress-auth`へのコンテナ名selector変更）、`scripts/verify-audit-service.sh`（frontend経由の実機ログイン検証へ全面書き換え）
- ADR 0021のStatus行を`Partially superseded by 0042`に更新し、本文中の該当箇所に訂正注記を追加した（本文自体は書き換えない）
- 閲覧できる場合は担当地域に関わらず全件が対象になる（表5のような地域/ティア単位の絞り込みは行わない、意図的な簡略化）。将来、地域単位で閲覧範囲を絞りたくなった場合は、表5と同様のABAC判定をaudit-service（またはaccount-serviceの`/audit/*`API）側に追加する必要がある
- frontendの`/me`はlevelを返さないままのため、junior analystにも「監査」リンク自体は表示される（クリック後に403で拒否される）。UXとして事前に非表示にしたい場合は`/me`の拡張が必要
