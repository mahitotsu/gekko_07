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
    │  Token Exchange（account-service 宛て、scope=account:read）
    ▼                               ↑ account:unfreeze はここに来ない
account-service
```

各サービスのアプリコードには Token Exchange の実装がありません。Envoy サイドカーが横取りして実行しています。Java・Go・Rust・Python・TypeScript と言語がバラバラでも、「次を普通に呼ぶだけ」で委任チェーンに参加できます。

詳しくは：[第 2 章](02-token-exchange.md)

---

## 3. 事後の監査

AI は非決定的です。「AI が実際に何を見て、何を提案したか」「人間がいつ・どのトークンで確定したか」を、後から確かめられる形で残す必要があります。

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

突き合わせを行う audit-service 自身は AI を使いません。判定は `jti` の完全一致だけです。「非決定的な AI の仕事を、決定的な仕組みで確かめる」という役割分担にしています。

詳しくは：[第 4 章](04-ai-agent-identity.md)

---

## 「なぜそうなるのか」を知りたい方へ

本章を読んで興味を持たれたら、次のように読み進めると理解が積み上がります。

| 関心 | 読む章 |
|---|---|
| **まず核心だけ知りたい** | この章 → [3章](03-scope-and-audience-topology.md) → [4章](04-ai-agent-identity.md) |
| **OAuth / Token Exchange から理解したい** | [1章](01-oauth-basics.md) → [2章](02-token-exchange.md) → [3章](03-scope-and-audience-topology.md) → [4章](04-ai-agent-identity.md) |
| **SPIFFE / mTLS まで知りたい** | [5章](05-workload-identity.md) |
| **一番深い検証結果（仕様間のギャップ）を知りたい** | [2章](02-token-exchange.md) → [6章](06-sender-constraining.md) |

全章を通しで読む必要はありません。[README](README.md) に各章の詳しい概要があります。
