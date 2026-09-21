# アーキテクチャ決定記録（ADR）

本ディレクトリは、設計判断1件ごとの根拠・選択経緯を記録する。[architecture.md](../architecture.md) は現在有効な設計断面のみを記載し、個々の判断の根拠はここに委譲する。

決定が覆った場合は、旧ADRのStatusを`Superseded by NNNN`に更新し、新しいADRを追加する。36件のうち24件は今も覆っていないAccepted——後続ADRによる修正は「シナリオ選定（凍結解除の確定操作の精緻化）」「Token Exchangeの実行主体・宛先指定」「身元検証（mTLS/SPIFFE/SPIRE）」「frontendの本実装内での段階的置き換え」の4テーマに偏っており、乱発しているわけではない。以下はテーマ別の索引。同じテーマのADRを続けて読むと、1つの関心事がどう変遷したかを追いやすい。

## シナリオ選定

| # | タイトル | Status |
|---|---|---|
| [0001](0001-scenario-fraud-detection-with-agent-assist.md) | シナリオにAIエージェント支援付き金融不正検知・口座凍結を採用 | Superseded by 0011 |
| [0011](0011-scenario-ai-assisted-unfreeze.md) | シナリオを「AI支援による口座凍結解除」に変更（凍結は自動検知エンジンが実行） | Partially superseded by 0036 |
| [0036](0036-unfreeze-proposal-approval-step.md) | 凍結解除提案に承認/却下の状態遷移を導入し、確定操作を精緻化 | Accepted |

## Token Exchangeの実装方式（サイドカー集約・トークン設計原則）

| # | タイトル | Status |
|---|---|---|
| [0002](0002-token-exchange-in-envoy-sidecar.md) | Token Exchange実装をEnvoyサイドカー（ext_authz）に配置 | Partially superseded by 0010 |
| [0005](0005-single-audience-tokens-only.md) | トークンは常に単一audienceのみを持つ | Accepted |
| [0006](0006-claim-vs-external-attribute-criteria.md) | トークンのクレームにするか業務データとして外部化するかの判断基準 | Accepted |
| [0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md) | Envoy ingress側の責務範囲とバイパス防止 | Accepted |
| [0010](0010-egress-listener-granularity.md) | egressは実サービス名への透過的な呼び出しとし、audienceはHostヘッダーから自動導出する | Partially superseded by 0014 |
| [0014](0014-fraud-agent-token-exchange.md) | fraud-agent→fraud-mcp-serverをToken Exchangeに変更し、frontendの事前トークン取得（パターン④）を廃止する | Accepted |

## 身元検証・mTLS・SPIFFE/SPIRE・DPoPの変遷

この一連の流れは「共有ext-authz-serviceが呼び出し元のclient_secretを代理保持する」設計（0002/0016）の身元検証ギャップに0019〜0021で気づき、各呼び出し元自身のPod内サイドカー＋SPIRE JWT-SVIDへ移行した経緯。0013→0015はDPoPを試験導入した後、mTLSとの重複を理由に撤去した経緯（知見は[insights.md](../insights.md)「DPoP送信者拘束」節）。

| # | タイトル | Status |
|---|---|---|
| [0012](0012-spiffe-spire-mtls-single-hop.md) | fraud-mcp-server→account-serviceの1ホップにSPIFFE/SPIREでmTLSを導入する | Accepted |
| [0013](0013-dpop-sender-constraining.md) | fraud-mcp-server→account-serviceの1ホップにDPoPでトークン送信者拘束を導入する | Superseded by 0015 |
| [0015](0015-dpop-removal-and-fraud-detection-engine-mtls.md) | DPoPを撤去し、SPIRE mTLSをfraud-detection-engine→account-serviceへ横展開する | Accepted |
| [0016](0016-ext-authz-and-keycloak-mtls.md) | SPIRE mTLSをext-authz-service(-cc)・Keycloakへ拡張する | Partially superseded by 0017/0019/0020/0021/0022 |
| [0017](0017-edge-proxy-full-keycloak-mtls.md) | edge-proxyを導入し、Keycloakを完全mTLS化する | Accepted |
| [0019](0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md) | ext-authz-serviceの身元検証ギャップを解消し、fraud-mcp-server→account-serviceをSPIFFE JWT-SVIDクライアント認証へ移行する | Accepted |
| [0020](0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md) | fraud-detection-engineの身元検証ギャップを解消し、client_credentialsグラントもSPIFFE JWT-SVIDクライアント認証へ移行する | Accepted |
| [0021](0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md) | account-service→analyst-attribute-service(表3)をSPIFFE JWT-SVIDクライアント認証で実装する | Accepted |
| [0028](0028-postgres-mtls-tcp-proxy.md) | 共有PostgresインスタンスへのアクセスをEnvoyのtcp_proxyでmTLS化する | Accepted |

## NetworkPolicy・到達制御

| # | タイトル | Status |
|---|---|---|
| [0018](0018-network-policy-default-deny.md) | gekko namespaceにNetworkPolicyでL3/4のdefault-denyを導入する | Partially superseded by 0022/0028/0030 |
| [0022](0022-keycloak-mgmt-probe-exec.md) | Keycloakのkubelet向けhttp-mgmt(9000)をexecプローブ化してloopback限定にする | Accepted |

## 監査

| # | タイトル | Status |
|---|---|---|
| [0025](0025-audit-log-aggregation.md) | 監査ログ集約基盤（Alloy+otel-lgtm）を導入し、監査（BR8）の実現方式を再設計する | Accepted |

## ローカル実行基盤

| # | タイトル | Status |
|---|---|---|
| [0003](0003-k3d-without-istio.md) | ローカル実行基盤にk3d（Istioは当面不採用）を採用 | Accepted |
| [0004](0004-external-access-via-port-forward.md) | 外部公開はIngressではなくkubectl port-forwardで行う | Accepted |

## 技術選定・データ基盤

| # | タイトル | Status |
|---|---|---|
| [0007](0007-per-service-language-selection.md) | 各サービスの実装言語・フレームワークの選定 | Accepted |
| [0008](0008-per-service-datastore-strategy.md) | サービスごとのデータストア戦略（Keycloakを含む） | Accepted |
| [0035](0035-keycloak-optimized-build.md) | Keycloakを事前ビルド済みイメージ(`kc.sh build`)で`start --optimized`起動する | Accepted |

## 各サービスの本実装

| # | タイトル | Status |
|---|---|---|
| [0023](0023-fraud-agent-fraud-mcp-server-hop.md) | fraud-agentを新規実装し、fraud-mcp-serverのingressを活性化する | Accepted |
| [0024](0024-frontend-edge-proxy-and-simplified-login.md) | frontendを新規実装し、edge-proxy配線・簡易ログインでaccount-service/fraud-agentへ横展開する | Partially superseded by 0031 |
| [0026](0026-account-service-analyst-attribute-service-implementation.md) | account-service・analyst-attribute-serviceを本実装し、ビルド・配布パイプラインを新設する | Partially superseded by 0027 |
| [0027](0027-fraud-detection-engine-implementation.md) | fraud-detection-engineを本実装し、デモ用凍結データの発生源をaccount-serviceのシードから切り替える | Accepted |
| [0029](0029-fraud-mcp-server-implementation.md) | fraud-mcp-serverを本実装し、account-serviceの読み取り・提案系機能をMCPツールとして公開する | Accepted |
| [0030](0030-fraud-agent-implementation.md) | fraud-agentを本実装し、Anthropic API向けに初めてのクラスタ外egressを設ける | Accepted |
| [0031](0031-frontend-implementation.md) | frontendを本実装し、簡易ログイン(ROPC)を本物のAuthorization Code + PKCEへ置き換える | Partially superseded by 0032 |
| [0032](0032-frontend-oidc-callback-form-post.md) | frontendのOIDCコールバックをresponse_mode=form_postへ変更し、認可コード・stateのURL露出を無くす | Partially superseded by 0033 |
| [0033](0033-frontend-logout-post.md) | frontendのログアウト(end_session_endpoint)へのid_token_hint送信をPOSTに変更する | Accepted |
| [0034](0034-frontend-display-username-instead-of-sub.md) | ログイン表示をKeycloakのsub(UUID)からpreferred_username(ログインに使った文字列)に変更する | Accepted |
