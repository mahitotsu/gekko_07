# ADR 0002: Token Exchange実装をEnvoyサイドカー（ext_authz）に配置

- **Status**: Partially superseded by [0010](0010-egress-listener-granularity.md)（egressの宛先指定を`localhost:<egressポート>`から実サービス名＋`hostAliases`へ変更。「アプリ本体にToken Exchangeのコードを持たせない」というコアの決定は有効なまま）
- **Date**: 2026-09-13

## Context

Token Exchangeロジックの置き場として、各サービスのアプリケーション本体に実装するか、Envoy等のサイドカープロキシに委譲するかを検討した。

アプリケーション本体に実装する場合、RFC 8693の意味論がコードとして直接見えるという利点はあるが、サービスの実装言語ごとに同じToken Exchangeクライアントロジック（トークンエンドポイントへの`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`呼び出し、レスポンス解釈、エラーハンドリング）を重複実装することになる。今回は複数言語でサービスを実装する方針（requirements.md参照）のため、この重複が顕在化しやすい。

Envoyでの実現方式として以下を検討した。

| 手段 | 評価 |
|---|---|
| `envoy.filters.http.oauth2` | Authorization Codeフロー専用。RFC 8693 Token Exchange grantには非対応 |
| `envoy.filters.http.lua` | 実装は可能だが、セキュリティクリティカルなロジックをEnvoy設定に埋め込むLuaに置くのはテスト・可読性の面で筋が悪い |
| WASMフィルタ自作 | ビルド環境（Rust/TinyGo→wasm）が要り、ext_authzで足りる要件に対して明らかにオーバーエンジニアリング |
| C++ネイティブフィルタ自作 | Envoy本体の再ビルドが必要。今回の規模では正当化できない |
| **`envoy.filters.http.ext_authz`（採用）** | 普通のHTTPサーバーを1つ書くだけで実現できる。言語自由 |

## Decision

**各サービスのEnvoyサイドカーの`ext_authz`（HTTPモード）から呼ばれる外部サービスとしてToken Exchangeを実装する**。アプリケーション本体には一切Token Exchangeのコードを持たせない。

- 各サービスのPodに、アプリコンテナ＋Envoyサイドカー（ext_authz設定込み）を同居させる
- ext_authzが呼ぶ外部サービスは、受信したAuthorizationヘッダーを`subject_token`としてKeycloakに`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`を叩き、交換後トークンを新しい`Authorization`ヘッダーとして返す
- アプリは次ホップの呼び出し先を`localhost:<egressポート>`宛てに叩くだけで、認可ヘッダーの中身を一切意識しない

## Consequences

- サービスの実装言語ごとのToken Exchangeクライアント重複実装が発生しない
- サイドカー方式そのものの検証コストが増える（Envoy bootstrap設定、ext_authzサービスの実装、Kubernetesマニフェスト）。1ホップで先行検証してから残りのホップへ横展開する方針とする（architecture.md参照）
- アプリ層でのDPoP検証をアプリ層に残すかサイドカー側に寄せるかは未決定（architecture.md参照）
