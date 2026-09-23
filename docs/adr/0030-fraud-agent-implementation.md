# ADR 0030: fraud-agentを本実装し、Anthropic API向けに初めてのクラスタ外egressを設ける

- **Status**: Partially superseded by [0037](0037-fraud-agent-anthropic-stream-retry.md)（アダプタ実行失敗時に無条件で`RUN_ERROR`を返す部分を、ターン単位の1回自動リトライに置き換え）・[0038](0038-fraud-agent-anthropic-route-timeout.md)（`anthropic_gateway`ルートに抜けていた`timeout: 0s`/`idle_timeout: 300s`を追加）。Anthropicへのegress構成（別名・TLS終端・`retry_policy`）自体は有効なまま
- **Date**: 2026-09-19

## Context

[ADR 0029](0029-fraud-mcp-server-implementation.md)でfraud-mcp-serverを本実装した時点で、README.mdの残り未着手項目はfraud-agent・frontendの2サービスだった。fraud-agentはfraud-mcp-serverのみに依存し（frontend未実装への依存が無い）、architecture.md §3の実装順序（1ホップ先行検証の順）でも残り2サービス中もっとも先頭に位置するため、本実装の最有力候補だった。

fraud-agentは[ADR 0007](0007-per-service-language-selection.md)でTypeScript/Claude Agent SDKと選定済み。[architecture.md](../architecture.md) UC1は「fraud-agentが凍結理由・取引履歴を分析し、誤検知の疑いがあれば解除を提案する」という実際のAI分析を前提にしており、決定論的なスタブ分析ではなく実際にAnthropic APIを呼び出す実装方針とした。

これは本リポジトリで初めて「クラスタ外（インターネット上のapi.anthropic.com）への実通信」が発生するケースであり、既存のSPIFFE mTLS前提のEnvoyサイドカーパターン（[ADR 0010](0010-egress-listener-granularity.md)の2パターン：①Token Exchange透過プロキシ、②client_credentials発行）のどちらにも当てはまらない新規のアーキテクチャ判断を要した。

実装当初は`POST /chat`を「`query()`の完了を待ってから一括でJSONを返す」同期実装にしたが、実機検証で2つの問題が判明した。1つ目：LLM呼び出しは本質的に実行時間が不定長（ツール呼び出しを挟む複数ターンの合計）であり、Envoyのルートタイムアウトを固定値（120秒）に緩めても実機で超過する事例が発生した。2つ目：frontendの将来目標がAG-UIプロトコル（CopilotKitが提唱するAgent-User Interaction Protocol、フロントエンドとAIエージェントをSSE/WebSocketで繋ぐオープン規格）への対応であるため、独自のJSON契約を今作ってfrontend本実装時に作り直すよりも、最初からAG-UIプロトコルに準拠したストリーミング実装にする方が手戻りが無いと判断した。この2つの理由から、`/chat`をAG-UIプロトコルのSSEストリームを返す実装に作り直した（後述）。

## Decision

### `services/fraud-agent/`（TypeScript/Claude Agent SDK、[ADR 0007](0007-per-service-language-selection.md)の言語選定を踏襲）

fraud-mcp-server（Python/FastMCP、ADR 0029）と同型の構成（単一ファイル`src/app.ts`、Node標準の`http`モジュールでHTTPサーバーを実装）を踏襲しつつ、AG-UIプロトコルの実装には公式のTypeScript SDK一式（`@ag-ui/core`・`@ag-ui/encoder`・`@ag-ui/claude-agent-sdk`）を使う。自前でイベントの型・SSEフレーミングを実装しない（fraud-mcp-serverがFastMCPを使うのと同じ「プロトコル実装は公式SDKに任せる」方針）。

- 多層防御（ADR 0009 §2、fraud-mcp-serverの`HandshakeMiddleware`と同じ2点）：①接続元loopback再チェック②合言葉ヘッダー検証。全ルート（`/healthz`含む）に一律で適用する（検証ロジックは環境によらず単一。CWE-489）。
- `POST /chat`が唯一の業務エンドポイント（frontend→fraud-agent、ADR 0014/0024。`scripts/verify-hop.sh`の既存呼び出し先と一致）。リクエストボディをAG-UIの`RunAgentInput`（`threadId`・`runId`・`messages`が必須。`@ag-ui/core/schemas`の`RunAgentInputSchema`で検証する。**サブパスインポートが必要**：`@ag-ui/core`本体からは`RunAgentInputSchema`はエクスポートされていない）として解釈し、`threadId`/`runId`/`messages`が無ければ補って構築する（`messages`が無い場合はUC1既定プロンプトの単発ユーザーメッセージにfail closeする。frontend本実装前の`verify-hop.sh`がボディ無しで`/chat`を叩く運用に合わせた）。
- レスポンスは`Content-Type: text/event-stream`のAG-UIイベントストリーム（`EventEncoder.encodeSSE()`が`data: {...}\n\n`フレーミングを生成する）。`RUN_STARTED`→`TEXT_MESSAGE_*`/`TOOL_CALL_*`→`RUN_FINISHED`（正常時）、または`RUN_ERROR`（異常時）という標準のイベント順序に従う。
- 公式アダプタ`ClaudeAgentAdapter`（`@ag-ui/claude-agent-sdk`）が内部で`query()`のライフサイクル・メッセージ→AG-UIイベント変換を管理する。**リクエストごとに新しい`ClaudeAgentAdapter`インスタンスを作る**（アダプタの設定はコンストラクタ時点で固定されるため、分析対象アナリストが変わるたびに異なる委任トークンを`mcpServers`へ渡す必要がある本リポジトリの要件には、インスタンスを使い回すAPIが用意されていない。1リクエスト1インスタンスは無駄だが状態を持たないため安全）。
- 受信した`Authorization`ヘッダーをそのまま`mcpServers.fraud_mcp_server.headers.Authorization`（`type: "http"`, `url: "http://fraud-mcp-server/mcp"`）へ渡す。`McpHttpServerConfig`はアダプタ生成のたびに設定できることを実機で確認した。egressのtoken-exchangeサイドカー（ADR 0023）がこれをsubject_tokenとして扱う。アプリ本体はToken Exchangeを一切意識しない（fraud-mcp-serverの`_delegated_authorization`と同じ設計）。
- アダプタの設定は`tools: []`（組み込みツールを全て無効化）・`allowedTools`にfraud-mcp-serverが公開する3ツール名（`mcp__fraud_mcp_server__get_frozen_accounts`等）のみを明示・`permissionMode: "dontAsk"`（許可リスト外のツール呼び出しは確認無しで拒否）とし、SDKレベルでも「読み取り・提案のみ」に構造的に絞った（architecture.md表2のスコープ設計と同じ意図の多層防御。SDK側の制約が破られてもToken Exchangeのスコープ側で`account:unfreeze`は取得できない）。
- アダプタ内部のエラーはAG-UIの`RUN_ERROR`イベントとしてストリームに乗って返ってくる（詳細を漏らさない一律のメッセージ。account-service/fraud-mcp-serverと同じfail-close方針）ため、アプリ側で追加の変換は不要。Observable自体が予期せずエラーになった場合（アダプタのバグ等）のみ、保険として自前で`RUN_ERROR`を書いてから接続を閉じる。〔[ADR 0037](0037-fraud-agent-anthropic-stream-retry.md)で追加：Anthropic応答ストリーミング中の切断についてはRUN_ERRORの前にターン単位で1回だけ自動リトライするようになった〕
- `CLAUDE_CODE_OAUTH_TOKEN`（`claude setup-token`で取得したOAuthトークン、`sk-ant-oat01-...`、有効期限1年）はSDKが`process.env`から自動的に読む。アプリコードはこの環境変数を明示的に扱わない。

### `services/fraud-agent/Dockerfile`

fraud-mcp-serverと同じくマルチステージ・非rootで統一した。`node:22-slim`（distrolessにせず-slimを選ぶ理由もfraud-mcp-serverと同じ：`scripts/verify-hop.sh`のkubectl exec診断で引き続きシェル・ランタイムを使えるようにするため）。ビルド段で`npm ci && npm run build`、実行段で`npm ci --omit=dev`＋コンパイル済み`dist/`のみをコピーする。`@anthropic-ai/claude-agent-sdk`は独自のCLIランタイム（`cli.js`、約11MB）を同梱した自己完結パッケージであり、別途`claude`バイナリのインストールは不要（実機のnpm installで確認済み）。非rootはnode公式イメージ組み込みの`node`ユーザー（uid 1000）を使う。

### 新規アーキテクチャ判断：Anthropic API向けegress

Claude Agent SDK本体が呼ぶAnthropic API（`api.anthropic.com`）は、Keycloakが認識するaudienceでもSPIRE mTLSのメッシュ内ピアでもない。ADR 0010の2パターン（Token Exchange／client_credentials）はいずれもKeycloak登録済みaudience宛てを前提としており、この新しいケースには当てはまらない。

#### 検討した選択肢

**1. appコンテナから直接api.anthropic.comへ接続（不採用）**：Envoy・hostAliasesを一切介さず、appが実際のDNS解決・TCP接続を行う方式。実装は最も単純だが、本リポジトリが一貫して守ってきた「appは常に自身のEnvoyサイドカー経由でしか外と通信しない」という構造的な一貫性が崩れる。NetworkPolicyの許可対象もappコンテナ自身のegressになり、Envoy側の監査ログ（access_log）に一切残らなくなる。

**2. Envoyのblind tcp_proxy（不採用。実装して実機で破綻を確認した）**：Envoyの新規リスナー（127.0.0.1:443）が`transport_socket`を一切設定せず、appのTLSバイト列をそのまま`api.anthropic.com`へtcp_proxyする案。appはhostAliasesで`api.anthropic.com`自体を127.0.0.1へ横取りされる想定だったが、**hostAliasesはPod内の全コンテナ（Envoy自身を含む）で共有される`/etc/hosts`への追記であるため、Envoy自身のクラスタ名前解決も同じエントリを引いてしまい、127.0.0.1（＝自分自身）への自己参照ループになることを実機で確認した**（`Too many open files`でのクラッシュ・ループとして顕在化）。内部サービス（account-service等）ではapp向けの短縮名（`account-service`）とEnvoy向けのFQDN（`account-service.gekko.svc.cluster.local`）が異なるためこの衝突は起きないが、Anthropicは公開ホスト名が1つしかないため同じ手が使えない。

**3. app向けの別名＋EnvoyでTLS終端（採用）**：Claude Agent SDKが標準で尊重する`ANTHROPIC_BASE_URL`環境変数を使い、appの接続先を実ホスト名とは異なる内部専用の別名`http://anthropic-gateway`にする（`anthropic-gateway`をhostAliasesで127.0.0.1へ横取り。この別名はEnvoy自身が解決しようとする名前とは別物なので選択肢2の衝突が起きない）。Envoyのegress:80リスナーに`anthropic_gateway`という仮想ホストを追加し、ここでTLSを終端して実際の`api.anthropic.com:443`へ公開CA検証で再接続する。内部サービスの「短縮名(app向け) vs FQDN(Envoy向け)」パターンと同じ考え方をAnthropicにも適用した形になる。

選択肢3を実装する過程で、さらに3つの実機特有の問題が見つかった（詳細は[insights.md](../insights.md)）。

1. **ALPNとHTTPコーデックの不一致**：`alpn_protocols: ["h2", "http/1.1"]`を指定すると、Anthropic側がh2を選んだ場合にEnvoyのHTTP層（`typed_extension_protocol_options`でhttp2を明示していないため既定でHTTP/1.1コーデック）と食い違い、`reset reason: protocol error`になった。`http/1.1`のみに絞ることで解消。
2. **Hostヘッダーの不一致**：appは接続先URLのホスト名（`anthropic-gateway`）をそのままHostヘッダーに送るが、SNIは`api.anthropic.com`のため、Anthropic側が`421 Misdirected Request`で拒否した。ルートに`host_rewrite_literal: api.anthropic.com`を追加し、Envoyが転送時にHostヘッダーを実際のホスト名へ書き換えることで解消。
3. **HTTP/1.1 keep-alive接続の失効**：1回の会話ターンでAnthropic APIを複数回（ツール呼び出しを挟んで）呼ぶ際、間隔が空くとAnthropic側のエッジが先にkeep-alive接続を閉じることがあり、Envoyが失効した接続を掴むと`socket connection was closed unexpectedly`になった。ルートに`retry_policy`（`retry_on: "reset,connect-failure,refused-stream"`）を追加し、失効した接続を掴んだ場合のみ透過的に再試行するようにした（レスポンスヘッダー到達前のリセットのみが対象のため、二重実行の心配は無い）。

最終的に、`/chat`で実際にAnthropic APIを呼び・fraud-mcp-server経由でaccount-serviceのデータを取得し・`RUN_FINISHED`まで到達することを実機（k3dクラスタ内、`CLAUDE_CODE_OAUTH_TOKEN`使用）で確認した。

#### APIキー（OAuthトークン）の扱い

`CLAUDE_CODE_OAUTH_TOKEN`はappコンテナ自身がSecret（`secretKeyRef`、`k8s/account-service/deployment.yaml`のDB_PASSWORDと同じパターン）経由で保持する。Envoyはこのトークンの値そのものには関与しない（HTTPヘッダーとして素通しするだけで、Token Exchangeのような書き換え・検証は行わない）。これは本リポジトリが一貫して守ってきた「秘密鍵に触れるのはEnvoyのみ」原則（ADR 0009 §2、SPIRE mTLSの秘密鍵について）からの意図的な逸脱である。理由：この原則はメッシュ内でのmTLS身元証明・Token Exchangeという「委任チェーン上のプロセス間認証」を対象にしたものであり、Anthropic呼び出しはそのどちらでもない、委任チェーン外の単純なAPIキー認証である。

### Envoyのタイムアウト設計：固定`timeout`ではなく`idle_timeout`

`/chat`はLLM呼び出しを含むため実行時間が本質的に不定長であり、リクエスト開始から完了までの総時間に上限を課す固定`timeout`とは相性が悪い。実機検証で以下を確認した。

- 当初、既定の15秒（Envoyのルートタイムアウト既定値）から120秒へ緩めたが、それでも実機で`upstream connect error or disconnect/reset before headers`（Envoy側が先に接続を切る）が発生する事例があった。固定タイムアウトは「今回はたまたま収まる値」を推測するゲームにしかならず、本質的な解決にならない。
- 対応：`/chat`が通る全ホップ（edge-proxy→frontend、frontend→fraud-agent、fraud-agent自身のingress）のEnvoyルートを`timeout: 0s`（総時間の上限を無効化）＋`idle_timeout: 300s`（無活動時間の上限。SSEイベントが実際に流れている限りリセットされる）に変更した。AG-UIイベントが継続的に流れる限りタイムアウトせず、本当にハングした場合のみ5分でカットされる。〔[ADR 0038](0038-fraud-agent-anthropic-route-timeout.md)で訂正：この一覧にfraud-agent→Anthropic（egress、`anthropic_gateway`ルート）自身が抜けており、既定の15秒route timeoutのままだった〕

frontend-stub（`k8s/frontend/app-configmap.yaml`）も、fraud-agentからの応答を`urllib.request.urlopen().read()`で全部読み切ってから返す従来の`forward()`ではなく、`resp.readline()`で1行ずつ即座に中継する`stream_forward()`を`/chat`専用に新設した。バッファ方式のままだと、fraud-agentの処理が終わるまでedge-proxy⇔frontend間の接続が完全に無活動になり、上記のidle_timeout設計の恩恵を受けられない（frontendがEnvoyから見て「詰まっている」ように見えてしまう）ため。

envoyコンテナの起動コマンドには`ulimit -n 65536`（既定のnofile soft limit 1024を引き上げ）も追加してある。上記のblind tcp_proxy自己参照ループを試していた際に`Too many open files`でのクラッシュを実機で確認した名残りだが、hard limitの範囲内でのsoft limit変更は非特権プロセスでも可能で無害なため、安全側の設定として残した。

#### NetworkPolicy

`k8s/fraud-agent/networkpolicy.yaml`に新規egressルールを追加した。Anthropicの実IPは公開レンジとして固定できないため、`ipBlock: 0.0.0.0/0`から RFC1918プライベートレンジ（`10.0.0.0/8`・`172.16.0.0/12`・`192.168.0.0/16`。このクラスタのk3d docker network `172.19.0.0/16`を含む）を`except`で除外した範囲をport 443のみで許可する。既存のfraud-mcp-server向けpodSelectorルールとは独立に論理和で合成されるため、この除外が内部到達性に影響することはない。

**本リポジトリで初めての「公開インターネットegress」の例外**であり、[ADR 0018](0018-network-policy-default-deny.md)がこれまで前提としてきた「全ての許可ルールはpodSelectorで宛先を特定できる」という運用から外れる。

## Consequences

- README.md・docs/services.mdの進捗を「fraud-mcp-serverが本実装済み」から「fraud-agentも本実装済み」へ更新した。残るfrontendは引き続きスタブのまま。
- Deployment名を`fraud-agent-stub`から`fraud-agent`へリネームした（fraud-mcp-serverと違い、fraud-agentは元々スタブ専用の別名を持っていたため、Makefileの`deploy`ターゲットに`kubectl delete deployment fraud-agent-stub --ignore-not-found`という明示的な後始末を追加した）。
- `CLAUDE_CODE_OAUTH_TOKEN`はKeycloak admin password等と違いopenssl randで自動生成できない実クレデンシャルであり、Makefileに専用の取得ロジック（`.secrets/claude-code-oauth-token`があれば再利用、無ければ環境変数から読み取って保存、どちらも無ければ`make deploy`を明確なエラーで停止）を追加した。
- `k8s/fraud-agent/networkpolicy.yaml`のegress例外（`ipBlock 0.0.0.0/0 except <RFC1918>`）は、[ADR 0018](0018-network-policy-default-deny.md)のConsequencesに追記した。
- `scripts/verify-hop.sh`の7番は、レスポンスをJSON一括ではなくAG-UI SSEイベントストリームとして扱うよう変更した（`"reply"`キーの有無ではなく、`RUN_FINISHED`が現れ`RUN_ERROR`が現れないことを確認する）。実行時間が伸び、外部ネットワーク・`CLAUDE_CODE_OAUTH_TOKEN`の実在に依存するようになった。
- fraud-agentのresources.requests/limitsは、Claude Agent SDKが同梱するCLIランタイム（約11MB、wasm資産含む）を踏まえ、他のスタブ由来サービスより高め（requests: 100m/256Mi、limits: 500m/512Mi）に設定した。
- 残るfrontendの本実装は引き続きbacklog外（README.mdのチェックリストで追跡）。
