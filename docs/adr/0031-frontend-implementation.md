# ADR 0031: frontendを本実装し、簡易ログイン(ROPC)を本物のAuthorization Code + PKCEへ置き換える

- **Status**: Partially superseded by [0032](0032-frontend-oidc-callback-form-post.md)（`/callback`をGET→POST(form_post)化）・[0034](0034-frontend-display-username-instead-of-sub.md)（`layouts/authenticated.vue`のヘッダー表示をsub→usernameに変更）。それ以外のAuthorization Code + PKCE設計・BFFパターン・セッションCookie設計は本ADRのまま有効
- **Date**: 2026-09-19

## Context

[ADR 0030](0030-fraud-agent-implementation.md)でfraud-agentを本実装した時点で、README.mdの残り未着手項目はfrontendのみだった。frontendは[ADR 0024](0024-frontend-edge-proxy-and-simplified-login.md)でedge-proxy配線・SPIRE mTLS・Token Exchangeの実機検証をスタブ（Python、簡易ログイン=ROPCのHTTPエンドポイント化）で先行完了させており、fraud-agentが実在するようになったことで、frontendを本実装すればログイン→ダッシュボード→チャット→凍結解除確定の一気通貫シナリオ（UC1/UC2）を初めて実機で通せる状態になった。

frontendは[ADR 0007](0007-per-service-language-selection.md)でTypeScript/Nuxt.jsと選定済み。[docs/services.md](../services.md)は本実装のセッション管理を「サーバー側データストアを持たず、暗号化・署名付きCookieでステートレスに保持する」と明記しており、ADR 0024は「本実装（TypeScript/Nuxt.js）時に、本物のリダイレクト・code_verifier管理・Cookieによるセッション管理へ置き換え、`directAccessGrantsEnabled`をfalseに戻すかどうかを判断する」ことを本ADRに持ち越していた。

## Decision

### BFF（Backend for Frontend）・Confidential Clientを維持する

frontendは引き続きConfidential Client（`publicClient: false`・`clientAuthenticatorType: federated-jwt`。Keycloakクライアント設定自体は変更しない）であり、生のトークン（access_token・id_token）はブラウザに一切渡さないBFFパターンを徹底する。ブラウザが受け取るのはhttpOnlyの不透明なCookieのみで、ダッシュボード・チャット画面のクライアント側JSはトークンに触れない（同一オリジンの`fetch`がCookieを自動送信するのみ）。PKCEはこのConfidential Client構成に対する追加の防御層（認可コード横取り対策）として導入するのであり、PKCE採用によってPublic Client化するわけではない。

### login時に受け取る`id_token`をOIDCのRelying Partyとして検証・デコードする

Authorization Codeフローでは`scope=openid`によりKeycloakが`access_token`に加えて`id_token`を返す。OpenID Connect Coreの仕様上、RP（＝frontend）は`id_token`の署名検証（KeycloakのJWKS）・`iss`・`aud=frontend`・`exp`・`nonce`（リプレイ対策。PKCEの`state`と対で発行する）を確認してから「認証されたユーザー」として扱う義務がある。これはEnvoyのjwt_authnが担ってきた「リソースサーバー向けBearerトークン検証」とは別物（RPとしての自己責任の検証）であり、frontendが初めてOIDC RPになることで新たに必要になった。

- `services/frontend`に`jose`（Node/TypeScriptで広く使われる実績のあるJWT/JWKSライブラリ）を追加した。自前でRS256検証を書かない（AG-UI公式SDKをそのまま使うfraud-agentの方針=「プロトコル実装は自前で書かない」を踏襲）
- JWKS取得は`token-exchange`サイドカーではなくアプリ本体（Nitro、`server/utils/jwks.ts`）が行う。[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)の「appはKeycloakと直接通信しない」原則は「クライアント認証情報を使ってKeycloakにトークンを要求する」操作を指しており、公開鍵（JWKS、秘密情報を含まない）の取得はこれに該当しないと判断した。取得経路自体はEnvoyの既存egressリスナー（`k8s/frontend/envoy-configmap.yaml`の`keycloak`ドメインルート。token-exchangeサイドカー自身のKeycloak宛て通信と同じくext_authzが無効化済み）をそのまま使う——appはこれまでどおり`http://keycloak/...`へplaintextで投げるだけで、実際のmTLS終端はEnvoyが行う（証明書はappに一切触れさせないADR 0009 §2の原則は維持される）
- `/callback`で認可コードをトークンに交換した直後、`jose.jwtVerify(id_token, remoteJWKS, {issuer, audience: "frontend"})`で検証し、`sub`・`exp`を取り出す。検証に失敗した場合はfail closeで`/login?error=1`へリダイレクトする
- 検証済みの`sub`・`exp`・`id_token`（ログアウトで`id_token_hint`として使うため保持する）と、Token Exchangeに使う`access_token`をセッションの中身とする

### セッションはAES-256-GCMで暗号化したCookieに保持し、Envoyの`jwt_authn`はフロントエンドingressから撤去する

GCMは暗号化と改ざん検知を同時に満たすため、services.mdの「暗号化・署名付きCookie」をそのまま実現できる。「復号」は`server/utils/session.ts`が毎リクエストで行う（Cookieを復号し`exp`を確認、無効なら`/login`へリダイレクト）。「検証」は前述の通りログイン時（`/callback`）に一度、JWTの署名・iss・aud・expを厳密に確認する。両者は担当箇所が異なる別の処理である。

従来のEnvoy `jwt_authn`（`k8s/frontend/envoy-configmap.yaml`）は、アプリ層で暗号化したCookieを読めないため撤去した。従来のjwt_authnは「ログイン済みかどうか」の粗いゲートに過ぎず（ADR 0024:「rbacフィルタは付けない…実際の認可はaccount-service/fraud-agent側の受け側で行う」）、業務認可はダウンストリーム（account-service/fraud-agent）のToken Exchange・RBAC/ABACが引き続き担う。代わりにアプリ自身が「ログイン時の厳密なid_token検証」＋「毎リクエストのセッション復号・exp確認」（`server/middleware/1.auth.ts`）を行うことで、Envoyのjwt_authnが提供していた保証をOIDC仕様に忠実な形で引き継いでいる。

検討した代替案：Envoyの`jwt_authn`に`from_cookies`を設定し、Cookieに生のJWTをそのまま格納する案。Envoy側の変更が最小で済む利点はあるが、services.mdが明示する「暗号化・署名付きCookie」を字義通り満たせない（生JWTは署名付きだが暗号化されていない）ため不採用とした。

暗号鍵はPod起動時に`crypto.randomBytes(32)`でプロセス内生成し、Kubernetes Secretとしては永続化しない。services.mdが明言する「ステートレス・サーバー側データストアなし」という設計そのものが「Pod再起動でセッションが失われても構わない」ことを前提にしているため、鍵の永続化は不要と判断した。複数レプリカ化する場合は再検討が要る（architecture.md参照）。

### セッションは失効させる。リフレッシュトークンによるサイレント延命は行わない

「一度ログインしたら実質無期限にセッションが有効」はバッドプラクティスであるため、リフレッシュトークンを取得・保持・使用しない（`scope`に`offline_access`等を含めない。トークンレスポンスから`refresh_token`が返っても保存せず捨てる）。`gekko_session` Cookieの`maxAge`はKeycloakが発行した`access_token`の`exp`（realm-configmap.yamlで明示的に上書きしていないためKeycloakの既定値=5分）にそのまま連動させ、`requireSession()`相当の`exp`確認と合わせて二重に効かせる。5分経過後はアプリのセッションが必ず失効し、ダッシュボード/チャットへのアクセスは`/login`へ302される（再度Keycloakの認可エンドポイントへ飛ぶ）。より長いが上限付き（絶対タイムアウト）のセッションが要る場合はリフレッシュトークン運用の再検討が要る旨をarchitecture.mdに記録した。

### ログアウト：ローカルCookie削除に加え、KeycloakのSSOセッションもRP-Initiated Logoutで終了させる

ローカルの`gekko_session`を消すだけではKeycloak自身のSSOセッション（ブラウザ側のKeycloakドメインCookie）が残るため、再度`/login`に来ると同じユーザーで自動的に認可コードが発行されてしまい、別ユーザーへの切り替えができない。`POST /logout`は以下を行う：

1. `gekko_session`・`gekko_pkce`（残っていれば）を即座に削除する
2. 保持していた`id_token`を`id_token_hint`として、Keycloakの`/realms/gekko/protocol/openid-connect/logout`（RP-Initiated Logout、OIDC標準）へブラウザを302リダイレクトする（`post_logout_redirect_uri=${EDGE_PROXY_BASE_URL}/login`）
3. KeycloakがSSOセッションを終了し、`/login`へリダイレクトして戻す

CSRF対策として`/logout`はGETリンクではなくPOST専用にする（`SameSite=Lax`は他サイトからのGETトップレベルナビゲーションでは送信されるがPOSTには送信されないため、同一オリジンのフォーム送信からしか呼べない）。UI側は`<form method="post" action="/logout">`での実送信にする——`fetch()`経由だとKeycloakのend_session_endpointへのリダイレクトをJSが自動追従して結果を捨てるだけの無駄なラウンドトリップになるため、素直なブラウザナビゲーションに任せる。

### PKCEの`code_verifier`/`state`/`nonce`は短命Cookieに保持する

`gekko_pkce`（HMAC署名付き、10分TTL）に`code_verifier`・`state`・`nonce`をまとめて保持する。署名鍵はセッション暗号鍵と同じくプロセス内生成。`/login`（GET）で生成・設定し、`/callback`（GET）で検証・削除する。`nonce`はid_token検証で照合する。〔[ADR 0032](0032-frontend-oidc-callback-form-post.md)で訂正：`/callback`はresponse_mode=form_postによりPOSTに変更。GETは迷い込み時のfail-close専用〕

### Cookie属性

`httpOnly`・`SameSite=Lax`・`secure=false`（ローカルk3d port-forwardがhttpのため。本番相当環境対応時の検討事項としてarchitecture.mdに記録）。`SameSite=Lax`はOAuthのトップレベルリダイレクト（Keycloak→`/callback`のGET）では送信されるが他サイトからのPOSTでは送信されないため、追加のCSRFトークンなしで妥当な保護になる。〔[ADR 0032](0032-frontend-oidc-callback-form-post.md)で訂正：`/callback`はresponse_mode=form_postによりPOSTに変更されたが、edge-proxyが同一オリジン(`http://localhost:3000`)でKeycloak・frontendの両方を配信しているため、Keycloakからのform_post submitは同一オリジン遷移であり`SameSite=Lax`でも送信される。追加のCSRFトークン不要という結論自体は変わらない〕

### `directAccessGrantsEnabled`を`false`に戻し、ROPCコードを完全に削除する

バックワード互換シムは残さない方針。`k8s/keycloak/realm-configmap.yaml`のfrontendクライアントを`directAccessGrantsEnabled: false`に戻し、`k8s/frontend/token-exchange-app-configmap.yaml`から`ropc_login()`を削除して`exchange_authorization_code(code, redirect_uri, code_verifier)`（`grant_type=authorization_code`）に置き換えた。サイドカーの新エンドポイントは`POST /login/complete`（`{code, redirectUri, codeVerifier}`を受け`{access_token, id_token, expires_in}`を返す）。

### `services/frontend/`（新規、Nuxt.js）

Nitro（Nuxtサーバー）の`server/routes`/`server/middleware`で実装した。

- `server/middleware/0.security.ts`：①loopback限定bind②接続元loopback再チェック③合言葉ヘッダー検証（ADR 0009 §2、fraud-agentの`app.ts`と同型）。全リクエストに一律適用
- `server/middleware/1.auth.ts`：ページ読み込み(GET)のセッションゲート。`/login`・`/callback`・`/logout`・`/me`・`/accounts/**`・静的アセット以外の全GETに有効なセッションを要求し、無ければ`/login`へ302する
- `server/utils/crypto.ts`・`session.ts`・`jwks.ts`・`pkce.ts`：前述の暗号・検証処理
- `server/routes/login.get.ts`・`callback.get.ts`・`logout.post.ts`：Authorization Code + PKCEの起点・終点・ログアウト〔[ADR 0032](0032-frontend-oidc-callback-form-post.md)で訂正：終点は`callback.post.ts`に変更。`callback.get.ts`は迷い込みGETのfail-close専用に縮小〕
- `server/routes/accounts/[...].ts`・`chat.post.ts`：account-service・fraud-agentへのプロキシ（セッションの`access_token`を`Authorization: Bearer`として付与）。`/chat`はfraud-agentのAG-UI SSEストリームをレスポンスを読み切らず都度書き込む方式で中継する（スタブの`stream_forward()`・ADR 0030のidle_timeout設計を踏襲）
- `pages/dashboard.vue`：凍結中口座一覧（`GET /accounts/frozen`）と「凍結解除を確定」ボタン（`POST /accounts/{id}/unfreeze`）
- `pages/chat.vue`：AG-UI SSEイベントを最小限のクライアント側パーサで読み、アシスタントのテキストを逐次表示する。`propose_unfreeze`の`TOOL_CALL_RESULT`を検出したら該当`accountId`/`proposalId`で「この提案を確定」ボタンを表示し、UC1手順8〜10をチャット画面内で完結できるようにした
- `layouts/authenticated.vue`：ログイン中の`sub`表示とログアウトボタンの共通ヘッダー〔[ADR 0034](0034-frontend-display-username-instead-of-sub.md)で訂正：表示を`sub`から`username`に変更〕

### `services/frontend/Dockerfile`

fraud-agentと同じマルチステージ・`node:22-slim`・非root（`USER node`）パターン。fraud-agentと異なり実行段で`node_modules`を別途コピーしない——Nitro（`nuxt build`）は`.output/server/`配下に依存関係込みの自己完結バンドルを生成するため、`.output`だけで動く。

### `k8s/frontend/`・base trackへの統合

- `app-configmap.yaml`：削除（ビルド済みイメージに置き換わったため。fraud-mcp-server/fraud-agentと同じ）
- `deployment.yaml`：Deployment名を`frontend-stub`→`frontend`にリネーム。appコンテナを`gekko07/frontend:local`イメージへ置き換え
- `envoy-configmap.yaml`：jwt_authn撤去に伴い、専用の`keycloak_jwks`クラスタも削除した（JWKS取得は`keycloak_upstream`クラスタを流用する）
- `Makefile`：`build-frontend`を新設し、`deploy`/`undeploy`のbase trackへ統合。`deploy-verify-hop`/`undeploy-verify-hop`からはfrontend関連の行を削除した（account-service等が辿った昇格パターンと同じ）

### `scripts/verify-hop.sh`の全面更新

`$LOGIN_TOKEN`を`Authorization: Bearer`ヘッダーで持ち回る現行方式は、Cookieベースの本実装と両立しないため書き換えた。

- `login_via_frontend()`：ヘッドレスブラウザなしでKeycloakのログインフォームをcurlで直接POSTする一般的な手法で、`gekko_session` Cookieを実際に確立する（`/login`→Keycloakログインフォーム→`/callback`という一連のリダイレクトをcookie jar越しに辿る）。yamada/suzuki/tanaka個別のjarを使い、frontend向けの呼び出しは全て`-b <jar>`に置き換えた
- `raw_login_token()`：パターン①検証（fraud-agent/fraud-mcp-server連鎖のToken Exchangeをサイドカー直叩きで検証する既存手法）向けに、frontendの`/login`を経由しない独自のPKCEパラメータでKeycloakへログインし、frontendのtoken-exchangeサイドカーへ`kubectl exec`経由で`authorization_code`交換をリクエストして生のaud=frontendトークンを得る。BFFパターンによりCookieの中身からはこのトークンを取り出せないため、Envoyのext_authzが送るのと同じ形でサイドカーを直接叩く既存の技法（`sidecar_exchange`）をログイン自体にも適用したもの
- ログアウト・ユーザー切替の実機検証（6b）を新規追加：ログアウト後に`gekko_session`が失効し（`/me`が401）、KeycloakのSSOセッションも実際に終了していることを確認する

## Consequences

- README.md・docs/services.mdの進捗を「frontendも本実装済み」へ更新した。docs/architecture.mdの「frontendの簡易ログイン（ROPC）を本物のAuthorization Code + PKCEブラウザフローへ置き換える」項目は解消した
- [ADR 0024](0024-frontend-edge-proxy-and-simplified-login.md)のStatusを`Partially superseded by 0031`に更新した（ROPC・`directAccessGrantsEnabled=true`の恒久化・frontend ingressのjwt_authnは本ADRで置き換えたが、edge-proxy配線・Token Exchangeのscope解決方式・account-serviceのunfreeze rbacポリシー追加は無変更で有効）
- UC1〜UC5がfrontendのダッシュボード・チャット画面を通じて実機で一気通貫に確認できるようになった
- リフレッシュトークン不使用によりセッションは5分（Keycloak既定のAccess Token Lifespan）で必ず失効する。より長いセッションが必要になった場合の再検討事項をarchitecture.mdに記録した
- 複数レプリカ化する場合、セッション暗号鍵がPod内生成でレプリカ間共有されないため、同一セッションが別レプリカに当たると復号に失敗する（現状replicas: 1のため顕在化しない）。将来の検討事項としてarchitecture.mdに記録した
