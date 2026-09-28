# 3. スコープと audience で「構造的に」権限を封じる

> 対象読者：[第 2 章](02-token-exchange.md)で「交換の可否は認可サーバーが決める」を理解した方。
> この章のねらい：AI エージェントに実行権限を「渡さない」を、アプリの `if` 文ではなく認可サーバーの設定で成り立たせる、という考え方を一緒に見ていきます。業務担当の方に「なぜ大丈夫と言えるのか」をお伝えするうえで、いちばん大事な章です。

## 3.1 「権限を絞ったつもり」が本当に絞れているか

AI エージェントに社内 API を触らせるとき、多くの方が同じ不安を持たれます。「読み取りと提案だけを許して、実行はさせないつもりだけれど、本当にそうなっているのだろうか」というものです。

素朴な実装は、エージェントのコードに次のように書きます。

```
if (操作 === "凍結解除の実行") {
  throw new Error("エージェントは実行できません");
}
```

これでも動きはしますが、正直に申し上げると、少し心もとない守り方です。この `if` 文にバグがあったり、あるいはプロンプトインジェクションでエージェントが想定外の経路を通ったりすれば、チェックはすり抜けられてしまいます。**「エージェントのコードが正しく書かれている」という前提の上にしか、安全が成り立たない**からです。コードレビューでいくら確認しても、「絶対に実行できない」という確信までは持ちにくいところです。

そこでこの章では、これをコードの外——**認可サーバー（Keycloak）の設定そのもの**——で成り立たせる方法を見ていきます。エージェントのコードにどんなバグがあっても、**そもそも実行系のトークンを取得する経路が存在しない**なら、実行できないはずです。この「経路が存在しない」を設定として作り込むのが、この章のテーマです。

## 3.2 鍵は「Token Exchange の可否」

[第 2 章](02-token-exchange.md)で見たとおり、あるサービスが次のサービスを呼ぶには Token Exchange が必要で、その可否は Keycloak が判定します。ということは、**「この audience・この scope への交換は許さない」と Keycloak に設定しておけば、その権限のトークンは物理的に手に入らない**、ということになります。

このサンプルの考え方を一言でまとめると、次のようになります。

> **AI エージェント（fraud-agent / fraud-mcp-server）が持てるどのトークンにも、`account:unfreeze`（凍結解除の実行）スコープを取得する経路を、Keycloak の設定上つくらない。**

エージェントが「解除すべきだ」とどれだけ強く提案しても、凍結解除 API を呼べるトークンをそもそも交換で得られません。ですから実行できません。アプリの分岐ではなく、認可のレイヤーで封じる、という形です（[docs/requirements.md](../docs/requirements.md) BR5）。

## 3.3 部品①：スコープは 1 つの audience だけを指す

Keycloak では、クライアント（frontend や fraud-agent など）に「クライアントスコープ」を割り当てます。このサンプルでは、各クライアントスコープが**対象とする audience をちょうど 1 つだけ**指すように設計しています（`oidc-audience-mapper`。[ADR 0046](../docs/adr/0046-account-read-audience-scope-split.md)）。

たとえば `fraud-agent:read` というスコープは「audience = fraud-agent」を指します。`account:read` は「audience = account-service」を指します。スコープと audience が 1 対 1 で結びついている、とお考えください。

ここで Keycloak の重要な挙動が効いてきます。**要求元クライアントが、その audience を指すスコープを持っていない場合、その audience への Token Exchange を要求すると、Keycloak 自身が拒否します**（エラー：`Requested audience not available`）。つまり「どの audience へ交換できるか」は、そのクライアントに割り当てたスコープの集合で決まります。

## 3.4 部品②：スコープの割り当てが「委任トポロジー」になる

ですから、**各クライアントにどのスコープを割り当てるか**を設計することが、そのまま「誰が誰を呼べるか」という**委任トポロジーの設計**になります。このサンプルのスコープ割り当てを抜粋します（[docs/architecture.md](../docs/architecture.md) §4）。

| スコープ | 対象 audience | このスコープを**割り当てるクライアント** | 意味 |
|---|---|---|---|
| `fraud-agent:read` | fraud-agent | **frontend のみ** | AI とのチャット開始（委任チェーンの入口） |
| `fraud-mcp-server:read` | fraud-mcp-server | **fraud-agent のみ** | MCP ツール呼び出し |
| `account:read` | account-service | frontend, fraud-mcp-server | 口座・取引の読み取り |
| `account:propose` | account-service | **fraud-mcp-server のみ** | 凍結解除の提案（取り消せる・低リスク） |
| `account:unfreeze` | account-service | **frontend のみ** | 凍結解除の実行・承認・却下（取り消せない・高リスク） |

この表を「誰が何へ交換できるか」として読むと、委任の地図になります。

- frontend は `fraud-agent:read` を持つ → fraud-agent へ交換できる（AI にチャットを頼める）
- fraud-agent は `fraud-mcp-server:read` を持つ → fraud-mcp-server へ交換できる
- fraud-mcp-server は `account:read`・`account:propose` を持つ → account-service へ「読み取り」「提案」の交換ができる
- **`account:unfreeze` は frontend にしか割り当てられていない**

最後の一行が要になります。fraud-agent にも fraud-mcp-server にも `account:unfreeze` は一切割り当てません。ですから AI エージェント側の経路には、凍結解除を実行できるトークンを生む交換が**どこにも存在しない**、という状態になります。

## 3.5 なぜ「ホップ飛ばし」もできないのか

「AI がずるをして、途中を飛ばして直接 account-service を呼べば通ってしまうのでは」という疑問が湧くかもしれません。ここも同じ仕組みで防がれています。

fraud-agent が持つスコープは `fraud-mcp-server:read` **だけ**です。account-service を指すスコープ（`account:read` など）は持っていません。ですから fraud-agent が「audience=account-service で交換してほしい」と Keycloak に要求しても、`Requested audience not available` で拒否されます。fraud-agent が account-service へ到達する唯一の道は、正規のルート（fraud-mcp-server 経由）だけです（[docs/architecture.md](../docs/architecture.md) 表1）。

各ホップは「自分宛てのトークンだけを `subject_token` にして、自分に割り当てられたスコープの範囲でしか次へ交換できない」ようになっています。この積み重ねで、委任チェーンの形そのものが Keycloak の設定に固定されます。**経路は、設定として存在するものだけ**であり、コードで経路を増やしたり飛ばしたりはできません。

## 3.6 スコープの検証はどこで行うか

もう一つ、「渡した先で本当にスコープが効いているか」も大切です。このサンプルでは、届いたトークンのスコープ検証を、**アプリのコードの外——Envoy サイドカーの受信側（ingress の `rbac` フィルタ）**で行っています（[docs/architecture.md](../docs/architecture.md) §3.4・表2）。account-service の場合は、次のようになります。

- `GET /accounts/**` には `account:read` が必要
- `POST /accounts/{id}/unfreeze` には `account:unfreeze` が必要

このチェックは、アプリに入る前に Envoy が済ませます。仮にアプリ内で追加のチェックをする場合も、必ずリクエストの入口（業務ロジックに入る前）でのみ行い、ビジネスロジックの途中には置かないようにしています（理由は [ADR 0006](../docs/adr/0006-claim-vs-external-attribute-criteria.md)）。「スコープの検証」という横断的な関心事を、アプリの奥深くに散らばらせない、という考え方です。

## 3.7 二重の封じ込め

ここまでを整理すると、AI エージェントの実行権限は**二重に**封じられています。

1. **トークンを取得できない**（発行側）：fraud-agent / fraud-mcp-server には、`account:unfreeze` へ交換できるスコープが割り当てられていません。Keycloak が交換要求を拒否します
2. **仮にトークンがあっても弾かれる**（検証側）：account-service の Envoy が、凍結解除 API には `account:unfreeze` を要求します。持っていなければ拒否します

そして、そもそも凍結解除 API を呼べるトークン（`account:unfreeze`）を発行できるのは frontend だけです。frontend がそれを使うのは、アナリストが画面で「承認」「凍結解除を確定」といった**明示的なボタン操作**をしたときに限られます（[第 4 章](04-ai-agent-identity.md)、[docs/requirements.md](../docs/requirements.md) BR6）。

この形の良いところは、確認のしやすさです。「AI は実行できないか」を確かめるのに、AI のコードを読む必要がありません。**Keycloak のクライアント設定で `account:unfreeze` の割り当て先を見れば、frontend にしか付いていないことが確認できます**。安全の根拠が、レビューしにくいアプリのコードから、宣言的で見通しのよい認可サーバーの設定へ移っている、とお考えいただくと分かりやすいと思います。

## 3.8 この章のまとめ

- AI に実行させない、を `if` 文だけで守るのは心もとない面があります。このサンプルは**認可サーバーの設定**で、実行系トークンを取得する経路そのものを無くしています
- Keycloak では**スコープが 1 つの audience を指し**、そのスコープを持たない audience への Token Exchange は拒否されます（[ADR 0046](../docs/adr/0046-account-read-audience-scope-split.md)）
- だからこそ**各クライアントへのスコープ割り当てが、そのまま委任トポロジー**になります。`account:unfreeze` を frontend にしか割り当てないことで、AI 経路に実行権限が流れないようにしています（[docs/architecture.md](../docs/architecture.md) §4）
- ホップ飛ばしも、スコープを持たない audience へは交換できないため、行えません
- 発行側（交換できない）と検証側（Envoy の scope チェック）で、二重に封じています
- 安全の根拠が、レビューしにくいコードから、確認しやすい認可サーバーの設定へ移ります

次章では、この封じ込めの前提となる「AI エージェントはそもそもどうやって『田中さんの代理』という身元を持つのか」と、最後の砦である「人間の確定操作」「事後の監査」を扱います。

## gekko_07 ではどう確かめたか

- スコープと委任トポロジーの設計：[docs/architecture.md](../docs/architecture.md) §4、audience 間の交換可否（表1）・account-service のスコープ別可否（表2）
- スコープを 1 audience に分離した経緯：[ADR 0046](../docs/adr/0046-account-read-audience-scope-split.md)・[ADR 0047](../docs/adr/0047-fraud-agent-scope-rename.md)
- 「AI が凍結解除を直接実行しようとする（構造的に届かない）」実行時シナリオ：[docs/architecture.md](../docs/architecture.md) §10 UC5
- 手元で確かめる：`make verify-hop` の異常系で、AI 経路からの `account:unfreeze` 取得が成立しないことを確認します

---

前へ：[2. Token Exchange（RFC 8693）入門](02-token-exchange.md) ｜ 次へ：[4. AI エージェントのアイデンティティと認可](04-ai-agent-identity.md)
