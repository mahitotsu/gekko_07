# サービス仕様

各サービスの存在意義・提供機能・保有データを定義する。認可の詳細・トークンチェーンの実装方式は[architecture.md](architecture.md)を参照。

各サービスの技術スタックは意図的に統一しない（多言語構成の理由は[requirements.md](requirements.md)「背景（なぜサイドカーへ切り出すか）」参照：Token Exchangeをサイドカーへ切り出す価値は、実装言語がバラバラな構成でこそ際立つ）。個々の選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)を参照。

frontendはAuthorization Code + PKCEブラウザフローでログインする（[ADR 0031](adr/0031-frontend-implementation.md)）。

## frontend（BFF。[ADR 0031](adr/0031-frontend-implementation.md)）

- **存在意義**：アナリストがシステムに触れる唯一の入口。ログイン・チャットUI・取引ダッシュボード・凍結解除確定ボタンを提供する
- **提供機能**：
  - ログイン（Authorization Code + PKCE）。発行される直後のトークンは`aud=frontend`のみ（スコープなし。[ADR 0005](adr/0005-single-audience-tokens-only.md)）
  - 取引ダッシュボード：ログイントークンを`subject_token`にToken Exchange（audience=account-service, scope=account:read）を行い、そのトークンでaccount-serviceにアクセスする
  - 「AIによる精査を依頼」ボタン：チャット画面へ遷移し、AIエージェントによる凍結事由の精査を自動的に開始する
  - チャット画面の「承認」「却下」「凍結解除を確定」ボタン：いずれもToken Exchange（audience=account-service, scope=account:unfreeze）を行い、そのトークンでaccount-serviceにアクセスする。承認済みの提案がある場合のみ「凍結解除を確定」ボタンが有効になる（[ADR 0036](adr/0036-unfreeze-proposal-approval-step.md)）。決定論的操作の起点
  - チャットUI：AIエージェント（fraud-agent）とのやり取り。開始時にログイントークンを`subject_token`に別のToken Exchange（audience=fraud-agent, scope=account:read）を行い、そのトークンでfraud-agentのチャット開始APIを呼ぶ（他の全ホップと同じ、実サービスへの透過的呼び出し。[ADR 0014](adr/0014-fraud-agent-token-exchange.md)）
- **保有データ**：ログインセッション（アナリストのログイントークン）。サーバー側データストアは持たず、暗号化・署名付きCookieでステートレスに保持する（[ADR 0008](adr/0008-per-service-datastore-strategy.md)）
- **連携相手**：Keycloak（認証、用途ごとのToken Exchangeの実行）、account-service（交換後のトークンで）、fraud-agent（Token Exchangeで得たトークンによる実呼び出し）
- **技術スタック**：TypeScript / Nuxt.js（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）

## fraud-agent（AIエージェント。[ADR 0030](adr/0030-fraud-agent-implementation.md)）

- **存在意義**：凍結済み口座の凍結理由・取引履歴を分析し、誤検知の疑いがあれば凍結解除の提案を行う。**書き込み権限は「提案の記録」までで、凍結解除の実行権限は一切持たない**
- **提供機能**：`POST /chat`でfrontendから呼ばれ、fraud-mcp-serverが公開するMCPツール（`get_frozen_accounts`・`get_account_history`・`propose_unfreeze`・`conclude_no_unfreeze`）のみを使って凍結中口座の凍結根拠・取引履歴を実際にAnthropic APIへ分析させる。結論として誤検知の疑いがあれば根拠とともに解除を提案し（`propose_unfreeze`）、根拠がないと判断した場合もその結論を記録する（`conclude_no_unfreeze`、[ADR 0039](adr/0039-unfreeze-recommendation-axis.md)）。SDKレベルでもこの4ツール以外を許可しない構成（`allowedTools`・`permissionMode: "dontAsk"`）にしている。レスポンスはAG-UIプロトコル（公式`@ag-ui/claude-agent-sdk`アダプタ）準拠のSSEイベントストリーム
- **保有データ**：なし（frontendから渡された委任トークンを保持するのみ。永続化しない）
- **連携相手**：frontend（Token Exchangeで得たトークンによる実呼び出しを受ける）、fraud-mcp-server（MCPクライアントとして）、Anthropic API（Claude Agent SDK本体の呼び出し先。クラスタ外・Token Exchange対象外）。Keycloakとは自身のEnvoyサイドカー経由でToken Exchangeを行う（受け取った`aud=fraud-agent`のトークンを`subject_token`に`audience=fraud-mcp-server, scope=account:read`で交換。アプリ本体はトークンを一切意識しない。[ADR 0002](adr/0002-token-exchange-in-envoy-sidecar.md)・[ADR 0014](adr/0014-fraud-agent-token-exchange.md)）
- **技術スタック**：TypeScript / Claude Agent SDK（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）。Anthropic API呼び出しは`claude setup-token`で取得したOAuthトークン（`CLAUDE_CODE_OAUTH_TOKEN`）を使う

## fraud-mcp-server（[ADR 0029](adr/0029-fraud-mcp-server-implementation.md)）

- **存在意義**：account-serviceの読み取り・提案系機能をMCPツールとして公開する。AIエージェントとaccount-serviceの間に立ち、MCPプロトコルとREST/gRPCの変換を担う
- **提供機能**：MCPツール`get_frozen_accounts`（凍結中口座とその凍結根拠の照会）、`get_account_history`（取引履歴照会）、`propose_unfreeze`（凍結解除案の記録）、`conclude_no_unfreeze`（解除の根拠なしという結論の記録。[ADR 0039](adr/0039-unfreeze-recommendation-axis.md)）
- **保有データ**：なし。account-serviceへの中継のみ
- **連携相手**：fraud-agentからMCPで呼ばれる。account-serviceへは自身のEnvoy/token-exchangeサイドカー経由でToken Exchange（audience=account-service, scope=account:read/account:propose）を行った上で委任する（アプリ本体は受信した委任トークンをそのまま転送するだけで、Token Exchange自体は一切意識しない。[ADR 0002](adr/0002-token-exchange-in-envoy-sidecar.md)・[ADR 0019](adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)）
- **技術スタック**：Python / FastMCP（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）

## fraud-detection-engine（不正検知エンジン。[ADR 0027](adr/0027-fraud-detection-engine-implementation.md)）

- **存在意義**：取引パターンを監視し、疑わしい取引を検知した口座を自動的に凍結する。account-serviceが「MCPサーバー経由（AI）」だけでなく「通常のマイクロサービス」からも利用されることを示す対照項（[ADR 0011](adr/0011-scenario-ai-assisted-unfreeze.md)）
- **提供機能**：ingressの受け口は持たず、バックグラウンドで一定間隔（既定5秒）ごとに自身が保有する観測シグナルを検知ルールのしきい値と照合し、該当する口座があればaccount-serviceへ機械間認証（client_credentials, scope=account:freeze）で凍結を依頼する。凍結時の判定根拠（発火した検知ルール・スコア等）をaccount-serviceに記録させる。実際の取引イベントストリームは存在しないため、観測シグナル自体は起動時に投入する固定シードで代用する（実運用ではここが実際の監視入力に置き換わる想定。architecture.md参照）
- **保有データ**：検知ルール・しきい値の設定、観測シグナル（口座ID・発火ルール・スコア・理由）、凍結実行済みマーク（同じ口座を繰り返し凍結依頼しないための冪等性管理）。PostgreSQL（account-service・analyst-attribute-serviceと同一インスタンス内の別データベース。[ADR 0008](adr/0008-per-service-datastore-strategy.md)）
- **連携相手**：account-serviceへ機械間認証で直接アクセスする。ユーザー委任チェーンには参加しない
- **技術スタック**：Rust / Axum（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)。DBアクセスは`tokio-postgres`のみでORM・マイグレーションフレームワークは導入しない）

## account-service（今回の主役）

- **存在意義**：口座・取引データを保有する共有マイクロサービス。MCPサーバー（fraud-mcp-server）と通常のマイクロサービス（fraud-detection-engine）の双方から利用され、呼び出し元アナリストの業務属性に基づくアクセス制御を行う
- **提供機能**：
  - 取引履歴・凍結中口座の照会（`account:read`）
  - 凍結解除案の記録（`account:propose`）
  - 口座凍結の自動実行（`account:freeze`）。fraud-detection-engineからの機械間認証リクエストのみを受け付け、業務属性チェックは行わない
  - 口座凍結の解除の実行（`account:unfreeze`）。実行時にanalyst-attribute-serviceへ再照会し業務属性を再検証する（多層防御）
  - アナリスト経由のリクエストでは、呼び出し元の担当地域・権限レベルに応じて閲覧・凍結解除可能な口座を制限する（architecture.md 表5）
- **保有データ**：口座（地域`region`、ティア`standard`/`high-value`）、取引履歴、口座凍結記録（fraud-detection-engineがいつ・何を根拠に凍結したか）、凍結解除提案（誰が・何を根拠に、AIの結論（`unfreeze`=解除推奨/`keep_frozen`=根拠なし。[ADR 0039](adr/0039-unfreeze-recommendation-axis.md)）は何か、承認/却下の状態と決定者・決定日時。[ADR 0036](adr/0036-unfreeze-proposal-approval-step.md)）、凍結解除実行記録（誰が・どの提案を確定したか）。PostgreSQL（[ADR 0008](adr/0008-per-service-datastore-strategy.md)）
- **連携相手**：fraud-mcp-server・fraud-detection-engine・frontendから呼ばれる。アナリスト経由のリクエストではanalyst-attribute-serviceへさらに委任する
- **技術スタック**：Java / Spring Boot（選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）

## analyst-attribute-service

- **存在意義**：アナリストの業務属性（担当地域・権限レベル）を一元管理する属性局。委任チェーンの終端
- **提供機能**：アナリスト情報照会（`analyst:read`、account-serviceからのみ許可）
- **保有データ**：アナリスト（担当地域の配列、権限レベル`junior`/`senior`）。PostgreSQL（account-service/fraud-detection-engineと同一インスタンス内の別データベース。[ADR 0008](adr/0008-per-service-datastore-strategy.md)）
- **連携相手**：account-serviceから委任で呼ばれる。他のどこからも呼ばれない
- **技術スタック**：Go（標準ライブラリの`net/http`。選定理由は[ADR 0007](adr/0007-per-service-language-selection.md)）
