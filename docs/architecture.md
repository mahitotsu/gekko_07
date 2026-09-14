# アーキテクチャ設計

本ドキュメントは現在有効なアーキテクチャの断面のみを記録する。何を・なぜ実現するか（目的・背景・要求水準）は[requirements.md](requirements.md)、誰が何をできて何をできてはいけないかという業務要件は[access-control-requirements.md](access-control-requirements.md)、それをどう実現するかのディシジョンテーブル（認証トークンの内容を含む）は[access-control-design.md](access-control-design.md)、個々の設計判断の根拠・選択経緯は[docs/adr/](adr/)、具体的な業務シナリオは[use-cases.md](use-cases.md)、各サービスの存在意義は[services.md](services.md)を参照。決定が変わった場合は該当箇所を直接書き換え、対応するADRをSupersededに更新する。

## 1. 採用する認可サーバー

**Keycloak**を使用する（バージョン・realm設計の詳細は実装時に決定）。トークンのクレームに含めるデータと、業務サービス側に外部化して都度照会するデータの切り分けは、役割（委譲の天井か実行時の個別業務判断か）・オーナーシップ・機密性の3軸で判断する（[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)）。この基準の具体的な適用例は[access-control-design.md](access-control-design.md)の「認証」節を参照。

## 2. シナリオとサービス構成

金融の不正検知・口座凍結（[ADR 0001](adr/0001-scenario-fraud-detection-with-agent-assist.md)）。

```
[アナリスト] --ログイン--> [frontend]
                              │
              ┌───────────────┼────────────────────┐
              │ (提案生成パス)                        │ (確定パス)
              ▼                                     ▼
      [fraud-agent] --MCP--> [fraud-mcp-server] --> [account-service] <-- [payment-service]
                                                          │
                                                          ▼
                                              [analyst-attribute-service]
```

各サービスの存在意義・提供機能・保有データは[services.md](services.md)を参照。認証（ログイン時に発行されるトークンの内容）は[access-control-design.md](access-control-design.md)を参照。

## 3. Token Exchangeの実装方式

**各サービスのEnvoyサイドカーから呼ばれるext_authzサービスとして実装する**（[ADR 0002](adr/0002-token-exchange-in-envoy-sidecar.md)）。アプリケーション本体にはToken Exchangeのコードを一切持たせない。

- 各サービスのPodは**initContainer 1つ＋アプリコンテナ＋Envoyサイドカーの構成**（initContainerの役割は§3後半・[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)参照）
- アプリは相手サービスの**実サービス名・実APIパスをそのまま**使ってリクエストを組み立てる（例：`http://account-service/accounts/123/transactions`）。人工的なURLプレフィックスやegress専用ポートは使わない。Podの`hostAliases`で相手サービス名を`127.0.0.1`へ静的にマッピングし、Envoyサイドカーが1つのリスナー上の複数`virtual_hosts`（`domains`でサービス名をマッチ）で受け、`ext_authz`（HTTPモード）フィルタが横取りしてToken Exchangeを実行してから実際のアップストリームへ転送する（[ADR 0010](adr/0010-egress-listener-granularity.md)）
- **audienceはHostヘッダーから自動導出する**。Keycloakクライアントid＝Kubernetes Service名＝audience名を常に同一の文字列にする（MUST。[access-control-design.md](access-control-design.md)表1の既存の前提をKubernetes Service名にも拡張したもの）ため、ext_authzサービスはCheckRequestの`Host`をそのまま`audience`として使え、リスナー・ルートごとの明示設定が不要になる
- **scopeは常に「相手サービスの(パス, メソッド) → scope」という単一の仕組みで決める**（[access-control-design.md](access-control-design.md) 表2に拡張済みの対応表。account-service自身のingress側rbacポリシーと共有する単一の情報源）。特別扱いするケースはない——scopeがpathによらず1つだけのホップ（payment-service→account-service、account-service→analyst-attribute-service、frontend→fraud-mcp-server）は、この仕組みがワイルドカードルート1本に潰れているだけ。scopeがpathで変わるホップ（frontend→account-service、fraud-mcp-server→account-service。それぞれ`account:read`/`account:freeze`、`account:read`/`account:propose`）は複数ルートになる。パスパターンは表2に決まっているため、account-serviceの完全なAPI実装を待たずに全ホップのEnvoy route設計が今すぐ完成する。アプリのコードは常に実ホスト名・実パス・実メソッドで普通にAPIを呼ぶだけで、どちらのケースかを意識しない
- egressで必要な処理は4種類ある（ADR 0010）：①Token Exchange（大半のホップ、透過的プロキシ）②client_credentials発行（payment-service→account-service、透過的プロキシ）③素通し（fraud-agent→fraud-mcp-server、ext_authzを呼ばない単純プロキシ）④トークンを値として取得（frontend→fraud-mcp-server。①と同じext_authz呼び出しだが実サービスは呼ばない合成的な呼び出しで、この1ケースのみ人工的な専用パス`http://fraud-mcp-server/_mint-token`を使う。ルートを`direct_response`にし交換後トークンを`allowed_client_headers_on_success`で呼び出し元自身への応答として返す）
- `ext_authz`の応答ヘッダー許可リスト（①②：`allowed_upstream_headers`に`Authorization`を含める。④：`allowed_client_headers_on_success`に交換後トークンを返すヘッダー名を含める）
- 実装順序：まず1ホップ分＝fraud-mcp-server→account-serviceの`account:read`/`account:propose`（いずれもパターン①）で先行検証し、パターンが固まってから残りのホップ・他の3パターンへ横展開する

**サイドカーの受信側（ingress）の責務**（[ADR 0009](adr/0009-envoy-ingress-responsibility-and-bypass-prevention.md)）：

- JWT検証（`jwt_authn`フィルタ：署名・`iss`・`exp`・`aud`がこのサービス自身であること）とscope検証（`rbac`フィルタ：[access-control-design.md](access-control-design.md) 表2）はEnvoy側で完結させる。表5等の業務データに依存する認可判定自体はアプリ内に残さざるを得ない（理由は[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)参照）
- 検証済みの身元はヘッダー（`x-auth-sub`等）でアプリへ転送し、アプリは自前のJWTライブラリを持たない
- **Envoyを経由しない直接アクセスのバイパス防止**（3層。詳細はADR 0009）：①アプリは`127.0.0.1`にのみbindし、Serviceはアプリのポートではなく Envoyのリスナーを指す（構造的な防止）②アプリ自身も接続元がloopbackでなければ拒否する（多層防御）③initContainerがPod起動時に生成しemptyDirで共有する使い捨ての合言葉を、jwt_authn/rbacを通過した後にのみEnvoyがヘッダーへ付与し、アプリはこれを検証してから他の認証ヘッダーを信用する（Envoyの設定ミスや誤操作によるバイパスの検知）
- 上記②③の検証ロジックはk8s環境外でもテスト可能にする。ただし「テスト時は検証をスキップする」条件分岐は作らない（[CWE-489](https://cwe.mitre.org/data/definitions/489.html)）。検証ロジックは環境によらず単一とし、期待値の読み出し元（ファイルパス等）のみ環境変数で設定可能にする

## 4. Keycloakのクライアント・スコープ設計

**クライアント**

| クライアント | 種別 | 備考 |
|---|---|---|
| `frontend` | confidential, standard token exchange有効 | アナリスト向けBFF |
| `fraud-mcp-server` | confidential | AIエージェントの代理としてaccount-serviceを呼ぶ |
| `payment-service` | confidential, client_credentials | 機械間認証。ユーザー委任なし |
| `account-service` | confidential | analyst-attribute-serviceへの委任元 |

全てのトークンは常に単一のaudienceのみを持つ（[ADR 0005](adr/0005-single-audience-tokens-only.md)）。ログイントークンは`aud=frontend`（単一。内容は[access-control-design.md](access-control-design.md)参照）のみで、`account:read`等のスコープは持たない。frontendがaccount-serviceにアクセスする際（直接・委任いずれも）は、都度明示的なToken Exchangeで単一audienceのトークンを取得する（§5参照）。

**スコープとトポロジー制御**（各クライアントに付与するoptional client scopeのみで委任トポロジーを制御する。Client Policiesは使わない）

| スコープ | 対象audience | 付与するクライアント | 意味 |
|---|---|---|---|
| `account:read` | account-service | frontend, fraud-mcp-server | 取引・口座の読み取り |
| `account:propose` | account-service | fraud-mcp-server のみ | 凍結案の記録（可逆・低リスク） |
| `account:freeze` | account-service | **frontend のみ** | 口座凍結の実行（不可逆・高リスク） |
| `account:transact` | account-service | payment-service のみ | 通常の入出金・振込処理 |
| `analyst:read` | analyst-attribute-service | account-service のみ | アナリストの担当地域・権限レベル照会 |

`account:freeze`は`fraud-mcp-server`にも`fraud-agent`にも一切付与しない。AIエージェントがどれだけ「凍結すべき」と提案しても、Keycloakのスコープ設計上そもそも凍結APIを呼べるトークンを取得できない、という形で認可レイヤーで強制する（[access-control-design.md](access-control-design.md) 表1・表2）。

## 5. トークンチェーン

ログイントークン（`aud=frontend`、単一audience、それ以上のスコープを持たない。詳細は[access-control-design.md](access-control-design.md)参照）を起点に、目的ごとに異なる単一audienceトークンを都度Token Exchangeで取得する（[ADR 0005](adr/0005-single-audience-tokens-only.md)）。frontendが「ログイントークンをそのまま使う近道」は存在しない。

**① 提案生成パス（AI起因、読み取り＋提案のみ）**
```
analystトークン(aud=frontend)
  → Token Exchange (frontend実行, audience=fraud-mcp-server, scope=account:read)
  → Token Exchange (fraud-mcp-server実行, audience=account-service, scope=account:read/account:propose)
  → account-serviceがToken Exchange (audience=analyst-attribute-service, scope=analyst:read) でアクセス制御
```

**② 確定パス（人間起因、決定論的操作）**
```
analystトークン(aud=frontend)
  → Token Exchange (frontend実行, audience=account-service, scope=account:freeze)
  → account-serviceが同じくanalyst-attribute-serviceへ照会（提案生成パスと同じ判定ロジック）
  → 凍結実行。①で記録された提案IDと紐付けて記録
```

**③ 通常決済パス（機械間、業務属性チェック対象外）**
```
payment-serviceの client_credentials トークン(scope=account:transact)
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
| payment-service | PostgreSQL（account-serviceと同一インスタンス内の別データベース） |
| analyst-attribute-service | PostgreSQL（同一インスタンス内の別データベース） |
| frontend | なし（ログインセッションは暗号化Cookieでステートレスに保持） |
| Keycloak（6サービス外・プラットフォーム基盤） | PostgreSQL（同一インスタンス内の別データベース） |

## 8. 監査

[access-control-requirements.md](access-control-requirements.md) BR8（事後追跡可能性）を満たすため、トークンの`jti`（発行識別子）と`audience`の組を突合キーとする方式に加え、AIの提案と人間の確定を紐付けるための`proposal_id`を導入する。

- account-serviceは提案の記録（propose）時に`proposal_id`を発行し、`sub`・`jti`・根拠データとともに記録する
- 凍結実行（freeze）時は、確定に使われた`proposal_id`（存在する場合）と、その時の`sub`・`jti`を記録する
- これにより「どの提案が、誰によって、どのトークンで確定されたか」を事後に再構成できる
- OpenTelemetryトレース・Keycloakイベントログとの統合方式は実装時に決定（backlog.md参照）

## 9. 既知の制約・未決定事項

[backlog.md](backlog.md)を参照。
