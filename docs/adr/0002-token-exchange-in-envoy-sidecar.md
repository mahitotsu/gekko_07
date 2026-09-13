# ADR 0002: Token Exchange実装をEnvoyサイドカー（ext_authz）に配置

- **Status**: Accepted
- **Date**: 2026-09-13

## Context

gekko_05の[ADR 0002](https://github.com/example/gekko_05/blob/main/docs/adr/0002-token-exchange-in-application-layer.md)（同名・別リポジトリ）では、Token Exchangeを各サービスのアプリケーション本体に実装し、Envoy等のプロキシへは委譲しないと決定していた。理由はRFC 8693の意味論を学習目的でコードとして直接見せるためであり、当時の目的（Token Exchangeの学習）には合致していた。

gekko_07では目的が変わり、「サービス実装言語に依存しない横断的関心事として、Token Exchangeを1箇所に集約できる」というサイドカー方式の価値を実演したい。加えて、gekko_05では言語ごとに同じRFC 8693クライアントロジックを重複実装していた（`TokenExchangeClient.java`/`tokenexchange.go`/`token_exchange.rs`等）。

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

- gekko_05で発生した「言語ごとのRFC 8693クライアント重複実装」が発生しない
- サイドカー方式そのものの検証コストが増える（Envoy bootstrap設定、ext_authzサービスの実装、Kubernetesマニフェスト）。1ホップで先行検証してから残りのホップへ横展開する方針とする（backlog.md参照）
- アプリ層でのDPoP検証（gekko_05ではfrontend接点のみに適用）を今回もアプリ層に残すかサイドカー側に寄せるかは未決定（backlog.md参照）
