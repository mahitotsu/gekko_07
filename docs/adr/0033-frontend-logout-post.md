# ADR 0033: frontendのログアウト(end_session_endpoint)へのid_token_hint送信をPOSTに変更する

- **Status**: Accepted
- **Amends**: [0032](0032-frontend-oidc-callback-form-post.md)（ログアウトを「form_postの対象外」として現状維持とした判断を訂正し、POST方式で対応する）
- **Date**: 2026-09-21

## Context

[ADR 0032](0032-frontend-oidc-callback-form-post.md)は、ログアウト時に`id_token`本体が`end_session_endpoint`のクエリパラメータ（`id_token_hint`）としてブラウザのアドレスバー・履歴に露出する点について、(a) `id_token`は`aud=frontend`専用でAPI呼び出しには使えない、(b) 5分で失効する、の2点を理由に対応を見送った。

レビューで「5分あれば十分悪用できるのではないか」という指摘を受け、この判断根拠を洗い直した。有効期限の短さは緩和策の一つではあるが、URL露出（ブラウザ履歴・プロキシ/CDNのアクセスログ・共有端末での閲覧等）から悪用までに必要な時間は数秒〜数十秒のオーダーであり得るため、「短命だから対応不要」という結論は不十分だった。

改めてOpenID Connect RP-Initiated Logout 1.0の仕様を確認したところ、ADR 0032の「form_postはあくまで認可エンドポイントの応答にのみ存在する概念で、ログアウトには適用対象が無い」という認識自体が誤りだった。実際には以下の2つの独立した緩和策が仕様で定義されている。

1. **`end_session_endpoint`自体がPOSTメソッドをサポートする**：仕様は「OpenID ProviderはHTTP GET/POST双方をLogout Endpointでサポートしなければならない（MUST）。POSTの場合はForm Serialization（`application/x-www-form-urlencoded`のbody）でパラメータを渡す」と定めている。**POSTを推奨する理由として仕様が明記しているのが、まさに`id_token_hint`がWebサーバーのアクセスログに残ることを防ぐため**であり、今回の懸念にそのまま合致する。Keycloakもこのformベースのログアウトをサポートしている（実機で確認済み）
2. **`id_token_hint`の代わりに`client_id`パラメータを使う**：`id_token`自体を保持・送信しない設計にできる。ただしOPは「`id_token_hint`が無い場合、post-logout-redirectの正当性を確認する他の手段が無い限りリダイレクトしてはならない」ことになっており、Keycloak（19以降、26.2以降は仕様によりstrict化）は`id_token_hint`が無いと「ログアウトしますか」という確認画面を挟む。実機で確認したところ、これは`post_logout_redirect_uri`を指定していても発生し、UXの後退になる

2つの案を比較し、**id_token_hintは保持したままPOSTで送る（案1）**を採用した。id_tokenが持つ「OPに対して正当なログアウト要求であることを示す」役割を維持しつつ、URL露出という当初の懸念だけを解消できるため、確認画面という追加コストを払う理由が無い。

## Decision

### `server/routes/logout.post.ts`をGETリダイレクトから自動送信フォームのPOSTへ変更する

`server/routes/callback.get.ts`がresponse_mode=form_postの着地点として自動送信フォームを受け取る側だったのと対称に、今度は`/logout`自身が送信側になる。`sendRedirect(event, endSessionUrl, 302)`（`id_token_hint`・`post_logout_redirect_uri`をクエリ文字列に含む）を廃止し、代わりに`Content-Type: text/html`のページを返す。ページ本体は`<body onload="document.forms[0].submit()">`の中に`<form method="POST" action=".../logout">`を置き、`id_token_hint`・`post_logout_redirect_uri`を隠しinputのvalueとして埋め込む（JavaScript無効時のフォールバックとして`<noscript>`に送信ボタンを用意する）。

`id_token`はJWTのcompact serialization（RFC 7519）であり、base64urlアルファベットと`.`のみで構成されるためHTML属性値として安全に埋め込めるが、防御的にHTMLエスケープ（`&`・`"`）を行っている。

`end_session_endpoint`自体のURLはクエリパラメータを持たないベースURLのみになる（`http://localhost:3000/realms/gekko/protocol/openid-connect/logout`）。

### Referrer-Policy: no-referrerを明示する

このページ自体は外部リソースを一切読み込まないため実害は無いが、Keycloak自身の各種ページが`Referrer-Policy: no-referrer`を送っている慣行に倣い、防御的に同じヘッダーを設定した。

### `client_id`方式は不採用のまま記録する

上記Context参照。将来Keycloakや構成が変わり確認画面を回避できる条件が整理された場合は再検討の余地があるが、現時点では優位性が無い。

## Consequences

- ログアウト時、`id_token`がブラウザのアドレスバー・履歴・アクセスログのいずれにも露出しなくなった（実機確認：`/logout`のレスポンス自体も遷移先URLもクエリ文字列を持たない）
- Keycloak側のSSOセッションが実際に終了することを実機で確認した（ログアウト後に`/login`へ戻ると自動再認可ではなく実際のユーザー名/パスワード入力フォームが表示される）
- [ADR 0032](0032-frontend-oidc-callback-form-post.md)の「ログアウトは対応対象外」という判断・その根拠（有効期限の短さ、form_postの適用範囲の誤認）を訂正した。Statusを更新し、該当箇所にインライン注記を追加した
