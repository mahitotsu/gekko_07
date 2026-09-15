# アーキテクチャ決定記録（ADR）

本ディレクトリは、設計判断1件ごとの根拠・選択経緯を記録する。[architecture.md](../architecture.md) は現在有効な設計断面のみを記載し、個々の判断の根拠はここに委譲する。

決定が覆った場合は、旧ADRのStatusを`Superseded by NNNN`に更新し、新しいADRを追加する。

## 一覧

| # | タイトル | Status |
|---|---|---|
| [0001](0001-scenario-fraud-detection-with-agent-assist.md) | シナリオにAIエージェント支援付き金融不正検知・口座凍結を採用 | Superseded by 0011 |
| [0002](0002-token-exchange-in-envoy-sidecar.md) | Token Exchange実装をEnvoyサイドカー（ext_authz）に配置 | Accepted |
| [0003](0003-k3d-without-istio.md) | ローカル実行基盤にk3d（Istioは当面不採用）を採用 | Accepted |
| [0004](0004-external-access-via-port-forward.md) | 外部公開はIngressではなくkubectl port-forwardで行う | Accepted |
| [0005](0005-single-audience-tokens-only.md) | トークンは常に単一audienceのみを持つ | Accepted |
| [0006](0006-claim-vs-external-attribute-criteria.md) | トークンのクレームにするか業務データとして外部化するかの判断基準 | Accepted |
| [0007](0007-per-service-language-selection.md) | 各サービスの実装言語・フレームワークの選定 | Accepted |
| [0008](0008-per-service-datastore-strategy.md) | サービスごとのデータストア戦略（Keycloakを含む） | Accepted |
| [0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md) | Envoy ingress側の責務範囲とバイパス防止 | Accepted |
| [0010](0010-egress-listener-granularity.md) | egressは実サービス名への透過的な呼び出しとし、audienceはHostヘッダーから自動導出する | Accepted |
| [0011](0011-scenario-ai-assisted-unfreeze.md) | シナリオを「AI支援による口座凍結解除」に変更（凍結は自動検知エンジンが実行） | Accepted |
| [0012](0012-spiffe-spire-mtls-single-hop.md) | fraud-mcp-server→account-serviceの1ホップにSPIFFE/SPIREでmTLSを導入する | Accepted |
| [0013](0013-dpop-sender-constraining.md) | fraud-mcp-server→account-serviceの1ホップにDPoPでトークン送信者拘束を導入する | Superseded by 0015 |
| [0014](0014-fraud-agent-token-exchange.md) | fraud-agent→fraud-mcp-serverをToken Exchangeに変更し、frontendの事前トークン取得（パターン④）を廃止する | Accepted |
| [0015](0015-dpop-removal-and-fraud-detection-engine-mtls.md) | DPoPを撤去し、SPIRE mTLSをfraud-detection-engine→account-serviceへ横展開する | Accepted |
