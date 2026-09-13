# サービス仕様

各サービスの存在意義・提供機能・保有データを定義する。認可の詳細は[permission-matrix.md](permission-matrix.md)、トークンチェーンの実装方式は[architecture.md](architecture.md)を参照。

現時点ではk3dクラスタの土台のみ存在し、以下は未実装（設計段階）。実装言語は未定（backlog.md参照）。

## frontend（BFF）

- **存在意義**：アナリストがシステムに触れる唯一の入口。ログイン・チャットUI・取引ダッシュボード・凍結確定ボタンを提供する
- **提供機能**：
  - ログイン（Authorization Code + PKCE）
  - チャットUI：AIエージェント（fraud-agent）とのやり取り
  - 取引ダッシュボード：account-serviceへの直接アクセス（`account:read`）
  - 「凍結を確定」ボタン：account-serviceへの直接アクセス（`account:freeze`）。決定論的操作の起点
  - AIエージェント起動時、自身の直接ログイントークンからToken Exchange（audience=fraud-mcp-server, scope=account:read）を行い、ダウンスコープしたトークンをfraud-agentに渡す
- **保有データ**：ログインセッション（アナリストのアクセストークン）
- **連携相手**：Keycloak（認証、Token Exchange①の実行）、account-service（直接）、fraud-agent（委任トークンの受け渡し）

## fraud-agent（AIエージェント）

- **存在意義**：取引パターンを分析し、口座凍結の提案を行う。**書き込み権限は「提案の記録」までで、凍結の実行権限は一切持たない**
- **提供機能**：fraud-mcp-serverが公開するMCPツールを呼び出し、取引履歴・不審パターンを分析。結果を凍結提案としてfraud-mcp-server経由で記録する
- **保有データ**：なし（フロントエンドから渡された委任トークンを保持するのみ。永続化しない）
- **連携相手**：fraud-mcp-server（MCPクライアントとして）。Keycloakとは直接やり取りしない（frontendが交換済みのトークンを使い回すのみ）

## fraud-mcp-server

- **存在意義**：account-serviceの読み取り・提案系機能をMCPツールとして公開する。AIエージェントとaccount-serviceの間に立ち、MCPプロトコルとREST/gRPCの変換を担う
- **提供機能**：MCPツール`get_flagged_transactions`（不審取引の照会）、`get_account_history`（取引履歴照会）、`propose_freeze`（凍結案の記録）
- **保有データ**：なし。account-serviceへの中継のみ
- **連携相手**：fraud-agentからMCPで呼ばれる。account-serviceへToken Exchange②（audience=account-service, scope=account:read/account:propose）を行った上で委任する

## payment-service

- **存在意義**：通常の入出金・振込処理。account-serviceが「MCPサーバー経由（AI）」だけでなく「通常のマイクロサービス」からも利用されることを示す対照項
- **提供機能**：入金・出金・振込処理。account-serviceへ機械間認証（client_credentials, scope=account:transact）で残高更新を依頼する
- **保有データ**：取引リクエストの受付記録（保有データの詳細は実装時に決定）
- **連携相手**：account-serviceへ機械間認証で直接アクセスする。ユーザー委任チェーンには参加しない

## account-service（今回の主役）

- **存在意義**：口座・取引データを保有する共有マイクロサービス。MCPサーバー（fraud-mcp-server）と通常のマイクロサービス（payment-service）の双方から利用され、呼び出し元アナリストの業務属性に基づくアクセス制御を行う
- **提供機能**：
  - 取引履歴・不審取引の照会（`account:read`）
  - 凍結提案の記録（`account:propose`）
  - 口座凍結の実行（`account:freeze`）。実行時にanalyst-attribute-serviceへ再照会し業務属性を再検証する（多層防御）
  - 入出金・振込処理（`account:transact`）。この操作のみ業務属性チェックを行わない（機械間認証のため）
  - アナリスト経由のリクエストでは、呼び出し元の担当地域・権限レベルに応じて閲覧・凍結可能な口座を制限する（permission-matrix.md 表5相当）
- **保有データ**：口座（地域`region`、ティア`standard`/`high-value`）、取引履歴、凍結提案（誰が・何を根拠に提案したか）、凍結実行記録（誰が・どの提案を確定したか）
- **連携相手**：fraud-mcp-server・payment-service・frontendから呼ばれる。アナリスト経由のリクエストではanalyst-attribute-serviceへさらに委任する

## analyst-attribute-service

- **存在意義**：アナリストの業務属性（担当地域・権限レベル）を一元管理する属性局。委任チェーンの終端
- **提供機能**：アナリスト情報照会（`analyst:read`、account-serviceからのみ許可）
- **保有データ**：アナリスト（担当地域の配列、権限レベル`junior`/`senior`）
- **連携相手**：account-serviceから委任で呼ばれる。他のどこからも呼ばれない
