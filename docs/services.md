# サービス仕様

各サービスの存在意義・提供機能・保有データを定義する。認可の詳細は[access-control-design.md](access-control-design.md)、トークンチェーンの実装方式は[architecture.md](architecture.md)を参照。

各サービスの技術スタックは意図的に統一しない（多言語構成の理由は[requirements.md](requirements.md)「背景（なぜサイドカーへ切り出すか）」参照：Token Exchangeをサイドカーへ切り出す価値は、実装言語がバラバラな構成でこそ際立つ）。個々の選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)を参照。

以下のサービス本実装はいずれも未着手（設計段階）。ただしaccount-service・fraud-mcp-server・fraud-detection-engineは、Envoy/ext_authzによるToken Exchange・SPIFFE/SPIRE mTLSの実機検証用スタブとして存在する（本実装とは別物。詳細は[architecture.md](architecture.md)・[insights.md](insights.md)参照）。

## frontend（BFF）

- **存在意義**：アナリストがシステムに触れる唯一の入口。ログイン・チャットUI・取引ダッシュボード・凍結解除確定ボタンを提供する
- **提供機能**：
  - ログイン（Authorization Code + PKCE）。発行される直後のトークンは`aud=frontend`のみ（スコープなし。[ADR 0005](adr/0005-single-audience-tokens-only.md)）
  - 取引ダッシュボード：ログイントークンを`subject_token`にToken Exchange（audience=account-service, scope=account:read）を行い、そのトークンでaccount-serviceにアクセスする
  - 「凍結解除を確定」ボタン：同様にToken Exchange（audience=account-service, scope=account:unfreeze）を行い、そのトークンでaccount-serviceにアクセスする。決定論的操作の起点
  - チャットUI：AIエージェント（fraud-agent）とのやり取り。開始時にログイントークンを`subject_token`に別のToken Exchange（audience=fraud-agent, scope=account:read）を行い、そのトークンでfraud-agentのチャット開始APIを呼ぶ（他の全ホップと同じ、実サービスへの透過的呼び出し。[ADR 0014](adr/0014-fraud-agent-token-exchange.md)）
- **保有データ**：ログインセッション（アナリストのログイントークン）。サーバー側データストアは持たず、暗号化・署名付きCookieでステートレスに保持する（[ADR 0008](adr/0008-per-service-datastore-strategy.md)）
- **連携相手**：Keycloak（認証、用途ごとのToken Exchangeの実行）、account-service（交換後のトークンで）、fraud-agent（Token Exchangeで得たトークンによる実呼び出し）
- **技術スタック**：TypeScript / Nuxt.js（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）

## fraud-agent（AIエージェント）

- **存在意義**：凍結済み口座の凍結理由・取引履歴を分析し、誤検知の疑いがあれば凍結解除の提案を行う。**書き込み権限は「提案の記録」までで、凍結解除の実行権限は一切持たない**
- **提供機能**：fraud-mcp-serverが公開するMCPツールを呼び出し、凍結中口座の凍結根拠・取引履歴を分析し、誤検知かどうかを判断する。結果を凍結解除提案としてfraud-mcp-server経由で記録する
- **保有データ**：なし（frontendから渡された委任トークンを保持するのみ。永続化しない）
- **連携相手**：frontend（Token Exchangeで得たトークンによる実呼び出しを受ける）、fraud-mcp-server（MCPクライアントとして）。Keycloakとは自身のEnvoyサイドカー経由でToken Exchangeを行う（受け取った`aud=fraud-agent`のトークンを`subject_token`に`audience=fraud-mcp-server, scope=account:read`で交換。アプリ本体はトークンを一切意識しない。[ADR 0002](adr/0002-token-exchange-in-envoy-sidecar.md)・[ADR 0014](adr/0014-fraud-agent-token-exchange.md)）
- **技術スタック**：TypeScript / Claude Agent SDK（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）

## fraud-mcp-server

- **存在意義**：account-serviceの読み取り・提案系機能をMCPツールとして公開する。AIエージェントとaccount-serviceの間に立ち、MCPプロトコルとREST/gRPCの変換を担う
- **提供機能**：MCPツール`get_frozen_accounts`（凍結中口座とその凍結根拠の照会）、`get_account_history`（取引履歴照会）、`propose_unfreeze`（凍結解除案の記録）
- **保有データ**：なし。account-serviceへの中継のみ
- **連携相手**：fraud-agentからMCPで呼ばれる。account-serviceへToken Exchange（audience=account-service, scope=account:read/account:propose）を行った上で委任する
- **技術スタック**：Python / FastMCP（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）

## fraud-detection-engine（不正検知エンジン）

- **存在意義**：取引パターンを監視し、疑わしい取引を検知した口座を自動的に凍結する。account-serviceが「MCPサーバー経由（AI）」だけでなく「通常のマイクロサービス」からも利用されることを示す対照項（[ADR 0011](adr/0011-scenario-ai-assisted-unfreeze.md)）
- **提供機能**：取引パターンの監視、疑わしい口座の自動凍結。account-serviceへ機械間認証（client_credentials, scope=account:freeze）で凍結を依頼する。凍結時の判定根拠（発火した検知ルール・スコア等）をaccount-serviceに記録させる
- **保有データ**：検知ルール・しきい値の設定（詳細は実装時に決定）。PostgreSQL（account-serviceと同一インスタンス内の別データベース。[ADR 0008](adr/0008-per-service-datastore-strategy.md)）
- **連携相手**：account-serviceへ機械間認証で直接アクセスする。ユーザー委任チェーンには参加しない
- **技術スタック**：Rust / Axum（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）

## account-service（今回の主役）

- **存在意義**：口座・取引データを保有する共有マイクロサービス。MCPサーバー（fraud-mcp-server）と通常のマイクロサービス（fraud-detection-engine）の双方から利用され、呼び出し元アナリストの業務属性に基づくアクセス制御を行う
- **提供機能**：
  - 取引履歴・凍結中口座の照会（`account:read`）
  - 凍結解除案の記録（`account:propose`）
  - 口座凍結の自動実行（`account:freeze`）。fraud-detection-engineからの機械間認証リクエストのみを受け付け、業務属性チェックは行わない
  - 口座凍結の解除の実行（`account:unfreeze`）。実行時にanalyst-attribute-serviceへ再照会し業務属性を再検証する（多層防御）
  - アナリスト経由のリクエストでは、呼び出し元の担当地域・権限レベルに応じて閲覧・凍結解除可能な口座を制限する（access-control-design.md 表5）
- **保有データ**：口座（地域`region`、ティア`standard`/`high-value`）、取引履歴、口座凍結記録（fraud-detection-engineがいつ・何を根拠に凍結したか）、凍結解除提案（誰が・何を根拠に提案したか）、凍結解除実行記録（誰が・どの提案を確定したか）。PostgreSQL（[ADR 0008](adr/0008-per-service-datastore-strategy.md)）
- **連携相手**：fraud-mcp-server・fraud-detection-engine・frontendから呼ばれる。アナリスト経由のリクエストではanalyst-attribute-serviceへさらに委任する
- **技術スタック**：Java / Spring Boot（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）

## analyst-attribute-service

- **存在意義**：アナリストの業務属性（担当地域・権限レベル）を一元管理する属性局。委任チェーンの終端
- **提供機能**：アナリスト情報照会（`analyst:read`、account-serviceからのみ許可）
- **保有データ**：アナリスト（担当地域の配列、権限レベル`junior`/`senior`）。PostgreSQL（account-service/fraud-detection-engineと同一インスタンス内の別データベース。[ADR 0008](adr/0008-per-service-datastore-strategy.md)）
- **連携相手**：account-serviceから委任で呼ばれる。他のどこからも呼ばれない
- **技術スタック**：Go（標準ライブラリの`net/http`。選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）
