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

- 各サービスのPodはアプリコンテナ＋Envoyサイドカーの2コンテナ構成
- アプリは次ホップの呼び出し先を`localhost:<egressポート>`宛てに叩くだけで、Envoyの`ext_authz`（HTTPモード）フィルタが呼び出しを横取りし、ext_authzサービスがToken Exchangeを実行してから実際のアップストリームへ転送する
- 次ホップごとに専用のegressリスナーを1つずつ用意する（例：fraud-mcp-serverのサイドカーは「account-service宛て」専用リスナーを1つ持つ）。これによりext_authzサービスは「このリスナーに来た＝このaudienceへの交換」と静的に決め打ちでき、動的なaudience解決ロジックが不要になる
- `ext_authz`の応答ヘッダー許可リスト（`allowed_upstream_headers`）に`Authorization`を含める
- 実装順序：まず1ホップ（fraud-mcp-server→account-service）で先行検証し、パターンが固まってから残りのホップへ横展開する
- サイドカーの受信側（ingress）では、可能な限りscope検証（[access-control-design.md](access-control-design.md) 表2）もアプリの外で完結させる。業務データに依存する認可判定（表5等）はアプリ内に残さざるを得ない。scopeチェックの実施箇所に関するルールは[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)を参照

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

## 7. 監査

[access-control-requirements.md](access-control-requirements.md) BR8（事後追跡可能性）を満たすため、トークンの`jti`（発行識別子）と`audience`の組を突合キーとする方式に加え、AIの提案と人間の確定を紐付けるための`proposal_id`を導入する。

- account-serviceは提案の記録（propose）時に`proposal_id`を発行し、`sub`・`jti`・根拠データとともに記録する
- 凍結実行（freeze）時は、確定に使われた`proposal_id`（存在する場合）と、その時の`sub`・`jti`を記録する
- これにより「どの提案が、誰によって、どのトークンで確定されたか」を事後に再構成できる
- OpenTelemetryトレース・Keycloakイベントログとの統合方式は実装時に決定（backlog.md参照）

## 8. 既知の制約・未決定事項

[backlog.md](backlog.md)を参照。
