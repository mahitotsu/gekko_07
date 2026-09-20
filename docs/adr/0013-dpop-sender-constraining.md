# ADR 0013: fraud-mcp-server→account-serviceの1ホップにDPoPでトークン送信者拘束を導入する

- **Status**: Superseded by [0015](0015-dpop-removal-and-fraud-detection-engine-mtls.md)
- **Date**: 2026-09-16

**訂正(2026-09-16)**: 本ADRで導入したDPoPは、実装・実機検証の直後にADR 0015で撤去した。理由は、このホップが既にSPIRE mTLS(ADR 0012)で呼び出し元の身元を限定済みのため、DPoPが追加で守る範囲がmTLSと大きく重複し実利が乏しい一方、「拘束のスロットは委任チェーンに1箇所(終端ホップ)だけ」という制約(本ADR内で実機検証済み)だけが今後の横展開の足かせとして残ったため。本ADRの実機検証結果(Token Exchangeを跨いだDPoP拘束の挙動)自体は、将来DPoPを再検討する際に有効な知見として残す。撤去の詳細・代替判断はADR 0015を参照。

## Context

[ADR 0012](0012-spiffe-spire-mtls-single-hop.md)はfraud-mcp-server↔account-serviceの1ホップにSPIREでmTLSを導入したが、トークン送信者拘束(R6)は未解決のまま残した。RFC 8705(mTLS拘束アクセストークン)を検討したが、Keycloak 26.7.0の`client-x509`認証がSPIRE発行証明書のURI SAN(SPIFFE ID)を一切見ず、Subject DNしか照合できないという製品上の制約により断念した(解消にはSPIRE側の非標準的な証明書カスタマイズか、Dockerfileを書かない方針を初めて破るKeycloakカスタムSPIプラグインが要る)。代わりにDPoP(RFC 9449)を採用する。DPoPはトークンをmTLS接続の同一性ではなく署名鍵にバインドするため、`ext-authz-service`という第三者プロセスがKeycloakとのやり取りを代行する現アーキテクチャとも構造的に両立する。

### Keycloak 26.7.0でのDPoPサポート(実機ソース確認済み)

DPoPはKeycloak 26.4でGA(デフォルト有効、機能フラグ不要)。クライアント属性`dpop.bound.access.tokens: "true"`で有効化する。ヘッダー名は`DPoP`、アクセストークン提示時のAuthorizationスキームは`Bearer`ではなく`DPoP`になる。`ath`クレームはリソースエンドポイントへの提示時のみ必須(トークンエンドポイント自体への提示では不要)。DPoP nonceはKeycloakサーバー側で未実装(2026年9月時点でissue #39042がopenのまま)。

### 決定的な実機検証結果:DPoPは委任チェーンの「最後のクライアント」でのみ有効化できる

Token Exchangeを跨いでDPoP拘束がどう振る舞うかを2パターンで実機検証した。

**パターンA(採用): subject_tokenに既存の拘束が無い場合** — frontendが交換した(DPoP無効の)トークンを、fraud-mcp-server自身のクライアント(`dpop.bound.access.tokens=true`)が別の鍵でTokenExchangeし直すと、subject_tokenのazpがfrontendのままでも、**fraud-mcp-server自身の鍵で新しく拘束された**トークンが発行される(200、`cnf.jkt`あり)。これは「拘束を引き継ぐ」のではなく、新しい保有者が要求の瞬間に自分の鍵で改めて証明する、という正しい送信者拘束の動作である。

**パターンB(検証したが不採用): subject_tokenに既存の拘束がある場合** — 仮にfrontendのクライアントにも`dpop.bound.access.tokens=true`を設定し、frontend自身の鍵でDPoP拘束済みのトークンを発行させた上で、fraud-mcp-serverが**別の鍵**でそれを再交換しようとすると、Keycloakは`400 invalid_request: "Sender-constrained token exchange rejected as the token was not issued for the requesting client"`で**exchangeそのものを拒否する**。これはKeycloakの「自己再交換は同一クライアント・同一鍵でなければならない」という制約(subject_tokenが既に拘束されている場合にのみ働く)によるもので、Keycloak issue #51205(delegation/actor tokenとの衝突。26.7.0に対して提出済み・未解決)が指摘する状況そのものである。

**この2つの実機結果から導かれる帰結**: このプロジェクトの委任チェーン設計(1つのトークンを複数ホップでexchangeし続ける方式)では、**後続でさらに再exchangeされることが無い、チェーンの最後のクライアントだけがDPoP拘束を安全に有効化できる**。frontendがfraud-mcp-server向けに発行するトークンは後続でfraud-mcp-serverが再exchangeするため、frontendのクライアントでDPoPを有効化するとその再exchangeそのものが壊れる。したがって今回fraud-mcp-server→account-serviceのみにDPoPを導入したのは、暫定的なパイロット選定ではなく、**このアーキテクチャでDPoPを安全に有効化できる唯一の位置**である。frontendが将来実装されても、frontend→fraud-mcp-server向けのexchangeにDPoPを追加することはできない(frontend→account-serviceへの直接exchange、pattern②の確定パスのように、それ自体が委任チェーンの終端となるexchangeであれば話は別)。

## Decision

**fraud-mcp-server(ext-authz-service)↔account-serviceの1ホップに、DPoP(RFC 9449)によるトークン送信者拘束を導入する。**

### 設計

- **Keycloak**: `fraud-mcp-server`クライアントの`attributes`に`dpop.bound.access.tokens: "true"`を追加([k8s/keycloak/realm-configmap.yaml](../../k8s/keycloak/realm-configmap.yaml))
- **Proof生成はEnvoyではなくext-authz-serviceに置く**: [ADR 0002](0002-token-exchange-in-envoy-sidecar.md)の「セキュリティクリティカルなロジックをLua/Envoy設定に埋め込まない」という原則をDPoPにも適用する。ext-authz-serviceは既にHost/Path/Methodを見てToken Exchangeを行っているため、同じ場所でES256鍵ペア(Pod起動ごとの使い捨て。ADR 0009の合言葉トークンと同じ簡略化パターン)を保持し、①Keycloakへの自分のexchangeリクエスト用proof、②実際にaccount-serviceへ転送する個別リクエスト用proof(`htm`/`htu`はその具体的なリクエスト、`ath`は交換後トークンのハッシュ)、の2つを都度作る。Python標準ライブラリにEC署名が無いため、`ecdsa`(純Python、コンパイル不要)を起動時にpip installする(Dockerfileは書かない方針を維持)
- **Proof検証は新しい`dpop-verifier`サービスに置く**: account-serviceのアプリ本体・Envoy Luaのどちらにも検証ロジックを持たせない(前者は既存の「アプリはEnvoyが検証済みのものだけ信頼する」原則、後者はADR 0002の原則)。ext-authz-serviceと同型の共有サービス([k8s/dpop-verifier/](../../k8s/dpop-verifier/))を新設し、account-serviceのingress Envoy(mTLS必須のfilter_chainのみ)で`jwt_authn`の後段・`rbac`の前段に第2の`ext_authz`フィルタとして配線する。`jwt_authn`が既に署名検証済みのAuthorizationヘッダーを自前で再デコードして`cnf.jkt`を取り出し(署名の再検証はしない)、DPoPヘッダーのproof(JWK thumbprint一致・`htm`/`htu`/`iat`window/`ath`)を照合する。`cnf`が無いトークン(fraud-detection-engine等、DPoP対象外の呼び出し元)はそのままALLOWする
- **jwt_authnの`from_headers`をDPoPスキームに切り替え**: DPoP拘束されたトークンはAuthorizationスキームが`Bearer`ではなく`DPoP`になる(RFC 9449)。account-serviceのTLS filter_chain(fraud-mcp-server専用)のjwt_authnにのみ`from_headers: [{name: Authorization, value_prefix: "DPoP "}]`を設定する。plaintext filter_chain(fraud-detection-engine用)は既定の`Bearer`のままで変更しない
- **jtiのリプレイキャッシュは持たない**(デモ規模の簡略化。architecture.md参照)

## Consequences

- fraud-mcp-server→account-serviceのホップは、mTLS(通信路の身元検証)とDPoP(トークン自体の送信者拘束)という独立した2つの層で守られる
- **frontendへの横展開は不可能ではないが、frontend→fraud-mcp-server向けのexchangeには適用できない**(上記の実機検証結果参照)。frontend→account-serviceへの直接exchange(pattern②、確定パス)のように、それ自体がチェーンの終端となる呼び出しであれば別途検証が要る
- `ext-authz-service`・`dpop-verifier`ともに`pip install ecdsa`を起動時に行うため、readinessProbeが無いとEnvoyのext_authzが起動直後の数秒間`connection refused`を受けてfail closeする(`failure_mode_allow: false`のため403)。実機検証で判明し、両Deploymentに`readinessProbe`(TCP、port 8080)を追加して解消した
- 実機検証で判明した個別の設定ミス(3件)はinsights.mdに記録: ①`dpop.bound.access.tokens`・`standard.token.exchange.enabled`の正確なキー名、②DPoP proof検証時のjwt_authn `from_headers`切り替えの必要性、③起動レースによる403
