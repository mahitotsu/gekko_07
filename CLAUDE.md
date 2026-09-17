# ドキュメント運用ルール

`docs/`配下には目的の異なる複数のドキュメントがある。個々のファイルは自分の役割を冒頭で自己申告しているが、ファイルをまたいだ整合性維持の手順はどこにも書かれていなかった（[ADR 0016](docs/adr/0016-ext-authz-and-keycloak-mtls.md)が、後発のADR 0017/0022で決定を覆されたにもかかわらずStatus更新が漏れたまま放置されていた実例がある）。本ファイルはその手順を明文化する。

## ドキュメント地図と役割分担

| ファイル | 役割 |
|---|---|
| [docs/requirements.md](docs/requirements.md) | 何を・なぜ実現するか（目的・背景・要求水準） |
| [docs/access-control-requirements.md](docs/access-control-requirements.md) | 誰が何をできて何をできてはいけないかという業務要件（BR番号） |
| [docs/access-control-design.md](docs/access-control-design.md) | 業務要件をどう実現するかのディシジョンテーブル（認証トークンの内容を含む） |
| [docs/architecture.md](docs/architecture.md) | **現在有効な**アーキテクチャの断面のみ。経緯や過去の選択肢は書かない |
| [docs/adr/](docs/adr/) | 個々の設計判断の根拠・選択肢・結論（1決定＝1ファイル、追記専用） |
| [docs/services.md](docs/services.md) | 各サービスの存在意義・提供機能・保有データ |
| [docs/use-cases.md](docs/use-cases.md) | 具体的な業務シナリオ |
| [docs/backlog.md](docs/backlog.md) | **未着手**の改善項目・未決定事項のみ |
| [docs/insights.md](docs/insights.md) | 実装・実機検証で見つかった罠や仕様（症状/原因/対応）。設計判断そのものは書かない |

## 記載粒度の使い分け

- **architecture.md**：現在有効な結論だけを書く。「なぜそうなったか」はADRへのリンクに委譲し、経緯そのものは書き込まない。
- **docs/adr/NNNN-*.md**：一度Acceptedにした後のContext/Decision本文は書き換えない（歴史記録として保持）。決定が変わった場合はStatus行と、必要ならConsequencesへの追記だけで対応する。
- **backlog.md**：「未着手・未決定」のみを列挙する。着手したらその場で項目を削除し、結果はarchitecture.md/services.md/insights.mdのいずれかへ記録する。
- **insights.md**：設計判断ではなく、実装中に踏んだ罠・実機で判明した仕様上の制約を「症状/原因/対応」の型で記録する。

## 更新タイミングの原則（横断的整合性）

**新しいADRが過去のAccepted ADRの決定を変更・撤回する場合、影響を受けた旧ADR全てのStatusを同じコミットで`Partially/Fully superseded by NNNN`に更新する。** 旧ADR本文（Context/Decision）は書き換えず、Status行と該当するConsequences箇条書きへの短い注記だけで対応する。

手順：

1. 変更しようとしている設定・決定について、`grep -rn "<キーワード>" docs/adr/`でそれを最初に決めたADR、および同じ設定に後から触れた全てのADRを洗い出す（1箇所だけとは限らない。ADR 0016のように「本文中の一文」として埋もれているケースがある）
2. 見つかった旧ADR全てのStatus行を更新し、何がどう変わったかをConsequencesに1〜2行追記する
3. architecture.md・backlog.md・insights.mdの該当箇所も同じコミットで更新する（backlog.mdで「将来の課題」として言及されていた項目が解消された場合は、backlog.mdではなく言及元のADR側にも解消済みである旨を残す）
4. `k8s/`配下の変更を伴う場合は、docsをAccepted扱いにする前に`make verify-hop`（または該当するmakeターゲット）で実機確認する
