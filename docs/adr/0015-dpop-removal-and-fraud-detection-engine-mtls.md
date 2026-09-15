# ADR 0015: DPoPを撤去し、SPIRE mTLSをfraud-detection-engine→account-serviceへ横展開する

- **Status**: Accepted
- **Date**: 2026-09-16

## Context

[ADR 0013](0013-dpop-sender-constraining.md)でfraud-mcp-server→account-serviceの1ホップにDPoP(RFC 9449)を実装・実機検証した。実装自体は正しく動作したが、その価値を検討し直した結果、以下の判断に至った。

### DPoPの実利がmTLSと大きく重複する

このホップは既に[ADR 0012](0012-spiffe-spire-mtls-single-hop.md)でSPIRE mTLSを導入しており、`match_typed_subject_alt_names`でfraud-mcp-server自身のSPIFFE IDにのみ接続を限定している。この状態で、盗まれたトークンを別の場所から再提示しようとしても、その別の場所がfraud-mcp-server自身のSPIRE証明書を持っていない限り、DPoPの検証に到達する前にmTLSハンドシェイクの時点で拒否される。DPoPが追加で守る範囲は、「fraud-mcp-serverの信頼境界の中には侵入しているが、ext-authz-serviceが保持するDPoP鍵そのものには触れていない」という極めて狭いシナリオに限られ、投資に見合う実利が乏しいと判断した。

### 「拘束のスロットは委任チェーンに1箇所だけ」という制約

ADR 0013の実機検証で、Token ExchangeにおけるDPoP拘束は以下の性質を持つことが判明した。

- subject_tokenに既存の拘束が無い場合、要求者は自分の鍵で新しく拘束できる(成功)
- subject_tokenに既存の拘束がある場合、要求者が異なるクライアント・異なる鍵で再拘束しようとするとKeycloakに拒否される(`400: Sender-constrained token exchange rejected as the token was not issued for the requesting client`)

このため、DPoP拘束は委任チェーン全体でどこか1箇所、しかも後続で再exchangeされることの無い終端ホップにしか設定できない。今回のfraud-mcp-server→account-serviceがこのスロットを使うと、将来account-service→analyst-attribute-serviceへDPoPを拡張することはできなくなる。DPoPが本来最も効果を発揮するのはmTLSで守られていないfrontend方向(ブラウザ〜frontend間、SPIFFE IDを持てない)だが、frontendへの適用もこの制約により限定的にしかできず(ADR 0013 Consequences参照)、frontend自体が未実装のため現時点では検証すらできない。

以上を踏まえ、**今回のホップ限定でのDPoP導入は「メカニズムの実証」以上の意味を持たせにくい**という結論に至った。

## Decision

**ADR 0013で導入したDPoP関連の実装を撤去し、代わりにSPIRE mTLS(ADR 0012)をfraud-detection-engine→account-serviceへ横展開する。**

新しいメカニズム(DPoP)をもう1つ抱えるより、既に動作実績のある1つのメカニズム(SPIRE mTLS)を使い回す方が、プロジェクト全体の複雑さが増えない。また、fraud-detection-engine→account-serviceは[ADR 0012](0012-spiffe-spire-mtls-single-hop.md)が「既知の限界」として残していたplaintext受け口そのものであり、SPIRE化によってこの限界も同時に解消できる。

### 撤去した実装

- `ext-authz-service`のDPoP proof生成ロジック(`DPOP_ENABLED`分岐、`ecdsa`依存、起動時pip install、readinessProbe)
- `dpop-verifier`サービス一式(`k8s/dpop-verifier/`)
- account-serviceのingress Envoyに追加していた第2の`ext_authz`フィルタ・`dpop_verifier_cluster`・jwt_authnの`from_headers`(DPoPスキーム)上書き
- fraud-mcp-serverのegress Envoyの`allowed_upstream_headers`への`dpop`パターン追加
- Keycloakの`fraud-mcp-server`クライアントの`dpop.bound.access.tokens`属性
- `scripts/verify-hop.sh`のDPoP関連の正常系/異常系チェック

### 追加した実装(fraud-detection-engineのSPIRE化)

- fraud-detection-engineのEnvoyサイドカーに、fraud-mcp-serverと全く同じ構成(SPIRE Workload API向けSDSチャネル、`account_service_upstream`クラスタへのmTLS+ALPN h2のtransport_socket、`node`識別子)を追加
- fraud-detection-engineのDeploymentに、SPIRE Agent Workload APIソケットのhostPathマウントを追加(Envoyコンテナのみ)
- SPIRE registration entryをfraud-detection-engineのEnvoyコンテナ向けに追加(`k8s:container-name:envoy`セレクタ、他2エントリと同型)
- **account-serviceのingress Envoyを、TLS/plaintextの2つのfilter_chainから単一のmTLS必須filter_chainへ統合し直した**。`match_typed_subject_alt_names`にfraud-detection-engineのSPIFFE IDを追加し、fraud-mcp-server・fraud-detection-engine双方からの接続を許可する。`tls_inspector`リスナーフィルタ・`filter_chain_match`によるTLS/plaintext振り分けは不要になったため削除した

## Consequences

- account-serviceへのplaintextでの到達経路が完全に無くなった。ADR 0012 Consequencesが残していた既知の限界(「account-serviceへのplaintext到達経路の残存」)は解消された
- account-serviceの呼び出し元は全てSPIRE発行のSPIFFE IDを持つワークロードに限定される。今後account-serviceへ新しい呼び出し元を追加する場合、SPIRE registration entryの追加とmTLS対応が前提になる
- DPoPの実機検証結果(ADR 0013)自体は無駄にはならない。Token ExchangeとDPoP拘束の相互作用(「拘束のスロットは1つ、終端ホップのみ」)という知見は、将来frontendが実装されてDPoPを再検討する際の判断材料としてbacklog.mdに残す
- `ext-authz-service`はDPoP関連の依存(`ecdsa`のpip install)が無くなり、再び純粋な標準ライブラリのみの実装に戻った
