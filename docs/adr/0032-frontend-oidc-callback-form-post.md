# ADR 0032: frontendのOIDCコールバックをresponse_mode=form_postへ変更し、認可コード・stateのURL露出を無くす

- **Status**: Accepted
- **Amends**: [0031](0031-frontend-implementation.md)（`/callback`をGET→POST(form_post)化。`/callback`（GET）に触れた記述の訂正はADR 0031本文の該当箇所参照）
- **Date**: 2026-09-21

## Context

デモ画面のレビューで、ログイン成功直後・ログアウト時にブラウザのアドレスバーへ`client_id`・`redirect_uri`・`code_challenge`・`state`・`nonce`等が並んだ長いURLが表示されることが問題視された。値そのもの（`code_challenge`はcode_verifierからの一方向ハッシュ、`state`/`nonce`はCSRF/リプレイ対策トークンで、いずれもRFC 7636上URLに露出して問題ない値）は秘密ではないが、アドレスバーに表示された値はリロード・戻る/進む・お気に入り登録のいずれの経路でもブラウザ履歴・場合によってはサーバーのアクセスログやRefererヘッダーに残り得るという指摘は妥当だった。

実際に調べ直すと、`/login`→Keycloak認可エンドポイントの初回リダイレクト（`client_id`等、非秘密値のみ）はOAuth 2.0 Authorization Codeフローの前段リクエストとして本質的に避けられない（GET以外の手段でブラウザから認可エンドポイントへ遷移する標準的な方法がない。Google/Microsoft等主要IdPも同型のURLを使う）。一方、Keycloakから`/callback`への応答（既定のresponse_mode=query）は**認可コードそのもの**をURLクエリ文字列で返しており、こちらは事情が異なる。認可コードは単発使用でPKCEにより単独では悪用できないとはいえ、[RFC 9700（OAuth 2.0 Security Best Current Practice）§4.1.2](https://www.rfc-editor.org/rfc/rfc9700)はブラウザ履歴・Refererヘッダー経由の認可コード露出をリスクとして挙げ、緩和策として`response_mode=form_post`（[OAuth 2.0 Form Post Response Mode](https://openid.net/specs/oauth-v2-form-post-response-mode-1_0.html)）の利用を推奨している。Keycloakはこのresponse_modeを追加設定無しでサポートしている（実機で確認済み）。

`scripts/verify-hop.sh`の`login_via_frontend()`はKeycloakログインフォームPOST後の302 Locationヘッダーから`code`/`state`を抽出する実装だったため、form_post化（200+自動送信フォーム）でそのまま壊れることが判明した。

## Decision

### `server/routes/login.get.ts`にresponse_mode=form_postを追加する

認可リクエストの`searchParams`に`response_mode=form_post`を追加した。認可リクエスト自体（`/login`→Keycloak）の非秘密パラメータ群には変更を加えていない。

### `/callback`をPOST専用にし、GETはfail-closeの入り口として残す

`server/routes/callback.get.ts`と`callback.post.ts`に分割した。

- `callback.post.ts`：実際のOIDCコールバック処理本体。旧`callback.get.ts`のロジック（PKCE state検証・token-exchangeサイドカーへの委譲・id_token検証）をそのまま移し、`getQuery()`ではなく`readBody()`でPOST body（`code`・`state`・`session_state`・`iss`）を読む
- `callback.get.ts`：ブックマーク・戻る/進む・リロード等で古い`/callback` URLへ迷い込んだ場合の受け皿。form_post採用後、正規のフローがGETでここへ来ることは無い（stateはgekko_pkce Cookie=10分TTLと既に一致しないか、codeは使用済みのいずれかで成立し得ない）ため、中身を見ずに`/login?error=1`へfail closeする

`server/middleware/1.auth.ts`は元々POSTメソッドを素通りする実装のため変更不要だった。

### `scripts/verify-hop.sh`の`login_via_frontend()`をform_post対応に書き換える

Keycloakのログインフォームpost後の応答が302→200(自動送信フォーム)に変わったため、`keycloak_login_redirect()`（Locationヘッダー方式、`raw_login_token()`が引き続き使用）とは別に`keycloak_login_form_post()`を新設した。ログインフォームPOST後の応答ボディから`<FORM METHOD="POST" ACTION="...">`と隠しinput（`code`・`state`・`session_state`・`iss`）を抽出し、そのまま`/callback`へPOSTすることでブラウザの`onload="document.forms[0].submit()"`を代替する。`login_via_frontend()`はこれを呼ぶだけの薄い実装に変更した。

### ログアウト（`id_token_hint`）はform_postの対象外のまま残す

OIDC RP-Initiated Logoutの仕様上、`id_token_hint`はKeycloakの`end_session_endpoint`への**開始**リダイレクトのクエリパラメータとして送る以外の手段が定義されておらず、form_postはあくまで認可エンドポイントの**応答**（response_mode）にのみ存在する概念のため、そもそも適用対象にならない。`id_token`自体は`aud=frontend`専用でaccount-service/fraud-agent等のAPI呼び出しには使えず（BFFパターン、ADR 0031）、5分で失効するため、ブラウザ履歴に残るリスクは限定的と判断し、追加対応は見送った。

## Consequences

- ログイン成功後、ブラウザのアドレスバー・履歴に認可コード・stateが残らなくなった（実機確認：`/callback`は常にPOSTで到達し、最終的な着地点`/dashboard`のURLにクエリは一切付かない）
- `/callback`へのGETアクセス（ブックマーク・戻る/進む・リロード等の再訪）は常に`/login?error=1`へfail closeするようになった
- `/login`→Keycloak認可エンドポイントの初回リダイレクトに残る`client_id`・`redirect_uri`・`code_challenge`・`state`・`nonce`は、OAuth標準の前段リクエストとして引き続きURLに現れる（値自体は非秘密であり、主要IdPも同型のURLを使う。RFC 9700もこの部分の秘匿は要求していない）
- ログアウト時の`id_token_hint`は引き続きクエリパラメータとして露出する。OIDC仕様上の代替手段が無く、露出するid_token自体のリスクも限定的なため現状維持とした
- `scripts/verify-hop.sh`を更新し、`make verify-hop`で全ステップ（ログイン含む）が成功することを実機確認した
