# ドキュメント運用ルール

`docs/`配下には目的の異なる複数のドキュメントがある。個々のファイルは自分の役割を冒頭で自己申告しているが、ファイルをまたいだ整合性維持の手順はどこにも書かれていなかった（[ADR 0016](docs/adr/0016-ext-authz-and-keycloak-mtls.md)が、後発のADR 0017/0022で決定を覆されたにもかかわらずStatus更新が漏れたまま放置されていた実例がある）。本ファイルはその手順を明文化する。

2026-09-20、ファイル分割そのものが同種の食い違いを誘発していたと判断し（ADR 0016のStatus漏れ、DPoPの知見が複数文書に独立して重複していた実例、ドキュメント地図の順序不一致を同一セッションで3件発見）、access-control-requirements.md/access-control-design.md/use-cases.md/backlog.mdをrequirements.md/architecture.mdへ統合した（arc42方式：横断的関心事・実行時シナリオ・リスクは独立文書ではなく1つのアーキテクチャ文書の章）。以下はその結果の構造。

## ドキュメント地図と役割分担

| ファイル | 役割 |
|---|---|
| [docs/prfaq.md](docs/prfaq.md) | 対象読者は誰で、どんな課題を解決し、どんな利益を提供するか（Working Backwards形式のPR/FAQ）。詳細はrequirements.md以下へ委譲する一枚の入口 |
| [docs/requirements.md](docs/requirements.md) | 何を・なぜ実現するか（目的・背景・要求水準）。誰が何をできて何をできてはいけないかという業務要件（BR番号、§「業務要件（アクセス制御）」）を含む |
| [docs/architecture.md](docs/architecture.md) | **現在有効な**アーキテクチャの断面。経緯や過去の選択肢は書かず、ADRへのリンクに委譲する。業務要件をどう実現するかのディシジョンテーブル（§6）、実行時シナリオ（§10）、既知の制約・未着手事項（§11）を含む |
| [docs/adr/](docs/adr/) | architecture.mdの個々の決定の根拠・選択肢・結論（1決定＝1ファイル、追記専用）。本文を上書きする権威は持たない。[docs/adr/README.md](docs/adr/README.md)にテーマ別索引がある |
| [docs/services.md](docs/services.md) | 各サービスの存在意義・提供機能・保有データの参照カタログ（他文書から引かれる索引であり、通読する核ではない） |
| [docs/insights.md](docs/insights.md) | 実装・実機検証で見つかった罠や仕様（症状/原因/対応）。設計判断そのものは書かない。核の物語には属さない運用ログ |

## 文書の依存関係と優先順位

核となる文書は「why（何を・なぜ、業務要件を含む）→ how（どう実現するか、ディシジョンテーブル・実行時シナリオ・既知の制約を含む）」の一直線。

```
prfaq.md（最も抽象・最も変わらない）
  │
requirements.md（業務要件を含む）
  │
architecture.md（ディシジョンテーブル§6・実行時シナリオ§10・既知の制約§11を含む）
  │   参照カタログ: services.md
  ▼
証跡: adr/（architecture.mdの決定根拠。追記専用、本文を上書きしない。テーマ別索引はadr/README.md）
運用ログ（核の外、随時参照）: insights.md（実機の罠）
```

記述内容が矛盾した場合、上位が下位を規定する：

**prfaq.md > requirements.md > architecture.md > services.md**

adr/はarchitecture.mdの決定根拠を記録するだけで、本文を上書きする権威は持たない（Statusの更新のみで対応する。下記「記載粒度の使い分け」参照）。

## 記載粒度の使い分け

- **prfaq.md**：対象読者・課題・提供価値そのものが変わったときだけ更新する。個々の設計判断や実装の変更では更新しない（それらはADR/architecture.mdへ）。
- **architecture.md・services.md（reference系）**：「今どうなっているか」だけを書く。「当初〜だったが〜になった」「〜済み」「全廃した」「移行した」のような経緯・変化を語る表現（journey narrative）は書かない。それらは既に該当ADRのContext/Decision/Consequencesに書いてあるはずのものであり、無ければADR側に書く。追記するときは必ず「これは現在の事実か、それとも変化の記述か」を自問し、後者なら該当ADRへ差し戻す。
- **docs/adr/NNNN-*.md**：一度Acceptedにした後のContext/Decision本文は書き換えない（歴史記録として保持）。決定が変わった場合はStatus行と、必要ならConsequencesへの追記だけで対応する。例外として、ドキュメント再編で参照先ファイルが移動・統合された場合の**リンク先パスの更新**は、決定の書き換えに当たらないため許可する（文言・reasoning・Statusは変更しない）。詳細な運用ルールは下記「ADR運用ルール」を参照。
- **architecture.md §11（既知の制約・未着手事項）**：「未着手・未決定」のみを列挙する。着手したらその場で項目を削除し、結果はarchitecture.mdの該当章/services.md/insights.mdのいずれかへ記録する。未決事項の判断材料となる実機知見・調査結果が既にinsights.mdやADRにあるなら、それを再掲せずポインタで済ませる（判断すべき問いそのものだけをここに書く）。
- **insights.md**：設計判断ではなく、実装中に踏んだ罠・実機で判明した仕様上の制約を「症状/原因/対応」の型で記録する。ただし対象が完全に撤去・置き換え済みの機構（過去に導入し後日撤去したもの）の場合、その知見は再検討時のみ価値を持つため、architecture.md §11から参照される形に留め、§11側に同じ内容を再掲しない。

## ADR運用ルール

ADRは運用ルールを定めないまま蓄積を始めたため、2026-09-20の全31本の棚卸で以下の実例が見つかった（詳細は各ADR自身のStatus行に残してある。本文は書き換えていない）。

- **Status更新漏れ（3件）**：ADR 0010がADR 0002の宛先指定方式（`localhost:<port>`→実サービス名+`hostAliases`）を変更したが0002のStatusは未更新のままだった。ADR 0014が`Amends`宣言付きでADR 0010のegressパターン③④を廃止したが0010のStatusは未更新のままだった。いずれも「新しいADRを書いた人が、影響を受ける旧ADRを漏れなく見つけて更新する」ことを記憶だけに依存しており、機械的に強制されていなかったことが根本原因
- **テンプレート逸脱（3件）**：ADR 0006・0028・0030が`## Context`/`## Decision`/`## Consequences`以外のH2見出しを持っていた（Decision配下の一部がH3ではなくH2に昇格していた）
- **本文の内部矛盾（1件）**：ADR 0007に、後で置き換わったサービス名（`payment-service`。ADR 0011でfraud-detection-engineに置換済み）が1箇所残っていた
- **表記ゆれ（1件）**：ADR 0013のStatus行だけ他と異なるリンク表記（`[ADR 0015]`、他は`[0015]`）だった

以下はこれらの再発を防ぐための、次回以降のADR作成・修正時に**必ず実行する**ルール。

### テンプレート（MUST）

ADRのH2見出しは`## Context`・`## Decision`・`## Consequences`の3つのみとする。検討した選択肢の詳細・新規サブトピック等、他に書きたい内容は`## Decision`配下のH3以下として書く。全ADRが同じ形で走査可能であることを保つ。

確認コマンド（出力が空であること。`docs/adr/README.md`は索引でありADRではないため対象外）：
```
grep -n "^## " docs/adr/[0-9]*.md | grep -vE "(Context|Decision|Consequences)$"
```

### 他のADRへの言及ルール（MUST）

ある変更が過去のAccepted ADRの**Decision sectionに書かれた決定そのもの**を変える場合、次の3点を**同じコミットで**行う。

1. 新しいADRのStatus行の直後に`- **Amends**: [NNNN](NNNN-slug.md)（変更範囲を一言で）`を追加する
2. 変更対象の旧ADRのStatus行を`Partially superseded by [NNNN](NNNN-slug.md)（何が・なぜ覆ったか、有効なまま残る部分は何か）`に更新する。旧ADRのContext/Decision本文は書き換えない
3. 旧ADR本文中に訂正箇所がある場合は`〔[ADR NNNN](NNNN-slug.md)で訂正/追加/削除〕`という統一形式のインライン注記を該当箇所に添える（Status行を読まず本文だけ読む読者にも伝わるようにするため）

**Decision内容を変えない訂正**（例示に使った固有名詞の言い換え、typo等）はStatus更新の対象外。ただし判断に迷う場合は安全側（Status更新する）に倒す。

新しいADRを書き終えたら必ず以下を実行し、出力された各参照先ADRのStatus行が実際に更新されているかを確認する：
```
grep -n "^\- \*\*Amends\*\*" docs/adr/[0-9]*.md
grep -no "〔\[\?ADR [0-9]\{4\}[^〕]*〕" docs/adr/[0-9]*.md
```

### ADR番号の表記統一（MUST）

- Status行で他のADRを参照する場合：`[NNNN](NNNN-slug.md)`（"ADR"は書かない）
- Context/Decision/Consequences本文中で参照する場合：`[ADR NNNN](NNNN-slug.md)`（文中に埋め込むため"ADR"を明示する）

### 実装ADR（1サービスの本実装をまとめて扱うもの）の粒度

account-service本実装（0026）のように1回の実装作業で複数の設計判断が同時に生じる場合、無理に複数のADRへ分割しない（人工的な細分化は追跡コストを増やすだけ）。ただし上記テンプレートは維持し、Decision配下をH3で主題ごとに区切る。Consequencesには、この実装によって更新した他文書（architecture.mdの該当章・services.md等）を具体的に列挙し、下記「文書修正時の横断確認ルール」で実際に反映されたかを検証できるようにする。

## 文書修正時の横断確認ルール

**docs/配下のいずれかのファイルを修正するセッションでは、コミット前に必ず「他の文書に修正要否があるか」を確認する。** 修正して満足した文書だけを見て終わらない。文書は互いに参照し合っており、片方だけ直すと反対側が古いまま残る（ADR 0016の実例：ADR 0022でKeycloakの9000ポートの決定を変えた際、同じ決定に触れていたADR 0016の更新だけが漏れた）。

手順：

1. 変更したキーワード・設定名・サービス名で`grep -rln "<キーワード>" docs/ CLAUDE.md`を実行し、同じ内容に触れている全ファイルを洗い出す（1箇所とは限らない。ADR本文中の一文に埋もれているケースもある）
2. ヒットした各ファイルについて、今回の変更後も記述が正しいか確認する。特に以下の組み合わせに注意する：
   - **ADR同士**：手順・確認コマンドは上記「ADR運用ルール」を参照
   - **ADR→architecture.md**：ADRの決定が変わったら、architecture.mdの対応箇所（現在有効な断面）も同じ内容に書き換える
   - **architecture.md §11→ADR/services.md/insights.md**：§11の項目に着手・解消した場合、その項目を削除し、結果をarchitecture.mdの該当章/services.md/insights.mdのいずれかに記録する。逆に、ADRやarchitecture.mdの他章の変更で§11の既存項目が解消された場合も、§11側の削除を忘れない
   - **k8s/等の実装→docs全般**：`k8s/`配下の変更を伴う場合は、docsをAccepted/現在有効扱いにする前に`make verify-hop`（または該当するmakeターゲット）で実機確認し、その実装に言及しているADR/architecture.md/insights.mdの記述が古くなっていないか確認する
3. 修正が必要な文書が見つかった場合は後回しにせず、その場で同じコミットに含める
