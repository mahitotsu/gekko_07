# アーキテクチャ決定記録（ADR）

本ディレクトリは、設計判断1件ごとの根拠・選択経緯を記録する。[architecture.md](../architecture.md) は現在有効な設計断面のみを記載し、個々の判断の根拠はここに委譲する。

決定が覆った場合は、旧ADRのStatusを`Superseded by NNNN`に更新し、新しいADRを追加する。

## 一覧

| # | タイトル | Status |
|---|---|---|
| [0001](0001-scenario-fraud-detection-with-agent-assist.md) | シナリオにAIエージェント支援付き金融不正検知・口座凍結を採用 | Accepted |
| [0002](0002-token-exchange-in-envoy-sidecar.md) | Token Exchange実装をEnvoyサイドカー（ext_authz）に配置 | Accepted |
| [0003](0003-k3d-without-istio.md) | ローカル実行基盤にk3d（Istioは当面不採用）を採用 | Accepted |
| [0004](0004-external-access-via-port-forward.md) | 外部公開はIngressではなくkubectl port-forwardで行う | Accepted |
| [0005](0005-single-audience-tokens-only.md) | トークンは常に単一audienceのみを持つ | Accepted |
| [0006](0006-claim-vs-external-attribute-criteria.md) | トークンのクレームにするか業務データとして外部化するかの判断基準 | Accepted |
| [0007](0007-per-service-language-selection.md) | 各サービスの実装言語・フレームワークの選定 | Accepted |
| [0008](0008-per-service-datastore-strategy.md) | サービスごとのデータストア戦略 | Accepted |
