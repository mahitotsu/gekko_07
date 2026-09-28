# 0. 5分で分かる：このサンプルが確かめたこと

この解説は全 6 章ありますが、**まずこの 1 枚を読んでください**。何を確かめたサンプルなのか、5 分で全体像を掴めます。「なぜこうなるのか」が気になったら、各章へ進んでください。

---

## 1. AI エージェントの権限設計

AI エージェントに社内 API を触らせるとき、よくある問いがあります。「読み取りと提案だけさせるつもりだが、本当に実行はできないのか」というものです。

よくある実装は、エージェントのコードに `if (操作 === "実行") throw ...` と書くことですが、そのコードにバグがあれば崩れます。このサンプルでは別の考え方を試しました——**そもそも実行系のトークンを取得できる経路を、認可サーバーの設定として作らない**、というやり方です。

```
アナリスト
    │
    │  調査を依頼
    ▼
AI エージェント
    │
    ├─ 読む       ○  （account:read）
    ├─ 分析する   ○
    ├─ 提案する   ○  （account:propose）
    │
    └─ 実行する   ×  ← Token Exchange の経路が存在しない
                        （account:unfreeze を取得できない）

アナリスト
    │
    │  提案を確認し、明示的に確定操作
    ▼
実行              ○
```

「エージェントのコードを信頼するのではなく、エージェントを信頼しなくても危険な操作ができない認可の構造を作る」——これがこのサンプルの核心です。

詳しくは：[第 3 章](03-scope-and-audience-topology.md)・[第 4 章](04-ai-agent-identity.md)

---

## 2. Token Exchange の連鎖

「実行はできないが、AI が口座を読む」という委任はどう実現するのでしょうか。サービスをまたぐたびに、認可サーバー（Keycloak）で「このサービス宛て・この権限のトークン」に交換します。これを **Token Exchange**（RFC 8693）と言います。

```
frontend
    │  Token Exchange（fraud-agent 宛て、scope=fraud-agent:read）
    ▼
fraud-agent（AI）
    │  Token Exchange（fraud-mcp-server 宛て、scope=fraud-mcp-server:read）
    ▼
fraud-mcp-server（MCP）
    │  Token Exchange（account-service 宛て、scope=account:read / account:propose）
    ▼
account-service
```

※この AI 経路（frontend→fraud-agent→MCP→account-service）には、`account:unfreeze`（実行権限）が一度も現れません。人間の確定操作は、これとは別の経路（frontend→account-service）を通ります（[第 3 章](03-scope-and-audience-topology.md)）。

各サービスのアプリコードには Token Exchange の実装がありません。Pod 内のサイドカーが代わりに担うので、Java・Go・Rust・Python・TypeScript と言語がバラバラでも、アプリは「次を普通に呼ぶだけ」で委任チェーンに参加できます（サイドカーの内訳——Envoy と token-exchange コンテナの役割分担——は[第 2 章](02-token-exchange.md)）。

詳しくは：[第 2 章](02-token-exchange.md)

---

## 3. 事後の監査

AI は非決定的です。「どの API が、どの権限で呼ばれ、どの提案が記録されたか」「その凍結解除は、どの提案に基づき、誰が確定したか」を、後から確かめられる形で残す必要があります（ログから分かるのはアクセスの成否までで、モデルが内部で何を考えたかは対象外です）。

```
                     Keycloak のトークン発行ログ
                     Envoy のアクセスログ（第三者記録）
                             │
                             ▼
業務サービスの自己申告  ──── audit-service が突き合わせ
（誰が提案し、承認し、実行したか）   │
                             ▼
                       jti（トークン固有 ID）の
                       完全一致で判定
                       ← AI は使わない
```

突き合わせを行う audit-service 自身は AI を使いません。判定は `jti`（トークン固有 ID）の完全一致だけです。「非決定的な AI の仕事を、決定的な仕組みで確かめる」という役割分担にしています。突き合わせの対象は、取り消せない操作（承認・却下・凍結解除の実行＝`account:unfreeze`）に絞っています。

詳しくは：[第 4 章](04-ai-agent-identity.md)

---

## 4. やってみて、あえて採らなかったこと

このサンプルの検証は「うまくいったこと」だけではありません。盗まれたトークンの再利用を防ぐ**送信者拘束**（DPoP / RFC 8705）も実際に試しましたが、Impersonation 型の多段 Token Exchange では、クライアントをまたいで拘束し直すための認可の根拠が仕様上定義されておらず、効果が限られることが分かりました。そのため現時点では採用していません。「何を・なぜ採らなかったか」まで含めて確かめている点が、この解説群のもう一つの中身です。

詳しくは：[第 6 章](06-sender-constraining.md)

---

興味を持たれたら、[README](README.md) の「関心別の読み方」を参照してください（核心だけなら この章 → [3章](03-scope-and-audience-topology.md) → [4章](04-ai-agent-identity.md) の 3 本で読めます）。全章を通しで読む必要はありません。
