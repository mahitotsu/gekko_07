# アーキテクチャ設計

本ドキュメントは現在有効なアーキテクチャの断面と、それを支える認可のディシジョンテーブル・実行時シナリオ・既知の制約を一体で記録する（§6・§10・§11）。何を・なぜ実現するか（目的・背景・要求水準、業務要件BR0〜BR8を含む）は[requirements.md](requirements.md)、個々の設計判断の根拠・選択経緯は[docs/adr/](adr/)、各サービスの存在意義は[services.md](services.md)を参照。決定が変わった場合は該当箇所を直接書き換え、対応するADRをSupersededに更新する。

## 1. 採用する認可サーバー

**Keycloak**を使用する（バージョン・realm設計の詳細は実装時に決定）。トークンのクレームに含めるデータと、業務サービス側に外部化して都度照会するデータの切り分けは、役割（委譲の天井か実行時の個別業務判断か）・オーナーシップ・機密性の3軸で判断する（[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)）。この基準の具体的な適用例は§6「認証」節を参照。

## 2. シナリオとサービス構成

金融の不正検知・口座凍結解除（[ADR 0001](adr/0001-scenario-fraud-detection-with-agent-assist.md)・[ADR 0011](adr/0011-scenario-ai-assisted-unfreeze.md)）。

```
[アナリスト] --ログイン--> [frontend]
                              │
              ┌───────────────┼────────────────────┐
              │ (提案生成パス)                        │ (確定パス)
              ▼                                     ▼
      [fraud-agent] --MCP--> [fraud-mcp-server] --> [account-service] <-- [fraud-detection-engine]
                                                          │
                                                          ▼
                                              [analyst-attribute-service]
```

各サービスの存在意義・提供機能・保有データは[services.md](services.md)を参照。認証（ログイン時に発行されるトークンの内容）は§6を参照。

## 3. Token Exchangeの実装方式

**各サービスのEnvoyサイドカーから呼ばれるext_authzサービスとして実装する**（[ADR 0002](adr/0002-token-exchange-in-envoy-sidecar.md)）。アプリケーション本体にはToken Exchangeのコードを一切持たせない。

- 各サービスのPodは**initContainer 1つ＋アプリコンテナ＋Envoyサイドカーの構成**（initContainerの役割は§3後半・[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)参照）。Envoyサイドカーはネイティブsidecarコンテナ（`initContainers`の`restartPolicy: Always`）として実装しており、Postgresに接続するサービス（keycloak・account-service・analyst-attribute-service・fraud-detection-engine）はその後ろに`wait-for-postgres` initContainerを置き、appコンテナの起動をPostgres疎通確認後まで遅らせている（[ADR 0028](adr/0028-postgres-mtls-tcp-proxy.md) Consequences、[insights.md](insights.md)参照。edge-proxyのみEnvoy単体Podのため対象外）
- アプリは相手サービスの**実サービス名・実APIパスをそのまま**使ってリクエストを組み立てる（例：`http://account-service/accounts/123/transactions`）。人工的なURLプレフィックスやegress専用ポートは使わない。Podの`hostAliases`で相手サービス名を`127.0.0.1`へ静的にマッピングし、Envoyサイドカーが1つのリスナー上の複数`virtual_hosts`（`domains`でサービス名をマッチ）で受け、`ext_authz`（HTTPモード）フィルタが横取りしてToken Exchangeを実行してから実際のアップストリームへ転送する（[ADR 0010](adr/0010-egress-listener-granularity.md)）
- **audienceはHostヘッダーから自動導出する**。Keycloakクライアントid＝Kubernetes Service名＝audience名を常に同一の文字列にする（MUST。§6表1の既存の前提をKubernetes Service名にも拡張したもの）ため、ext_authzサービスはCheckRequestに**自動転送される**`Host`ヘッダー（後述）をそのまま`audience`として使え、リスナー・ルートごとの明示設定が不要になる
- **scopeは常に「相手サービスの(パス, メソッド) → scope」という単一の仕組みで決める**（§6表2に拡張済みの対応表。account-service自身のingress側rbacポリシーと共有する単一の情報源）。特別扱いするケースはない——scopeがpathによらず1つだけのホップ（fraud-detection-engine→account-service、account-service→analyst-attribute-service、frontend→fraud-agent、fraud-agent→fraud-mcp-server）は、この仕組みがワイルドカードルート1本に潰れているだけ。scopeがpathで変わるホップ（frontend→account-service、fraud-mcp-server→account-service。それぞれ`account:read`/`account:unfreeze`、`account:read`/`account:propose`）は複数ルートになる。パスパターンは表2に決まっているため、account-serviceの完全なAPI実装を待たずに全ホップのEnvoy route設計が今すぐ完成する。アプリのコードは常に実ホスト名・実パス・実メソッドで普通にAPIを呼ぶだけで、どちらのケースかを意識しない
  - この対応表は**ext_authzサービス自身がコードとして持つ**。HTTPモードのext_authzは`Host`・`Method`・`Path`・`Content-Length`・`Authorization`を常に自動転送するため（Envoyの標準動作。`ExtAuthzPerRoute`の`context_extensions`はgRPCモード限定で使わない。[ADR 0010](adr/0010-egress-listener-granularity.md)の訂正箇所参照）、Envoy側のroute設定はどのクラスタへ転送するかという宛先の振り分けだけを担う
- egressで必要な処理は2種類ある（ADR 0010、[ADR 0014](adr/0014-fraud-agent-token-exchange.md)で③④廃止）：①Token Exchange（大半のホップ、透過的プロキシ。frontend→fraud-agent・fraud-agent→fraud-mcp-serverもここに含まれる）②client_credentials発行（fraud-detection-engine→account-service、透過的プロキシ）。[ADR 0030](adr/0030-fraud-agent-implementation.md)でfraud-agent→Anthropic API向けに3つ目のegressパターンが加わった：Keycloak登録済みaudience宛てではない（メッシュ外の公開エンドポイントのため①②いずれにも該当しない）ため、appは内部専用の別名（`anthropic-gateway`、`ANTHROPIC_BASE_URL`環境変数で指定）経由で接続し、Envoyが公開CA検証でTLSを終端して実際の`api.anthropic.com`へ再接続する
- `ext_authz`の応答ヘッダー許可リスト（①②とも`allowed_upstream_headers`に`Authorization`を含める）
- 以下の全6ホップでToken Exchange/client_credentialsが動作する：fraud-mcp-server→account-serviceの`account:read`/`account:propose`（パターン①）、fraud-detection-engine→account-serviceの`account:freeze`（パターン②、client_credentials）、account-service→analyst-attribute-serviceの`analyst:read`（表3）、fraud-agent→fraud-mcp-serverの`account:read`（[ADR 0023](adr/0023-fraud-agent-fraud-mcp-server-hop.md)）、frontend→account-serviceの`account:read`/`account:unfreeze`・frontend→fraud-agentの`account:read`（[ADR 0024](adr/0024-frontend-edge-proxy-and-simplified-login.md)）。frontendのログインはAuthorization Code + PKCE（[ADR 0031](adr/0031-frontend-implementation.md)）。各ホップの実装場所は`k8s/account-service/`・`k8s/fraud-mcp-server/`・`k8s/fraud-detection-engine/`・`k8s/analyst-attribute-service/`・`k8s/fraud-agent/`・`k8s/frontend/`。end-to-endの検証ウォークスルーは§10、実行可能な検証は`scripts/verify-hop.sh`、実機で見つかった罠は[insights.md](insights.md)を参照
- パターン①（fraud-mcp-server→account-service）・パターン②（fraud-detection-engine→account-service）・表3（account-service→analyst-attribute-service）とも、Token Exchange/client_credentials実行主体は各呼び出し元自身のPod内サイドカーに置き、クライアント認証はSPIRE発行JWT-SVID（KeycloakネイティブのSPIFFE対応）を使う（[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)・[ADR 0020](adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)・[ADR 0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)）
- Keycloak側で見落としやすい前提：Token Exchangeの`audience`パラメータが実際に解決されるには、要求元クライアントに割り当てたclient scope（`account:read`等）が、対象audienceを指す`oidc-audience-mapper`（protocol mapper）を持っている必要がある（[k8s/keycloak/realm-configmap.yaml](../k8s/keycloak/realm-configmap.yaml)）。`account:read`のように同名scopeが複数audience（account-service・fraud-agent・fraud-mcp-server）へ使われる場合は、そのscopeに全てのマッパーを持たせてよい——実際に発行されるトークンは、その時の`audience`パラメータで指定した1つだけに絞り込まれ、単一audience原則（[ADR 0005](adr/0005-single-audience-tokens-only.md)）は保たれる（実機で確認済み）

**サイドカーの受信側（ingress）の責務**（[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)）：

- JWT検証（`jwt_authn`フィルタ：署名・`iss`・`exp`・`aud`がこのサービス自身であること）とscope検証（`rbac`フィルタ：§6表2）はEnvoy側で完結させる。表5等の業務データに依存する認可判定自体はアプリ内に残さざるを得ない（理由は[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)参照）
- 検証済みの身元はヘッダー（`x-auth-sub`等）でアプリへ転送し、アプリは自前のJWTライブラリを持たない。`jwt_authn`の`claim_to_headers`設定でクレームからヘッダーへ直接変換できる（実機確認済み。[k8s/account-service/envoy-configmap.yaml](../k8s/account-service/envoy-configmap.yaml)）ため、別フィルタでのクレーム転記は不要
- **Envoyを経由しない直接アクセスのバイパス防止**（3層。詳細はADR 0009）：①アプリは`127.0.0.1`にのみbindし、Serviceはアプリのポートではなく Envoyのリスナーを指す（構造的な防止）②アプリ自身も接続元がloopbackでなければ拒否する（多層防御）③initContainerがPod起動時に生成しemptyDirで共有する使い捨ての合言葉を、jwt_authn/rbacを通過した後にのみEnvoyがヘッダーへ付与し、アプリはこれを検証してから他の認証ヘッダーを信用する（Envoyの設定ミスや誤操作によるバイパスの検知）。付与方式はADR 0009が候補に挙げた`envoy.filters.http.lua`を採用し、rbacより後段に置くことでフィルタ順序による保証を実現した（実機確認済み）
- 上記②③の検証ロジックはk8s環境外でもテスト可能にする。ただし「テスト時は検証をスキップする」条件分岐は作らない（[CWE-489](https://cwe.mitre.org/data/definitions/489.html)）。検証ロジックは環境によらず単一とし、期待値の読み出し元（ファイルパス等）のみ環境変数で設定可能にする

**mTLS（ワークロードID）**：上記のOAuth Token Exchangeは「誰が何をしてよいか」という業務認可層であり、「誰と話しているか」という通信路の身元検証・暗号化とは独立の関心事である。fraud-mcp-server→account-service（[ADR 0012](adr/0012-spiffe-spire-mtls-single-hop.md)）・fraud-detection-engine→account-service（[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)）・account-service→analyst-attribute-service（[ADR 0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)）・fraud-agent→fraud-mcp-server（[ADR 0023](adr/0023-fraud-agent-fraud-mcp-server-hop.md)）・frontend→account-service/fraud-agent（[ADR 0024](adr/0024-frontend-edge-proxy-and-simplified-login.md)）の全ホップは、SPIFFE/SPIREが発行するX.509-SVIDによるmTLS＋ALPNネゴシエーションのHTTP/2で接続する（`k8s/spire/`）。SPIRE agentのWorkload API（UDS）をEnvoyのSDSフィルタが参照し、証明書のプロビジョニング・ローテーションはSPIREが自動で行うため、Envoy bootstrap設定・アプリ本体のどちらにも証明書のライフサイクル管理コードは一切現れない。account-serviceのingressリスナーは単一のmTLS必須filter_chainのみで構成されており、plaintextでの到達経路は存在しない。fraud-agent→Anthropic APIのみ例外で、信頼メッシュの外にあるクラスタ外エンドポイントのためSPIRE mTLS（SPIFFE SDS）の対象ではなく、Envoyは通常のTLSクライアントとして公開CA検証でこの接続を終端する（[ADR 0030](adr/0030-fraud-agent-implementation.md)）。Keycloakが検証する身元（mTLS/JWT-SVID）と主張するclient_idは、fraud-mcp-server・fraud-detection-engine・account-serviceのいずれのホップでも一致する（[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)・[ADR 0020](adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)・[ADR 0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)）。

送信者拘束（DPoP、RFC 9449）は採用していない。検討経緯は[ADR 0013](adr/0013-dpop-sender-constraining.md)・[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)、再検討時の実機知見は[insights.md](insights.md)、再検討の要否は§11を参照。

**NetworkPolicy（L3/4のdefault-deny）**（[ADR 0018](adr/0018-network-policy-default-deny.md)）：上記2層（業務認可・mTLS）とは独立な3層目として、`gekko` namespace全体にingress/egress双方向のdefault-denyを導入し、実装済みの接続経路のみを明示的に許可する。`spire` namespace（hostNetworkで動くspire-agent等）は本ADRの対象外（§11参照）。Keycloakのkubelet向けhttp-mgmt:9000はexecプローブ化し`KC_HTTP_MANAGEMENT_HOST=127.0.0.1`に限定しているため、ネットワーク経由では誰からも到達不能（[ADR 0022](adr/0022-keycloak-mgmt-probe-exec.md)）。共有Postgresインスタンス（8節参照）は、常駐4サービス（keycloak/account-service/analyst-attribute-service/fraud-detection-engine）およびdb-init/seed Job（1回限りの初期化Job。ネイティブsidecarコンテナでEnvoyを持つ）の接続を全てEnvoyのtcp_proxy＋mTLS配下に置き（[ADR 0028](adr/0028-postgres-mtls-tcp-proxy.md)）、平文5432への直接到達経路（NetworkPolicyの許可ルール・Serviceのポート）を持たない。fraud-agentのみ例外があり、Anthropic API（`api.anthropic.com`）向けにpodSelectorで宛先を特定できない公開インターネットegress（`ipBlock 0.0.0.0/0`からRFC1918プライベートレンジを除外した範囲、port 443のみ）を許可している（[ADR 0030](adr/0030-fraud-agent-implementation.md)）。

## 4. Keycloakのクライアント・スコープ設計

**クライアント**

| クライアント | 種別 | 備考 |
|---|---|---|
| `frontend` | confidential, standard token exchange有効 | アナリスト向けBFF |
| `fraud-agent` | confidential, standard token exchange有効 | AIエージェント本体。frontendから受け取ったトークンを自身でfraud-mcp-server宛てに再exchangeする（[ADR 0014](adr/0014-fraud-agent-token-exchange.md)） |
| `fraud-mcp-server` | confidential | AIエージェントの代理としてaccount-serviceを呼ぶ |
| `fraud-detection-engine` | confidential, client_credentials | 機械間認証。ユーザー委任なし |
| `account-service` | confidential | analyst-attribute-serviceへの委任元 |

全てのトークンは常に単一のaudienceのみを持つ（[ADR 0005](adr/0005-single-audience-tokens-only.md)）。ログイントークンは`aud=frontend`（単一。内容は§6参照）のみで、`account:read`等のスコープは持たない。frontendがaccount-serviceにアクセスする際（直接・委任いずれも）は、都度明示的なToken Exchangeで単一audienceのトークンを取得する（§5参照）。

**スコープとトポロジー制御**（各クライアントに付与するoptional client scopeのみで委任トポロジーを制御する。Client Policiesは使わない）

| スコープ | 対象audience | 付与するクライアント | 意味 |
|---|---|---|---|
| `account:read` | account-service | frontend, fraud-mcp-server | 取引・口座の読み取り |
| `account:read` | fraud-agent | **frontend のみ** | AIエージェントとのチャット開始（委任チェーンの入口。[ADR 0014](adr/0014-fraud-agent-token-exchange.md)） |
| `account:read` | fraud-mcp-server | **fraud-agent のみ** | MCPツール呼び出し（[ADR 0014](adr/0014-fraud-agent-token-exchange.md)） |
| `account:propose` | account-service | fraud-mcp-server のみ | 凍結解除案の記録（可逆・低リスク） |
| `account:freeze` | account-service | **fraud-detection-engine のみ** | 口座凍結の自動実行（機械間認証。業務属性チェックなし） |
| `account:unfreeze` | account-service | **frontend のみ** | 口座凍結の解除の実行（不可逆・高リスク） |
| `analyst:read` | analyst-attribute-service | account-service のみ | アナリストの担当地域・権限レベル照会 |

`account:unfreeze`は`fraud-mcp-server`にも`fraud-agent`にも一切付与しない。AIエージェントがどれだけ「解除すべき」と提案しても、Keycloakのスコープ設計上そもそも凍結解除APIを呼べるトークンを取得できない、という形で認可レイヤーで強制する（§6表1・表2）。

## 5. トークンチェーン

ログイントークン（`aud=frontend`、単一audience、それ以上のスコープを持たない。詳細は§6参照）を起点に、目的ごとに異なる単一audienceトークンを都度Token Exchangeで取得する（[ADR 0005](adr/0005-single-audience-tokens-only.md)）。frontendが「ログイントークンをそのまま使う近道」は存在しない。

**① 提案生成パス（AI起因、読み取り＋提案のみ）**
```
analystトークン(aud=frontend)
  → Token Exchange (frontend実行, audience=fraud-agent, scope=account:read)
  → Token Exchange (fraud-agent実行, audience=fraud-mcp-server, scope=account:read)
  → Token Exchange (fraud-mcp-server実行, audience=account-service, scope=account:read/account:propose)
  → account-serviceがToken Exchange (audience=analyst-attribute-service, scope=analyst:read) でアクセス制御
```

**② 確定パス（人間起因、決定論的操作）**
```
analystトークン(aud=frontend)
  → Token Exchange (frontend実行, audience=account-service, scope=account:unfreeze)
  → account-serviceが同じくanalyst-attribute-serviceへ照会（提案生成パスと同じ判定ロジック）
  → 凍結解除を実行。①で記録された提案IDと紐付けて記録
```

**③ 自動凍結パス（機械間、業務属性チェック対象外）**
```
fraud-detection-engineの client_credentials トークン(scope=account:freeze)
  → account-serviceが通常のスコープチェックのみで処理（analyst-attribute-serviceへの照会は発生しない）
```

`sub`は①②を通じて常に元のanalystのまま維持される（Impersonation方式、Keycloak Standard Token Exchange V2を使用予定）ため、「AIが何を見て何を提案したか」と「人間が何を確定したか」を同一`sub`かつ異なる`jti`/`scope`で追跡でき、監査で再構成できる。①②はどちらもfrontendが自身のログイントークン（`aud=frontend`）を`subject_token`として、目的の異なる別々のToken Exchangeを実行した結果であり、1つのトークンが複数の用途を兼ねることはない。

## 6. 認可のディシジョンテーブル

[requirements.md](requirements.md)「業務要件（アクセス制御）」で定めた業務要件（BR0〜BR8）を、上記§3〜§5の認可設計がどう実現しているかを、条件と結果が漏れなく列挙できる形（ディシジョンテーブル）で示す。各表の見出しに対応する要件番号を明記し、業務要件と実装の対応関係を追跡できるようにする。性質の異なる認可判断ごとに表を分ける。

### 認証（アナリストのログイントークン、BR0に対応）

以降の表は全て「認証済みの主体が保持するトークン」を前提にしている。ここではその出発点、すなわちアナリストがログインした時点で何が発行されるかを定める。BR0（認証の必須化）は、ここで発行されるログイントークンを持たない限り、以降のどのToken Exchangeも開始できない、という形で実現される。

アナリストはOAuth 2.0 Authorization Code + PKCEでKeycloakにログインする。frontendはconfidential clientとして、ブラウザから受け取ったauthorization codeをKeycloakのトークンエンドポイントで自身のクライアント資格情報とともにアクセストークンに交換する（このやり取り自体はToken Exchangeではない、通常のOIDC認可コードフロー）。

ここで発行される**ログイントークン**の内容は以下の通り。

| クレーム | 値 |
|---|---|
| `sub` | アナリストの一意識別子（uid）。以降の全てのToken Exchangeを通じて維持され、委任チェーン全体を追跡するキーになる |
| `preferred_username` | アナリストがログインに使った読める名前（例: `yamada-analyst`）。`sub`と異なりid_tokenのみに含まれ、画面表示等の人間可読な用途にのみ使う（[ADR 0034](adr/0034-frontend-display-username-instead-of-sub.md)） |
| `aud` | `frontend`（単一。[ADR 0005](adr/0005-single-audience-tokens-only.md)） |
| `iss` | Keycloakのrealm発行者 |
| scope | 最小限（`openid`程度）。`account:read`・`account:unfreeze`等のスコープはこの時点では一切持たない |

このトークンには、アナリストの担当地域・権限レベルは一切含まれない。これらはanalyst-attribute-serviceが保持する外部属性であり、必要になった都度、後続のToken Exchangeの先で照会される（表5）。クレームにするか業務データとして外部化するかの判断基準（役割・オーナーシップ・機密性の3軸）は[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)を参照。担当地域・権限レベルは3軸全てで「外部化すべき」側に該当する：これは実行時の個別業務判断（今このアナリストが何をできるか）のもとになるデータであり、正典は業務ドメイン（人事上の配属情報）であり、fraud-mcp-server等の中継者に見せる必要がないため。

このログイントークンをそのままaccount-service等の呼び出しに使う経路は存在しない。account-serviceへのアクセスが必要になった時点で、frontendが目的別に明示的なToken Exchangeを実行する（表1、§5）。ログイントークンをDPoP等で送信者拘束するかどうかは未決定（§11参照）。

### 表1: Audience間のToken Exchange可否（BR5・BR6に対応）

この表は「あるaudience宛てのトークンを、別のどのaudience宛てのトークンに交換できるか」を示す。行は交換前トークンの`aud`（元audience）、列は交換後に要求する`aud`（先audience）である。全てのトークンは常に単一のaudienceのみを持つ（[ADR 0005](adr/0005-single-audience-tokens-only.md)）ため、「元audience」は常に一意に定まる。fraud-detection-engineはToken Exchangeに参加しない（client_credentials）ため、この表には含めない（表4で別に扱う）。

**注意点（重要）**：

- Keycloakの実際の許可判定は「トークンのaudienceそのもの」ではなく、「Token Exchangeを要求しているクライアント自身の認証情報（client_id/secret）が、要求先audienceについて許可されているか」、かつ「提示された`subject_token`の`aud`に、その要求元クライアント自身が含まれているか」の2点で行われる。本システムでは各サービスの`audience名`と`Keycloakのクライアントid`を同一にしており、かつ各サービスは自分宛て（＝自分のクライアントidと一致するaudience）のトークンしか受け取らない設計にしているため、結果として「元audience」と「それを正当に提示できる唯一のクライアント」が1対1に対応する。だからこそ本表を「audience→audience」の単純な遷移表として記述できる。この前提（audience名＝client id、1トークン1保持者）が崩れる場合、この単純化は成立しなくなる
- 「実際に交換をリクエストしたプロセスが誰か」という素性は、この表のALLOW/DENY判定に一切現れない。判定に使われるのは「提示されたトークンのaudience」と「要求元として認証されたクライアント資格情報」だけである
- この表はあくまで「どのaudience間でToken Exchangeが許可されているか」という認可トポロジーを示すものであり、「そのトークンを提示しているプロセスが本当にその正当な保持者かどうか」は別の関心事である。ベアラートークンである以上、盗まれたトークン文字列は誰でも提示できてしまう。これを防ぐには送信者拘束（DPoP、RFC 9449等）のような別の仕組みが必要で、本表の許可トポロジー単体では保証されない（DPoPの適用範囲は未決定。§11参照）

| 元audience \ 先audience | account-service | fraud-agent | fraud-mcp-server | analyst-attribute-service |
|---|---|---|---|---|
| frontend | ALLOW | ALLOW | DENY | DENY |
| fraud-agent | DENY | — | ALLOW | DENY |
| fraud-mcp-server | ALLOW | DENY | — | DENY |
| account-service | DENY | DENY | DENY | ALLOW |
| analyst-attribute-service | DENY | DENY | DENY | DENY |

- ALLOWは4マスのみ。frontendの行に2つALLOWがあるのは、frontendが1つのログイントークン（`aud=frontend`）から、目的の異なる2つの単一audienceトークン（account-service向け・fraud-agent向け）をそれぞれ個別のToken Exchangeで取得するため（[ADR 0005](adr/0005-single-audience-tokens-only.md)）。1つのトークンが複数audienceを同時に持つわけではない
- 委任チェーンはfrontend→fraud-agent→fraud-mcp-server→account-serviceの4ホップになった（[ADR 0014](adr/0014-fraud-agent-token-exchange.md)）。各ホップは常に「自分宛て（`aud`が自分自身のクライアントidと一致する）」トークンだけを`subject_token`として次のToken Exchangeに使う。これにより「元audience」と「それを正当に提示できる唯一のクライアント」の1対1対応（上記注意点参照）が保たれる
- fraud-mcp-server→account-serviceの1マス以外、AIエージェント側の経路にはanalyst-attribute-serviceへの到達手段がない。ホップ飛ばし（例：fraud-agentやfraud-mcp-serverが直接account-service・analyst-attribute-serviceを呼ぶ）は構造上不可能（各クライアントへの`optionalClientScopes`の割当のみで実現。Client Policiesは使わない）
- frontend→fraud-agent、fraud-agent→fraud-mcp-serverいずれの交換で発行されるトークンも`account:read`のみを持ち、`account:unfreeze`は含まれない。これがAIエージェントに凍結解除の実行権限を渡さないための核心の仕組み（表2参照）

### 表2: account-serviceのスコープ別操作可否（BR5・BR6・BR9に対応）

条件は「トークンが保有するスコープ」と「操作種別」の2軸。パスパターンは、account-service自身のingress側rbacポリシーと、account-serviceを呼ぶ全ての呼び出し元のegress側scope解決（[ADR 0010](adr/0010-egress-listener-granularity.md)）の両方が参照する単一の情報源である。account-serviceの実装時にAPIの詳細（レスポンス形式・ページネーション等）を決める際も、このパスパターン自体は変えない（変える場合はここを直接書き換える）。

| 操作 | 必要スコープ | パスパターン（Envoyのroute解決用） |
|---|---|---|
| 取引履歴・凍結中口座の照会（read） | `account:read` | `GET /accounts/{id}/**`（get_frozen_accounts・get_account_history・ダッシュボード表示を含む、読み取り系は全てこの配下） |
| 凍結解除案の記録（propose） | `account:propose` | `POST /accounts/{id}/unfreeze-proposals` |
| 口座凍結の自動実行（freeze） | `account:freeze`（機械間認証。業務属性チェックなし。表4参照） | `POST /accounts/{id}/freeze` |
| 凍結解除提案の承認・却下（decide） | `account:unfreeze`（提案を依頼した本人アナリストのみ。BR9・[ADR 0036](adr/0036-unfreeze-proposal-approval-step.md)） | `POST /accounts/{id}/unfreeze-proposals/{proposalId}/approve`, `.../reject` |
| 口座凍結の解除の実行（unfreeze） | `account:unfreeze`（実行時にanalyst-attribute-serviceへの再照会あり。表5参照。提案経由の場合は承認済み・依頼者本人であることも検証） | `POST /accounts/{id}/unfreeze` |

#### どのトークンがどのスコープを保有するか

§4のクライアント別スコープ割当を前提に、実際に発生する交換パスごとにトークンが保有するスコープを列挙したものが以下の表である。

| トークン | 発行経路 | 保有スコープ |
|---|---|---|
| frontendが発行するトークン（account-service宛て、確定パス用） | frontendが`aud=frontend`のログイントークンを`subject_token`にToken Exchange | `account:read`, `account:unfreeze` |
| frontendが発行するトークン（fraud-agent宛て、提案生成パス用） | 同上、target audienceのみ異なる（[ADR 0014](adr/0014-fraud-agent-token-exchange.md)） | `account:read`のみ |
| fraud-agentが発行するトークン（fraud-mcp-server宛て） | fraud-agentが受け取った`aud=fraud-agent`のトークンを`subject_token`にToken Exchange（[ADR 0014](adr/0014-fraud-agent-token-exchange.md)） | `account:read`のみ |
| fraud-mcp-serverが発行するトークン（account-service宛て） | fraud-mcp-serverがToken Exchange | `account:read`, `account:propose` |
| fraud-detection-engineのclient_credentialsトークン | client_credentials（委任チェーン外） | `account:freeze`のみ |

fraud-agent・fraud-mcp-server（ひいてはAIエージェント）が`account:unfreeze`を持つ経路は存在しない。凍結解除の実行、および提案の承認・却下のいずれも、frontendが確定パス用に発行するトークンのみで到達可能であり、これはアナリストがUIで決定論的操作（承認/却下ボタン、「凍結解除を確定」ボタン）を行った場合にのみ発行・使用される。

#### scopeチェックの実施箇所（MUST）

この表のスコープチェックは、**Envoyサイドカーの受信側（アプリの外）で行うか、やむを得ずaccount-serviceのアプリ内で行う場合もリクエストの入口（ハンドラの先頭、表5のABAC判定より前）でのみ**行う。ビジネスロジックの途中や、表5のABAC判定の後にスコープチェックを行ってはならない。理由は[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)を参照。

### 表3: analyst-attribute-serviceの照会可否（BR4に対応）

account-service以外の経路（fraud-mcp-server等）がanalyst-attribute-serviceへ直接到達できないことを保証する表。これにより、表5のABAC判定は必ずaccount-serviceを経由した最新の属性照会に基づいて行われ、BR4（AIエージェントの閲覧範囲はアナリスト本人を超えない）の前提が成り立つ。

| 呼び出し元 | 照会可否 |
|---|---|
| account-service（`aud=account-service`のトークンを`subject_token`に交換、scope=`analyst:read`） | ALLOW |
| その他すべて | DENY |

### 表4: fraud-detection-engineのaccount-serviceアクセス（Token Exchange対象外、BR7に対応）

fraud-detection-engineはユーザー委任チェーンに参加しない機械間認証（client_credentials）のため、表1の委任トポロジーとは別枠で扱う。

| 認証方式 | スコープ | 業務属性チェック |
|---|---|---|
| client_credentials（fraud-detection-engineの自クライアント） | `account:freeze` | なし（スコープチェックのみ） |

### 表5: account-serviceの口座別アクセス可否（アナリスト経由、RBAC+ABAC、BR1・BR2・BR3に対応）

アナリスト経由のリクエスト（`account:read`/`account:propose`/`account:unfreeze`のいずれか）にのみ適用される。fraud-detection-engineの`account:freeze`には適用しない（表4、BR7）。

`sub`がアナリスト本人のまま委任チェーンを通じて維持されるため（表1）、この判定はfrontend直接・AIエージェント経由のどちらのリクエストであっても同じアナリスト本人の属性に対して行われる。これによりBR4（AIエージェントの閲覧範囲はアナリスト本人を超えない）が成り立つ。

条件は「アナリストの権限レベル」と「口座の地域一致・ティア」の2軸。

| 権限レベル \ 口座の地域・ティア | 担当地域一致・standard | 担当地域一致・high-value | 担当地域不一致 |
|---|---|---|---|
| senior | ALLOW | ALLOW | DENY |
| junior | ALLOW | DENY | DENY |
| 属性未登録 | DENY | DENY | DENY |

- 担当地域はアナリストごとに複数持てる（表6参照）
- 拒否の表現は操作種別で使い分ける（[ADR 0026](adr/0026-account-service-analyst-attribute-service-implementation.md)）：単一リソース読み取り（`GET /accounts/{id}/transactions`）は404（口座の存在自体を秘匿）、単一リソースへの操作（propose/unfreeze）は403（呼び出し元は既に口座の存在を知っている前提）、一覧（`GET /accounts/frozen`）は個別のDENYではなく**結果セットからの除外**（§10参照）
- juniorがhigh-value口座の凍結解除を試みた場合、AIエージェント経由（提案止まり）でも人間の確定操作でも、この表に従ってaccount-serviceが拒否する

### 表6: テストアナリスト

| アナリスト | 担当地域 | 権限レベル |
|---|---|---|
| yamada-analyst | 東京 | junior |
| suzuki-senior | 東京, 大阪 | senior |
| tanaka-junior | 大阪 | junior |

## 7. ローカル実行環境

**k3d**（[ADR 0003](adr/0003-k3d-without-istio.md)）。Istioは当面不採用、サイドカーは素のEnvoyを手動構成する。

- クラスタ定義は[k3d/cluster-config.yaml](../k3d/cluster-config.yaml)。単一サーバーノード、Traefik・servicelbは無効化（Ingressを使わないため。[ADR 0004](adr/0004-external-access-via-port-forward.md)）
- 外部公開はIngressではなく`kubectl port-forward`で行う（[ADR 0004](adr/0004-external-access-via-port-forward.md)）。edge-proxy相当のServiceに直接port-forwardし、`KC_HOSTNAME`はホストからブラウザで到達する固定URL（`http://localhost:3000`を想定）に固定する
- クラスタのup/down/stop/start/statusは`make`タスクで操作する（[Makefile](../Makefile)）
- 実行に必要なWSL2側の前提条件（cgroup v2化）とその対応経緯は[insights.md](insights.md)を参照
- Keycloakは`kc.sh build`済みイメージ（[services/keycloak/Dockerfile](../services/keycloak/Dockerfile)）を`start --optimized`で起動する。起動のたびにaugmentationをやり直す`start-dev`と比べ起動時間を約半分に短縮している（[ADR 0035](adr/0035-keycloak-optimized-build.md)）

## 8. データストア

各サービスは自分のデータの唯一の番人であり、他サービスは直接テーブル・コレクションを見ない（サービス境界をスコープ付きトークンで越えるという本プロジェクトの核心と矛盾するため）。ローカル環境はメモリ制約が既知（[insights.md](insights.md)）のため、エンジン自体は共有しつつサービスごとに論理DB・認証情報を分離する。詳細・選定理由は[ADR 0008](adr/0008-per-service-datastore-strategy.md)を参照。

| サービス | エンジン |
|---|---|
| account-service | PostgreSQL（専用データベース） |
| fraud-detection-engine | PostgreSQL（account-serviceと同一インスタンス内の別データベース） |
| analyst-attribute-service | PostgreSQL（同一インスタンス内の別データベース） |
| frontend | なし（ログインセッションは暗号化Cookieでステートレスに保持） |
| Keycloak（6サービス外・プラットフォーム基盤） | PostgreSQL（同一インスタンス内の別データベース） |

## 9. 監査

[requirements.md](requirements.md) BR8（事後追跡可能性）を満たすため、監査ログ集約基盤（Grafana Alloy + `grafana/otel-lgtm`、[ADR 0025](adr/0025-audit-log-aggregation.md)）でEnvoyアクセスログ・Keycloakイベントログを集約し、以下の相関キーで事後の再構成を可能にする。

- **`sessionId`**（Keycloakのログインセッションid）：委任チェーン1インスタンスの相関キー。同一のfrontendログインセッションに由来する全ホップのToken Exchangeイベントは同じ`sessionId`を持つ（実機確認済み。insights.md参照）。`sub`単体では同一アナリストの複数の並行操作（別タブでの別操作等）を区別できないため、これを主キーとする
- **`sub`/`userId`/`username`**：誰が。委任チェーン全体で元のアナリストのまま維持される（Impersonation方式）。client_credentialsグラント（fraud-detection-engineの自動凍結処理）には`sessionId`自体が存在せず、`sub`はその処理自身のサービスアカウントになる（BR7と整合）
- **`token_id`（jti）/`scope`/`audience`**：各ホップで何をしたか。ホップごとに新しいトークンが発行されるため、`jti`はホップごとに変わる

集約先はKeycloakのイベントログ（`eventsEnabled`、`TOKEN_EXCHANGE`/`LOGIN`等。`userId`/`username`/`sessionId`/`token_id`/`scope`/`audience`/`subject_token_client_id`を含む）を主軸とし、全ホップのEnvoyアクセスログ（`x-auth-sub`/`x-auth-scope`/`x-auth-jti`）を補助的に併用する。`proposal_id`（AIの提案と人間の確定を紐付けるための識別子）はaccount-serviceの本実装（[ADR 0026](adr/0026-account-service-analyst-attribute-service-implementation.md)）でDB永続化済み：`unfreeze_proposals.id`として発行され、`unfreeze_executions.proposal_id`（NULL可、AIの提案に基づかない実行を許すため）で突合する。提案の承認・却下（BR9、[ADR 0036](adr/0036-unfreeze-proposal-approval-step.md)）は`unfreeze_proposals.status`/`decided_by_sub`/`decided_at`に記録され、「誰が提案し・誰がいつ承認し・誰がいつ実行したか」の3点を事後に区別して追跡できる。

## 10. 実行時シナリオ（ユースケース）

上記§1〜§9が関心事ごとに分割して説明している各層（Token Exchange・スコープ・ABAC判定）を、具体的なリクエストフローとして正常系・異常系ともに1本の線で串刺しにし、実装が噛み合っていることを示す（`scripts/verify-hop.sh`の人間可読版）。異常系は「どのように拒否が観測されるか」も明記する。同じ「拒否」でも、リクエスト自体がエラーになる場合と、処理は完了しつつ結果セットが絞り込まれる場合があり、両者を区別する。

### 不正検知・口座凍結解除

#### UC0: 前提（fraud-detection-engineによる自動凍結）

登場人物：なし（機械間認証）

```
1. fraud-detection-engineが取引パターンを監視し、疑わしい取引パターンを検知する
2. fraud-detection-engineがclient_credentialsでトークンを取得（scope=account:freeze）
3. account-serviceへ当該口座の凍結を依頼する
4. account-service: scope=account:freezeを確認 → 許可。analyst-attribute-serviceへの照会は発生しない（表4）。凍結の判定根拠（発火した検知ルール等）を記録する
```

このパスはユーザー委任チェーンに一切参加しない、account-serviceの「通常のマイクロサービスから利用される」側面を示す。以降のUC1〜UC5は、この自動凍結が既に起きていることを前提にする。

#### UC1: 正常系（AIが標準口座の凍結解除を提案し、juniorアナリストが確定する）

登場人物：yamada-analyst（junior, 担当地域=東京）

```
1. yamada-analystがfrontendからログイン
2. frontendでAIエージェント（fraud-agent）とのチャットを開始
   → frontend: 自身のログイントークン（aud=frontend）を`subject_token`にToken Exchangeを実行（audience=fraud-agent, scope=account:read）し、そのトークンでfraud-agentのチャット開始APIを呼ぶ（[ADR 0014](adr/0014-fraud-agent-token-exchange.md)）
3. fraud-agent → fraud-mcp-server: 受け取ったトークン（aud=fraud-agent）を`subject_token`に自身のToken Exchangeを実行（audience=fraud-mcp-server, scope=account:read）した上で、MCPツール get_frozen_accounts を呼ぶ
4. fraud-mcp-server: Token Exchange（audience=account-service, scope=account:read）
5. account-service: Token Exchange（audience=analyst-attribute-service, scope=analyst:read）でyamada-analystの属性（東京, junior）を取得
6. account-service: 東京の standard 口座のうち凍結中のものを、凍結根拠とともに返す（表5）
7. fraud-agentが凍結理由・取引履歴を分析し「この口座は誤検知の疑いがあり、凍結を解除すべきです」と提案。fraud-mcp-serverのpropose_unfreezeツールで提案を記録（scope=account:propose、status=pending）
8. yamada-analystがチャット画面で提案内容・根拠を確認し、「承認」ボタンを押す
   → frontend: 自身のログイントークン（aud=frontend）を`subject_token`に別のToken Exchangeを実行（audience=account-service, scope=account:unfreeze）し、承認APIを呼ぶ
   → account-service: 再度analyst-attribute-serviceへ照会し（多層防御）ALLOW。かつ手順7の提案を依頼したのがyamada-analyst本人であることを確認した上で（BR9）、提案のstatusをapprovedに更新する
9. yamada-analystが（チャット画面またはダッシュボードで）「凍結解除を確定」ボタンを押す
   → frontend: 同様にToken Exchangeを実行し、そのトークンでaccount-serviceの凍結解除APIを呼ぶ（手順8で承認済みの提案IDを添えて）
10. account-service: 再度analyst-attribute-serviceへ照会し（多層防御）、東京・standard・junior → ALLOW。かつ提案のstatusがapproved・依頼者=実行者本人であることを確認した上で、凍結解除を実行し提案IDと紐付けて記録
```

却下の場合：手順8で「却下」ボタンを押すと、account-serviceは提案のstatusをrejectedに更新するのみで、手順9以降は発生しない。ダッシュボードは「AIによる精査を依頼」ボタンを再表示し、手順2からやり直せる。

AIが「解除の根拠なし」と結論した場合（[ADR 0039](adr/0039-unfreeze-recommendation-axis.md)）：手順7でfraud-agentはpropose_unfreezeの代わりにconclude_no_unfreezeツールを呼び、提案をrecommendation=keep_frozenで記録する（scope=account:propose、status=pendingは共通）。手順8のボタンは「承認/却下」ではなく「了解(凍結を維持)/納得できない(見直しを依頼)」になる（BR10。凍結解除の承認・却下と混同されないよう文言を分ける）。「了解」を押すとstatusがapprovedになり精査完了(凍結維持)で終了、手順9・10（凍結解除の実行）は発生しない。「納得できない」を押すとstatusがrejectedになり、却下の場合と同じくダッシュボードから精査をやり直せる。account-serviceの凍結解除実行API（手順9・10）は、紐付く提案のrecommendationがunfreeze以外の場合は多層防御として拒否する。

#### UC2: 正常系（AIがhigh-value口座の凍結解除を提案し、seniorアナリストが確定する）

登場人物：suzuki-senior（senior, 担当地域=東京・大阪）

UC1と同じ流れだが、手順6で大阪のhigh-value口座も結果に含まれる（表5、senior行は地域一致であればティア不問でALLOW）。

#### UC3: 異常系・権限不足（juniorアナリストにはhigh-value口座がAI経由でも見えない）

登場人物：yamada-analyst（junior, 担当地域=東京）が東京のhigh-value口座について尋ねる場合

```
1〜5. UC1と同様
6. account-service: 表5でjunior×high-value=DENY → 結果セットから当該口座を除外
7. fraud-agentはそもそもこの口座のデータを受け取っていないため、凍結解除提案自体が発生しない
```

**拒否の見え方**：HTTPエラーにはならない。AIエージェントに見えるデータの時点で既に絞り込まれているため、「AIが見落とした」のではなく「そもそも見せていない」という設計になる。

#### UC4: 異常系・地域不一致（担当地域外の口座はAI経由でも人間経由でも見えない）

登場人物：yamada-analyst（担当地域=東京）が大阪の口座について尋ねる、またはfrontendから直接大阪の口座を照会しようとする場合

```
- AI経由：UC3と同じ経路で、大阪の口座はaccount-serviceの結果セットから除外される
- frontend直接：account-serviceが同じく表5に基づき除外する（呼び出し経路が違うだけで、判定権威はaccount-service一箇所に集約されている）
```

#### UC5: 異常系・AIエージェントが凍結解除を直接実行しようとするケース（構造的に不可能）

```
1. 仮にfraud-agent（またはfraud-mcp-server）が凍結解除APIを直接呼ぼうとしても、
   手持ちのトークンは委任チェーン（frontend→fraud-agent→fraud-mcp-server、いずれもToken Exchangeで発行。[ADR 0014](adr/0014-fraud-agent-token-exchange.md)）上のどのトークンも scope=account:read のみであり、
   account:unfreezeスコープを含まない
2. account-serviceのスコープチェック（表2）でDENY
```

**拒否の見え方**：これはリクエスト時点のスコープ不足によるHTTPエラー（403相当）であり、UC3/UC4の「結果セットの絞り込み」とは異なる種類の拒否。そもそも`fraud-mcp-server`クライアントには`account:unfreeze`のoptional client scopeが割り当てられていない（§4、表2）ため、Token Exchangeの時点で`account:unfreeze`を要求しても`invalid_scope`等で拒否される（トークン自体がそもそも取得できないパターン）。

## 11. 既知の制約・未着手事項

未着手の改善項目・未決定事項のみを列挙する。着手したらその場で該当項目を削除し、結果を本書の該当章・[services.md](services.md)・[insights.md](insights.md)のいずれかへ記録する。未決事項の判断材料となる実機知見・調査結果が既に[insights.md](insights.md)やADRにある場合は、それを再掲せずポインタで済ませる。

### Token Exchange / Envoyサイドカー

- **合言葉ヘッダー名・env var名の確定**：1ホップ先行検証でヘッダー名`x-gekko-handshake`・env var名`HANDSHAKE_TOKEN_FILE`を採用し、Python実装のスタブ間で統一した（[k8s/account-service/app-configmap.yaml](../k8s/account-service/app-configmap.yaml)等）。Java/TypeScript/Rust/Go等、他言語での本実装時にも同じ命名を踏襲する
- **Unixドメインソケット化の再検討**：[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)でTCP loopback+合言葉方式を採用しUnixドメインソケット化は見送ったが、「同一Pod内でアプリが侵害された場合」まで守る要求が出てきたら再検討する
- **Token Exchange結果のキャッシュ**：`(subject jti, audience)`単位でのキャッシュを検討しているが、各サイドカー内に閉じるか、どの範囲で共有するかは未決定。キャッシュTTLは性能とのトレードオフを意図的に選んだ短い値にする
- **交換後トークンのアクセストークン有効期間**：[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)は、トークン漏洩・誤用時の被害範囲を抑える多層防御として交換後トークンの有効期間を短く設定する方針を前提にしている。ログイントークンとは別に、各クライアント（frontend/fraud-mcp-server/account-service）が交換で得るトークンのAccess Token Lifespanを具体的に何秒にするかは未決定
- **`account:read`スコープのaudience監査ギャップ**：`account:read`は複数audience（account-service・fraud-agent・fraud-mcp-server）向けの`oidc-audience-mapper`を1つのclient scopeで共有しているため、Keycloak側は要求元クライアントが`account:read`を持ってさえいれば任意のaudienceを要求できてしまう（表1のDENYはKeycloakのクライアント設定ではなく、各クライアントの実装＝token-exchangeサイドカーが正しいaudienceしか要求しないことに依存している）。Client Policiesを使わない設計（§4）の下ではこの自制に頼るしかなく、現状は全クライアントの実装が正しいaudienceしか要求しないためリスクは顕在化していないが、監査要件が強まった場合はClient Policies導入を再検討する（[ADR 0024](adr/0024-frontend-edge-proxy-and-simplified-login.md) Consequences、[insights.md](insights.md)参照）

### DPoP

適用範囲は未定。[ADR 0013](adr/0013-dpop-sender-constraining.md)でfraud-mcp-server→account-serviceの1ホップに実装・実機検証したが、[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)で撤去した（このホップは既にSPIRE mTLSで身元を限定済みのため実利の重複が大きく、投資に見合わないと判断）。再検討する場合の判断材料（「拘束のスロットは委任チェーンに1箇所、終端ホップのみ」という制約、Keycloak issue #51205等）は[insights.md](insights.md)「DPoP送信者拘束」節に集約してある。frontendへの適用（pattern②、確定パスの直接exchange）は理論上は可能だが、[ADR 0024](adr/0024-frontend-edge-proxy-and-simplified-login.md)でのfrontend実装時もDPoPは有効化しなかった（SPIRE JWT-SVIDクライアント認証のみ採用）ため、依然として未検証。

### mTLS / SPIFFE / SPIRE

fraud-mcp-server・fraud-detection-engine・account-service・analyst-attribute-service・fraud-agent・frontend・edge-proxy・Keycloak間の全ホップ、常駐4サービス(keycloak/account-service/analyst-attribute-service/fraud-detection-engine)とPostgres間、および5つのdb-init/seed Job(1回限りの初期化Job。ネイティブsidecarコンテナでEnvoyを持つ)とPostgres間にSPIRE mTLSを導入済み（[ADR 0012](adr/0012-spiffe-spire-mtls-single-hop.md)/[0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)/[0017](adr/0017-edge-proxy-full-keycloak-mtls.md)/[0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)/[0020](adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)/[0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)/[0023](adr/0023-fraud-agent-fraud-mcp-server-hop.md)/[0024](adr/0024-frontend-edge-proxy-and-simplified-login.md)/[0028](adr/0028-postgres-mtls-tcp-proxy.md)）。Postgres本体の平文5432への直接到達経路は全て廃止された。全ホップへの横展開は完了し、残るのは以下の明示的スコープ外項目のみ。

- **NetworkPolicyのspire namespaceへの横展開**：[ADR 0018](adr/0018-network-policy-default-deny.md)で`gekko` namespaceにL3/4のdefault-denyを導入したが、`spire` namespace（spire-server/spire-agent）は対象外とした。spire-agentが`hostNetwork: true`で動作しており、kube-router netpolがhostNetwork Podに対してどう振る舞うかが未検証なため。加えて`spire-entries` Job（`kubectl exec`でspire-serverへ接続する）等、`gekko` namespaceとは異なる接続パターンを持つ点も要考慮
- **ワークロードPod（account-service/fraud-mcp-server等）自体への`hostPID`/`hostNetwork`付与**：SPIRE agentには必要だが、ワークロードPod側はカーネルのPID名前空間の性質上不要なはずという推測のもとで見送った。属性解決が実機で失敗した場合（SDS呼び出しがタイムアウトする、spire-serverのログに"no selectors found after max poll attempts"が出る等）のみ再検討する
- **`spiffe-csi`ドライバ・`spire-controller-manager`**：新規可動部を増やさないため、hostPathでのソケット共有・`spire-server entry create` CLIでの手動登録を選んだ。本番相当の運用を検証したくなった場合に再評価する

### 属性・アクセス制御の粒度

- **口座属性の拡張要否**：現状は地域(`region`)とティア(`standard`/`high-value`)の2軸のみ（表5）。実装を進める中でさらに軸が必要になるか要検討

### fraud-detection-engine

- **実際の取引イベントストリームとの連携**：[ADR 0027](adr/0027-fraud-detection-engine-implementation.md)で本実装した監視ループは、上流の取引イベント基盤が存在しないため観測シグナル（口座ID・発火ルール・スコア・理由）を起動時の固定シードで代用している。実際の取引ストリームと連携したくなった場合、BR7（fraud-detection-engineはaccount:readを持たない。表4）とどう両立させるか（account-serviceからの何らかのイベント供給の形を取るのか等）を含めて再検討が必要
- **スキャン間隔のチューニング**：既定5秒はデモの応答性優先の値であり実運用相当ではない。実運用を想定した値・可変間隔（負荷に応じた調整等）が必要になった場合に見直す

### fraud-agent

- **Anthropic API向けNetworkPolicyのIPレンジ絞り込み**：[ADR 0030](adr/0030-fraud-agent-implementation.md)で導入した`ipBlock 0.0.0.0/0`（RFC1918除外）は、Anthropicの実IPを固定できないための暫定措置。将来Anthropicが固定IPレンジを公開する、またはegress-filteringプロキシ（例：Envoyの`sni_dynamic_forward_proxy`をFQDN許可リストと組み合わせる等）を追加で検討したくなった場合に絞り込む
- **複数ターン会話の永続化**：現状はリクエストごとに新しい`ClaudeAgentAdapter`インスタンスを作って単発実行しており、会話履歴は保持しない（AG-UIの`threadId`は受け取るが、同じ`threadId`でも毎回新規セッション。複数ターンをまたぐ会話が必要になった場合、アダプタのセッション管理機能や永続化ストアの追加を検討する）
- **AG-UIの状態同期・frontend tool機能の活用**：`@ag-ui/claude-agent-sdk`アダプタは`STATE_SNAPSHOT`/`STATE_DELTA`によるフロントエンドとの双方向状態同期や、クライアント提供ツール（human-in-the-loop）もサポートするが、今回は使っていない（`RunAgentInput.tools`/`state`を渡していない）。frontend本実装（[ADR 0031](adr/0031-frontend-implementation.md)）でも`pages/chat.vue`は最小限の手書きSSEパーサに留めており未活用のまま。AG-UI準拠のUIを本格的に作る際に活用を検討する

### frontend

- **セッション暗号鍵の複数レプリカ対応**：[ADR 0031](adr/0031-frontend-implementation.md)でCookie暗号化鍵をPod起動時にプロセス内生成する方式にしたため、`replicas`を2以上にすると別レプリカが処理したリクエストの`gekko_session`を復号できない（無効セッション扱いになり`/login`へ302される）。複数レプリカ化する場合はKubernetes Secret等での鍵共有を検討する
- **より長いが上限付き（絶対タイムアウト）のセッション**：[ADR 0031](adr/0031-frontend-implementation.md)はリフレッシュトークンを一切使わず、セッションをKeycloakのAccess Token Lifespan（既定5分）で必ず失効させる設計にした。5分ごとの再ログインが実用上不便になった場合、リフレッシュトークンを使いつつ絶対タイムアウト（ログイン時刻からの上限）を別途設ける設計を再検討する
- **Cookieの`secure`属性**：[ADR 0031](adr/0031-frontend-implementation.md)はローカルk3d port-forwardがhttpのため`gekko_session`・`gekko_pkce`両Cookieとも`secure: false`固定にしている。本番相当のHTTPS環境で動かす場合は`secure: true`に切り替える
- **AIの「根拠なし」結論に人間が納得できない場合の直接実行導線**：[ADR 0039](adr/0039-unfreeze-recommendation-axis.md)で「納得できない」を押した場合、現状は精査のやり直しに戻すのみで、BR8が許容する「提案に基づかない直接実行」経路（`proposalId`省略の凍結解除API）をUIから呼び出す導線は無い。人間がAIの「根拠なし」判断に明確に反対し独自に解除したいケースが実運用で必要になった場合、ダッシュボードに直接実行ボタンを追加するか検討する

### 監査

- **otel-lgtmの同梱コンポーネント（Prometheus/Tempo/Pyroscope/OTel Collector）を無効化できるか**：ADR 0025で採用した`grafana/otel-lgtm`はGrafana+Lokiのみ使う想定だが、残り4コンポーネントも起動している。個別に無効化できるかは未調査（動くが未使用として許容している）
- **`k8s/keycloak/test-fixtures-job.yaml`のパスワード設定の再現性問題**：realm再import直後にジョブを実行すると、作成直後のユーザーでログインが401になることがある（kcadmでset-passwordを打ち直すと直る）。原因未特定（[insights.md](insights.md)参照）

### データストア

- **本番相当環境でのインスタンス分離**：現状はローカルのメモリ制約を理由にaccount-service/fraud-detection-engine/analyst-attribute-service/KeycloakのPostgreSQLを共有インスタンスにしている（ADR 0008）。本番相当の構成を検証したくなった場合、サービスごとの専用インスタンスへの切り替えを検討する
- **既定メンテナンスDB（`postgres`）への接続が全ロールに残っている**：[k8s/keycloak/db-init-configmap.yaml](../k8s/keycloak/db-init-configmap.yaml)で`keycloak`データベースはPUBLICのCONNECT権限を剥奪したが、Postgresの既定メンテナンスデータベース自体は未対応。実データを持たないため実害はないが、完全な分離ではない

### Keycloak

- **`standard.token.exchange.enabled`属性の機能的検証**：1ホップ先行検証（frontend→fraud-mcp-server、fraud-mcp-server→account-service、account-service→analyst-attribute-service）でRFC 8693トークン交換リクエストが実際に通ることを確認済み（[insights.md](insights.md)・[ADR 0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)参照）。ただしaudience解決には対象audience向けの`oidc-audience-mapper`がclient scope側に必要という追加の前提が判明した（同insights.md）
- **標準client scope（profile/email/roles等）の要否**：`--import-realm`での直接importでは自動生成されないため現状未定義（詳細はrealm-configmap.yamlのコメント参照）。`preferred_username`は画面表示用に必要になったため[ADR 0034](adr/0034-frontend-display-username-instead-of-sub.md)でdedicated protocol mapperとして解決済み（`profile`スコープ自体は導入していない）。email/roles等、他の標準クレームが必要になった場合は改めてclientScopesへの追加を検討する

### インフラ

- **k3dクラスタの複数ノード化**：現状`servers: 1, agents: 0`（k3d/cluster-config.yaml）。スケジューリングの検証が必要になった場合はagentノードを追加するか検討
- **WSL2 cgroup v2化の恒久性**：`.wslconfig`の`kernelCommandLine = cgroup_no_v1=all`で対応済み（insights.md参照）だが、Windows Update等で設定が失われないかは未検証
