# アーキテクチャ設計

本ドキュメントは現在有効なアーキテクチャの断面のみを記録する。何を・なぜ実現するか（目的・背景・要求水準）は[requirements.md](requirements.md)、誰が何をできて何をできてはいけないかという業務要件は[access-control-requirements.md](access-control-requirements.md)、それをどう実現するかのディシジョンテーブル（認証トークンの内容を含む）は[access-control-design.md](access-control-design.md)、個々の設計判断の根拠・選択経緯は[docs/adr/](adr/)、具体的な業務シナリオは[use-cases.md](use-cases.md)、各サービスの存在意義は[services.md](services.md)を参照。決定が変わった場合は該当箇所を直接書き換え、対応するADRをSupersededに更新する。

## 1. 採用する認可サーバー

**Keycloak**を使用する（バージョン・realm設計の詳細は実装時に決定）。トークンのクレームに含めるデータと、業務サービス側に外部化して都度照会するデータの切り分けは、役割（委譲の天井か実行時の個別業務判断か）・オーナーシップ・機密性の3軸で判断する（[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)）。この基準の具体的な適用例は[access-control-design.md](access-control-design.md)の「認証」節を参照。

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

各サービスの存在意義・提供機能・保有データは[services.md](services.md)を参照。認証（ログイン時に発行されるトークンの内容）は[access-control-design.md](access-control-design.md)を参照。

## 3. Token Exchangeの実装方式

**各サービスのEnvoyサイドカーから呼ばれるext_authzサービスとして実装する**（[ADR 0002](adr/0002-token-exchange-in-envoy-sidecar.md)）。アプリケーション本体にはToken Exchangeのコードを一切持たせない。

- 各サービスのPodは**initContainer 1つ＋アプリコンテナ＋Envoyサイドカーの構成**（initContainerの役割は§3後半・[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)参照）
- アプリは相手サービスの**実サービス名・実APIパスをそのまま**使ってリクエストを組み立てる（例：`http://account-service/accounts/123/transactions`）。人工的なURLプレフィックスやegress専用ポートは使わない。Podの`hostAliases`で相手サービス名を`127.0.0.1`へ静的にマッピングし、Envoyサイドカーが1つのリスナー上の複数`virtual_hosts`（`domains`でサービス名をマッチ）で受け、`ext_authz`（HTTPモード）フィルタが横取りしてToken Exchangeを実行してから実際のアップストリームへ転送する（[ADR 0010](adr/0010-egress-listener-granularity.md)）
- **audienceはHostヘッダーから自動導出する**。Keycloakクライアントid＝Kubernetes Service名＝audience名を常に同一の文字列にする（MUST。[access-control-design.md](access-control-design.md)表1の既存の前提をKubernetes Service名にも拡張したもの）ため、ext_authzサービスはCheckRequestに**自動転送される**`Host`ヘッダー（後述）をそのまま`audience`として使え、リスナー・ルートごとの明示設定が不要になる
- **scopeは常に「相手サービスの(パス, メソッド) → scope」という単一の仕組みで決める**（[access-control-design.md](access-control-design.md) 表2に拡張済みの対応表。account-service自身のingress側rbacポリシーと共有する単一の情報源）。特別扱いするケースはない——scopeがpathによらず1つだけのホップ（fraud-detection-engine→account-service、account-service→analyst-attribute-service、frontend→fraud-agent、fraud-agent→fraud-mcp-server）は、この仕組みがワイルドカードルート1本に潰れているだけ。scopeがpathで変わるホップ（frontend→account-service、fraud-mcp-server→account-service。それぞれ`account:read`/`account:unfreeze`、`account:read`/`account:propose`）は複数ルートになる。パスパターンは表2に決まっているため、account-serviceの完全なAPI実装を待たずに全ホップのEnvoy route設計が今すぐ完成する。アプリのコードは常に実ホスト名・実パス・実メソッドで普通にAPIを呼ぶだけで、どちらのケースかを意識しない
  - この対応表は**ext_authzサービス自身がコードとして持つ**。HTTPモードのext_authzは`Host`・`Method`・`Path`・`Content-Length`・`Authorization`を常に自動転送するため（Envoyの標準動作。`ExtAuthzPerRoute`の`context_extensions`はgRPCモード限定で使わない。[ADR 0010](adr/0010-egress-listener-granularity.md)の訂正箇所参照）、Envoy側のroute設定はどのクラスタへ転送するかという宛先の振り分けだけを担う
- egressで必要な処理は2種類ある（ADR 0010、[ADR 0014](adr/0014-fraud-agent-token-exchange.md)で③④廃止）：①Token Exchange（大半のホップ、透過的プロキシ。frontend→fraud-agent・fraud-agent→fraud-mcp-serverもここに含まれる）②client_credentials発行（fraud-detection-engine→account-service、透過的プロキシ）
- `ext_authz`の応答ヘッダー許可リスト（①②とも`allowed_upstream_headers`に`Authorization`を含める）
- 実装順序：fraud-mcp-server→account-serviceの`account:read`/`account:propose`（パターン①）、fraud-detection-engine→account-serviceの`account:freeze`（パターン②、client_credentials）、account-service→analyst-attribute-serviceの`analyst:read`（表3）、fraud-agent→fraud-mcp-serverの`account:read`（[ADR 0023](adr/0023-fraud-agent-fraud-mcp-server-hop.md)）、frontend→account-serviceの`account:read`/`account:unfreeze`・frontend→fraud-agentの`account:read`（[ADR 0024](adr/0024-frontend-edge-proxy-and-simplified-login.md)）の全6ホップで先行検証**済み**（`k8s/account-service/`・`k8s/fraud-mcp-server/`・`k8s/fraud-detection-engine/`・`k8s/analyst-attribute-service/`・`k8s/fraud-agent/`・`k8s/frontend/`、`scripts/verify-hop.sh`。詳細は[insights.md](insights.md)）。frontendのログイン（Authorization Code+PKCE）自体は簡易ログイン（ROPCのHTTPエンドポイント化）で代用しており未実装（backlog.md参照）
- パターン①（fraud-mcp-server→account-service）・パターン②（fraud-detection-engine→account-service）・表3（account-service→analyst-attribute-service）とも、Token Exchange/client_credentials実行主体を共有の`ext-authz-service`(-cc)から各呼び出し元自身のPod内サイドカーへ移し（表3は最初からこの形で実装）、クライアント認証もclient_secretからSPIRE発行JWT-SVID（KeycloakネイティブのSPIFFE対応）へ変更した（[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)・[ADR 0020](adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)・[ADR 0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)）。これにより共有`ext-authz-service`インスタンス方式（`k8s/ext-authz/`）は全廃した
- Keycloak側で見落としやすい前提：Token Exchangeの`audience`パラメータが実際に解決されるには、要求元クライアントに割り当てたclient scope（`account:read`等）が、対象audienceを指す`oidc-audience-mapper`（protocol mapper）を持っている必要がある（[k8s/keycloak/realm-configmap.yaml](../k8s/keycloak/realm-configmap.yaml)）。`account:read`のように同名scopeが複数audience（account-service・fraud-agent・fraud-mcp-server）へ使われる場合は、そのscopeに全てのマッパーを持たせてよい——実際に発行されるトークンは、その時の`audience`パラメータで指定した1つだけに絞り込まれ、単一audience原則（[ADR 0005](adr/0005-single-audience-tokens-only.md)）は保たれる（実機で確認済み）

**サイドカーの受信側（ingress）の責務**（[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)）：

- JWT検証（`jwt_authn`フィルタ：署名・`iss`・`exp`・`aud`がこのサービス自身であること）とscope検証（`rbac`フィルタ：[access-control-design.md](access-control-design.md) 表2）はEnvoy側で完結させる。表5等の業務データに依存する認可判定自体はアプリ内に残さざるを得ない（理由は[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)参照）
- 検証済みの身元はヘッダー（`x-auth-sub`等）でアプリへ転送し、アプリは自前のJWTライブラリを持たない。`jwt_authn`の`claim_to_headers`設定でクレームからヘッダーへ直接変換できる（実機確認済み。[k8s/account-service/envoy-configmap.yaml](../k8s/account-service/envoy-configmap.yaml)）ため、別フィルタでのクレーム転記は不要
- **Envoyを経由しない直接アクセスのバイパス防止**（3層。詳細はADR 0009）：①アプリは`127.0.0.1`にのみbindし、Serviceはアプリのポートではなく Envoyのリスナーを指す（構造的な防止）②アプリ自身も接続元がloopbackでなければ拒否する（多層防御）③initContainerがPod起動時に生成しemptyDirで共有する使い捨ての合言葉を、jwt_authn/rbacを通過した後にのみEnvoyがヘッダーへ付与し、アプリはこれを検証してから他の認証ヘッダーを信用する（Envoyの設定ミスや誤操作によるバイパスの検知）。付与方式はADR 0009が候補に挙げた`envoy.filters.http.lua`を採用し、rbacより後段に置くことでフィルタ順序による保証を実現した（実機確認済み）
- 上記②③の検証ロジックはk8s環境外でもテスト可能にする。ただし「テスト時は検証をスキップする」条件分岐は作らない（[CWE-489](https://cwe.mitre.org/data/definitions/489.html)）。検証ロジックは環境によらず単一とし、期待値の読み出し元（ファイルパス等）のみ環境変数で設定可能にする

**mTLS（ワークロードID）**（[ADR 0012](adr/0012-spiffe-spire-mtls-single-hop.md)・[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)）：上記のOAuth Token Exchangeは「誰が何をしてよいか」という業務認可層であり、「誰と話しているか」という通信路の身元検証・暗号化とは独立の関心事である。account-serviceへの呼び出し元(fraud-mcp-server・fraud-detection-engine)は全て、SPIFFE/SPIREが発行するX.509-SVIDによるmTLS＋ALPNネゴシエーションのHTTP/2で接続する（`k8s/spire/`）。SPIRE agentのWorkload API（UDS）をEnvoyのSDSフィルタが参照し、証明書のプロビジョニング・ローテーションはSPIREが自動で行うため、Envoy bootstrap設定・アプリ本体のどちらにも証明書のライフサイクル管理コードは一切現れない。account-serviceのingressリスナーは単一のmTLS必須filter_chainのみで構成されており、plaintextでの到達経路は存在しない（ADR 0012が残していた既知の限界はADR 0015で解消済み）。account-service→analyst-attribute-service（表3）へは[ADR 0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)で、fraud-agent→fraud-mcp-serverへは[ADR 0023](adr/0023-fraud-agent-fraud-mcp-server-hop.md)で、frontend→account-service・frontend→fraud-agentへは[ADR 0024](adr/0024-frontend-edge-proxy-and-simplified-login.md)で導入済み。全ホップへのSPIRE mTLS横展開が完了した。共有`ext-authz-service`(-cc)自体の身元検証ギャップ（mTLS/JWT-SVIDの身元とKeycloakへ主張するclient_idの不一致）は、fraud-mcp-server向け（[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)）・fraud-detection-engine向け（[ADR 0020](adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)）・account-service向け（[ADR 0021](adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)）のいずれも解消済みで、共有ext-authz-serviceインスタンス方式は全廃した。

トークン送信者拘束（DPoP、RFC 9449）は[ADR 0013](adr/0013-dpop-sender-constraining.md)で一度導入したが、このホップは既にmTLSで呼び出し元の身元を限定済みのため実利の重複が大きく、[ADR 0015](adr/0015-dpop-removal-and-fraud-detection-engine-mtls.md)で撤去した。実機検証で得た知見（Token Exchangeを跨いだDPoP拘束は「拘束のスロットが委任チェーンに1箇所、終端ホップのみ」という制約を持つ）はbacklog.mdに残してある。

**NetworkPolicy（L3/4のdefault-deny）**（[ADR 0018](adr/0018-network-policy-default-deny.md)）：上記2層（業務認可・mTLS）とは独立な3層目として、`gekko` namespace全体にingress/egress双方向のdefault-denyを導入し、実装済みの接続経路のみを明示的に許可する。mTLSの適用対象外だった共有Postgresインスタンス（7節参照）は、この層で初めてL3/4の到達制限がかかった。`spire` namespace（hostNetworkで動くspire-agent等）は本ADRの対象外で、backlog.mdに残してある。Keycloakのkubelet向けhttp-mgmt:9000は当初「kubeletのノードIPからのみ許可」というNetworkPolicyの許可リストで到達範囲を絞っていたが、[ADR 0022](adr/0022-keycloak-mgmt-probe-exec.md)でProbeをexec化し`KC_HTTP_MANAGEMENT_HOST=127.0.0.1`にしたことで、そもそも誰からもネットワーク経由で到達不能になり、この層での許可ルール自体が不要になった。

## 4. Keycloakのクライアント・スコープ設計

**クライアント**

| クライアント | 種別 | 備考 |
|---|---|---|
| `frontend` | confidential, standard token exchange有効 | アナリスト向けBFF |
| `fraud-agent` | confidential, standard token exchange有効 | AIエージェント本体。frontendから受け取ったトークンを自身でfraud-mcp-server宛てに再exchangeする（[ADR 0014](adr/0014-fraud-agent-token-exchange.md)） |
| `fraud-mcp-server` | confidential | AIエージェントの代理としてaccount-serviceを呼ぶ |
| `fraud-detection-engine` | confidential, client_credentials | 機械間認証。ユーザー委任なし |
| `account-service` | confidential | analyst-attribute-serviceへの委任元 |

全てのトークンは常に単一のaudienceのみを持つ（[ADR 0005](adr/0005-single-audience-tokens-only.md)）。ログイントークンは`aud=frontend`（単一。内容は[access-control-design.md](access-control-design.md)参照）のみで、`account:read`等のスコープは持たない。frontendがaccount-serviceにアクセスする際（直接・委任いずれも）は、都度明示的なToken Exchangeで単一audienceのトークンを取得する（§5参照）。

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

`account:unfreeze`は`fraud-mcp-server`にも`fraud-agent`にも一切付与しない。AIエージェントがどれだけ「解除すべき」と提案しても、Keycloakのスコープ設計上そもそも凍結解除APIを呼べるトークンを取得できない、という形で認可レイヤーで強制する（[access-control-design.md](access-control-design.md) 表1・表2）。

## 5. トークンチェーン

ログイントークン（`aud=frontend`、単一audience、それ以上のスコープを持たない。詳細は[access-control-design.md](access-control-design.md)参照）を起点に、目的ごとに異なる単一audienceトークンを都度Token Exchangeで取得する（[ADR 0005](adr/0005-single-audience-tokens-only.md)）。frontendが「ログイントークンをそのまま使う近道」は存在しない。

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

## 6. ローカル実行環境

**k3d**（[ADR 0003](adr/0003-k3d-without-istio.md)）。Istioは当面不採用、サイドカーは素のEnvoyを手動構成する。

- クラスタ定義は[k3d/cluster-config.yaml](../k3d/cluster-config.yaml)。単一サーバーノード、Traefik・servicelbは無効化（Ingressを使わないため。[ADR 0004](adr/0004-external-access-via-port-forward.md)）
- 外部公開はIngressではなく`kubectl port-forward`で行う（[ADR 0004](adr/0004-external-access-via-port-forward.md)）。edge-proxy相当のServiceに直接port-forwardし、`KC_HOSTNAME`はホストからブラウザで到達する固定URL（`http://localhost:3000`を想定）に固定する
- クラスタのup/down/stop/start/statusは`make`タスクで操作する（[Makefile](../Makefile)）
- 実行に必要なWSL2側の前提条件（cgroup v2化）とその対応経緯は[insights.md](insights.md)を参照

## 7. データストア

各サービスは自分のデータの唯一の番人であり、他サービスは直接テーブル・コレクションを見ない（サービス境界をスコープ付きトークンで越えるという本プロジェクトの核心と矛盾するため）。ローカル環境はメモリ制約が既知（[insights.md](insights.md)）のため、エンジン自体は共有しつつサービスごとに論理DB・認証情報を分離する。詳細・選定理由は[ADR 0008](adr/0008-per-service-datastore-strategy.md)を参照。

| サービス | エンジン |
|---|---|
| account-service | PostgreSQL（専用データベース） |
| fraud-detection-engine | PostgreSQL（account-serviceと同一インスタンス内の別データベース） |
| analyst-attribute-service | PostgreSQL（同一インスタンス内の別データベース） |
| frontend | なし（ログインセッションは暗号化Cookieでステートレスに保持） |
| Keycloak（6サービス外・プラットフォーム基盤） | PostgreSQL（同一インスタンス内の別データベース） |

## 8. 監査

[access-control-requirements.md](access-control-requirements.md) BR8（事後追跡可能性）を満たすため、トークンの`jti`（発行識別子）と`audience`の組を突合キーとする方式に加え、AIの提案と人間の確定を紐付けるための`proposal_id`を導入する。

- account-serviceは提案の記録（propose）時に`proposal_id`を発行し、`sub`・`jti`・根拠データとともに記録する
- 凍結解除の実行（unfreeze）時は、確定に使われた`proposal_id`（存在する場合）と、その時の`sub`・`jti`を記録する
- これにより「どの提案が、誰によって、どのトークンで確定されたか」を事後に再構成できる
- OpenTelemetryトレース・Keycloakイベントログとの統合方式は実装時に決定（backlog.md参照）

## 9. 既知の制約・未決定事項

[backlog.md](backlog.md)を参照。
