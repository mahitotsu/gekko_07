# ADR 0007: 各サービスの実装言語・フレームワークの選定

- **Status**: Accepted
- **Date**: 2026-09-13

## Context

[requirements.md](../requirements.md)「背景（なぜサイドカーへ切り出すか）」の通り、Token Exchangeをアプリケーション本体からEnvoyサイドカーへ切り出す価値は、サービス群の実装言語がバラバラな構成でこそ際立つ。そのため方針として多言語構成を採るが、これは「バラバラにすること自体」が目的ではなく、各サービスの役割に照らして技術選定の理由が説明できることが前提になる（無理に言語を割り振ってサイドカーの実演価値を損なっては本末転倒）。

## Decision

| サービス | 技術スタック | 選定理由 |
|---|---|---|
| frontend（BFF） | TypeScript / Nuxt.js | BFFとして必要な要素（サーバー側のOAuthフロー・セッション管理・チャット/ダッシュボードUIの配信）を1つのアプリで完結できる。Nuxtのサーバールート（Nitro）がBFF層、Vueがフロントエンド層を兼ねる。日本国内での採用実績・人材プールが厚く、学習用サンプルとしても再現しやすい |
| fraud-agent | TypeScript / Claude Agent SDK | Claude Agent SDKはPython/TypeScript両方で提供され機能差がないため、機能面での決め手はない。MCPサーバー接続（`mcpServers`設定）がSDK組み込みで完結し、エージェント本体に認可まわりのロジックを一切持たせずに済む。frontendと同じNode.jsランタイムに揃えることを優先した選択（下記「フロントエンド系2サービスの言語重複について」参照） |
| fraud-mcp-server | Python / FastMCP | MCPサーバー構築に特化したPythonの高レベルフレームワーク（`@mcp.tool()`デコレータでツール定義）で、公式SDKを直接使うよりボイラープレートが少ない。account-serviceへの中継はI/Oバウンドな処理が中心で、Pythonの非同期HTTPクライアント（httpx等）で十分こなせる |
| fraud-detection-engine | Rust / Axum | 薄いロジックを高頻度・低レイテンシで捌く役割に適所（詳細は下記「fraud-detection-engineのRust選定について」） |
| account-service（主役） | Java / Spring Boot | 表5のABAC判定など今回最も複雑な業務ロジックを持つ中核サービス。型安全性・テスト資産（JUnit5、Testcontainers等）・エンタープライズでの実績の厚さを優先。認可判定のような「間違えると業務影響が大きいロジック」を書く場所として手堅い選択 |
| analyst-attribute-service | Go（標準ライブラリ`net/http`） | 単一エンドポイントの属性照会のみで役割が最小。フレームワークを持ち込む理由がないため標準ライブラリのみで済ませる。ビルドが速くコンテナイメージも小さく、「委任チェーンの終端」という地味な役割に見合う軽量さ |

### フロントエンド系2サービスの言語重複について

frontendとfraud-agentは両方ともTypeScriptだが、これは「6言語ユニークな構成を手放した」わけではない。fraud-agent・fraud-mcp-serverはいずれも固有の理由（Claude Agent SDK、公式MCP SDKの充実度）でPython/TypeScriptの2択に絞られており、他の言語を選ぶ積極的な理由がない。この2サービスの候補プールが最初からPython/TypeScriptの2つしかない以上、3つ目のサービス（frontend）がどちらかと被るのはほぼ避けられない。

ここでPHPやRubyのように候補プールに入っていない言語を持ち込んで被りを回避することも考えられるが、それは「diversityの数字を揃えるためだけの選択」であり、このADRの前提（無理に言語を割り振ってサイドカーの実演価値を損なっては本末転倒）に反する。frontendの言語は独立した理由（Nuxt.js、国内での定番であること）で決めており、その結果がfraud-agentと同じTypeScriptになったのは、候補プールの構造上ほぼ必然の帰結であって、多様性を犠牲にした妥協ではない。多様性はfraud-mcp-server（Python）・fraud-detection-engine（Rust）・account-service（Java）・analyst-attribute-service（Go）を含む4言語構成で十分に示されている。

### fraud-detection-engineのRust選定について

「Rustの型安全性が生きる複雑な業務ロジックがあるか」という軸で評価すると、凍結の実処理自体はaccount-serviceに委譲するためfraud-detection-engine自体の業務ロジック（検知ルールの適用判定）は薄く、この軸では決め手にならない。しかし評価すべき軸はそちらではない。fraud-detection-engineに求められているのは**大量の取引をリアルタイムでスコアリングし、薄いロジックを高頻度・低レイテンシで捌くこと**であり、この軸で見るとRustは妥当、というよりむしろ適所である（[ADR 0011](0011-scenario-ai-assisted-unfreeze.md)によりpayment-serviceからfraud-detection-engineに役割が置き換わったが、この評価軸自体はより強く当てはまる）。

- **エコシステムの薄さは欠点にならない**：Spring/JVMエコシステムの厚み（ORM、DI、アノテーション処理系）は複雑なドメインモデリングに強みを発揮するが、薄いロジックのサービスにはそもそも不要な道具立てである。逆にfraud-detection-engineが必要とする要素（HTTPサーバー、シリアライズ、下流へのHTTPクライアント）はAxum/Tokio/serde/reqwestで既に十分成熟しており、エコシステムの狭さが不利に働く場面がない
- **GCを持たないことが直接効く**：複雑な状態遷移の型安全性より、大量の薄いリクエストを処理する際にレイテンシのばらつきが出ないことの方が、このサービスの実利に近い
- **呼び出し頻度の観点でも妥当**：実運用を想定すれば、fraud-detection-engineは全ての取引をリアルタイムでスコアリングする経路であり6サービス中最も呼び出し頻度が高くなり得る。「薄いロジック×高頻度」という特性への適性で選ぶなら、同じく薄い役割だが呼び出し頻度が低いanalyst-attribute-service（account-serviceからの内部照会のみ）よりも、fraud-detection-engineに配置する方が理にかなっている
- **副次的な理由**：`serde`によるシリアライズ時の型チェックと、しきい値・スコアを生の数値ではなくニュートン型（newtype）で表現することで、単位の取り違えや浮動小数点誤差といった検知ロジックで典型的なバグをコンパイル時に防げる副次的な利点もある

（旧版のこのADRでは「payment-serviceとanalyst-attribute-serviceを入れ替えた方が一貫する」という代替案を提示していたが、上記の呼び出し頻度の観点から的外れだったため撤回した。その後[ADR 0011](0011-scenario-ai-assisted-unfreeze.md)によりpayment-service自体がfraud-detection-engineに置き換わったが、Rust/Axumという選定と上記の評価軸は変わらず有効なため、本ADRはSupersededにせず本文を書き換える形で更新した）

## Consequences

- 言語は5種類（TypeScript, Python, Rust, Java, Go）だが、サービスは6つあるためビルド・Lint/テスト設定・CI導線は6サービス分それぞれ別に用意する必要がある（同じTypeScriptのfrontend/fraud-agentも別アプリとして別々に管理する）。これは多言語構成という目的自体が要求するコストであり、実装が進む中で負担が大きいと判明した場合は本ADRを見直す
- 6サービスの言語は5種類（TypeScript, Python, Rust, Java, Go）で、TypeScriptのみ2サービス（frontend, fraud-agent）が使う。これは候補プールの構造上の必然であり、無理に6言語目を持ち込んで揃えることはしない（詳細は上記「フロントエンド系2サービスの言語重複について」）
- 特定サービスの言語を後から変更する場合は、このADRのStatusを`Superseded by NNNN`にし、新しいADRを追加する（[docs/adr/README.md](README.md)の運用ルールに従う）
