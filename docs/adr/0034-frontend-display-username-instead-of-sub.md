# ADR 0034: ログイン表示をKeycloakのsub(UUID)からpreferred_username(ログインに使った文字列)に変更する

- **Status**: Accepted
- **Amends**: [0031](0031-frontend-implementation.md)（`layouts/authenticated.vue`のヘッダー表示をsub表示からusername表示に変更）
- **Date**: 2026-09-21

## Context

[ADR 0031](0031-frontend-implementation.md)で実装したデモ画面ヘッダーには「〜としてログイン中」という表示があるが、そこに出していたのはKeycloakが発行するid_tokenの`sub`クレーム、すなわちKeycloak内部のユーザーUUIDだった。ログイン自体には`yamada-analyst`等の読める`username`を使っているにもかかわらず、画面にはそれと無関係なUUIDが出るため、デモとして誰がログインしているのか分かりにくいという指摘があった。

[docs/architecture.md](../architecture.md) §11には元々「標準client scope（profile/email/roles等）の要否：`--import-realm`での直接importでは自動生成されないため現状未定義。ログイントークンに`preferred_username`等が必要になった時点でclientScopesに明示定義を追加する」という未着手事項が記録されていた。今回がその「必要になった時点」にあたる。

## Decision

### id_tokenに`preferred_username`クレームを追加する専用protocol mapperを足す。標準`profile`スコープは導入しない

[ADR 0025](0025-audit-log-aggregation.md)の監査ログ集約作業で判明した通り、`--import-realm`での直接importではKeycloak標準の`profile`/`email`/`roles`等のbuilt-in client scopeは自動生成されない（`k8s/keycloak/realm-configmap.yaml`のコメント参照）。今回必要なのは`preferred_username`一つだけであり、`profile`スコープ全体（`name`・`given_name`・`locale`等、他に使わないクレームを多数含む）を再構築するのはオーバースペックと判断した。

代わりに、既存の`subject-claim`マッパー（`sub`をアクセストークンへ明示的に乗せるためにADR 0025で追加した、`oidc-usermodel-property-mapper`によるdedicated protocol mapper）と同じ手法で、`preferred-username-claim`という専用マッパーをfrontendクライアントに追加した（`k8s/keycloak/realm-configmap.yaml`）。`user.attribute: username`→`claim.name: preferred_username`、`id.token.claim: true`（`sub`と異なり`preferred_username`はOIDC Coreのid_token必須クレームではなく標準では乗らないため、`subject-claim`とは逆に`id.token.claim`側を`true`にする）。

### frontendのセッション・`/me`レスポンス・画面表示をsubからusernameへ差し替える

- `server/utils/jwks.ts`の`verifyIdToken()`：`payload.preferred_username`を検証・抽出し`VerifiedIdentity.username`として返す。`sub`同様、文字列でなければ検証失敗としてfail closeする
- `server/utils/session.ts`の`Session`：`username`フィールドを追加する（`sub`は委任チェーンの追跡キーとして引き続き必要なため保持する）
- `server/routes/callback.post.ts`：`identity.username`をセッションに保存する
- `server/routes/me.get.ts`：レスポンスを`{ sub }`から`{ username }`へ変更する（画面表示以外にこのレスポンスを消費する箇所が無いことを確認済み）
- `layouts/authenticated.vue`：`{{ me.username }} としてログイン中`に変更する

## Consequences

- ダッシュボード・チャット画面ヘッダーに、ログインに使った`username`（例: `yamada-analyst`）が表示されるようになった。KeycloakのUUID（`sub`）は画面上には一切出さない
- [docs/architecture.md](../architecture.md) §6「認証（アナリストのログイントークン）」の表に`preferred_username`クレームの行を追加した
- [docs/architecture.md](../architecture.md) §11の「標準client scope（profile/email/roles等）の要否」は`preferred_username`単体については本ADRで解消した旨を追記した（`profile`スコープ自体の要否は他のクレームが必要にならない限り未定義のまま残る）
- [ADR 0031](0031-frontend-implementation.md)の`layouts/authenticated.vue`に関する記述（「ログイン中のsub表示」）を本ADRが上書きするため、同ADRのStatus行を更新した
