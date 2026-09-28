# 2. Token Exchange（RFC 8693）入門

> 対象読者：[第 1 章](01-oauth-basics.md)の用語（`sub`・`aud`・`scope`・ベアラートークン）を押さえた方。
> この章のねらい：サービスをまたいで権限を「委任」するとき何が起きるか、そしてこのサンプルの委任チェーンがなぜこの形になっているのかを、一緒に見ていきます。

## 2.1 問題：委任チェーンで「トークンを使い回せない」

第 1 章で、アナリストがログインすると `aud=frontend` のログイントークンが手に入ることを見ました。では、frontend はこのトークンを使って account-service を呼べるでしょうか。

呼べません。account-service は「自分宛て（`aud=account-service`）のトークンしか受け付けない」からです（[第 1 章 1.4](01-oauth-basics.md#14-audienceaudこのトークンは誰宛てか)）。`aud=frontend` のトークンを account-service に投げても、「私宛てではない」として受け付けられません。

「それなら、最初から `aud` に frontend と account-service の両方を入れておけばよいのでは」と思われるかもしれません。ですが、それはトークンの通用範囲を広げてしまいます。マイクロサービスが増えるほど「全部入り」の万能トークンになり、1 枚漏れただけで被害が全サービスに及んでしまいます。このサンプルが単一 audience を原則にしている（[ADR 0005](../docs/adr/0005-single-audience-tokens-only.md)）のは、これを避けたいからです。

さらに、このサンプルの本命のシナリオはもう少し複雑です。アナリストが AI エージェントに「この凍結口座を精査して」と頼むと、次のように**サービスが数珠つなぎ**になります。

```
アナリスト → frontend → fraud-agent → fraud-mcp-server → account-service
```

frontend は fraud-agent を、fraud-agent は fraud-mcp-server を、fraud-mcp-server は account-service を呼びます。**各つなぎ目（ホップ）で「呼ぶ相手宛ての、権限を絞ったトークン」が必要**になります。しかも「これは元をたどればアナリスト田中さんの依頼だ」という情報は保ったまま渡したいところです。これを実現するのが **Token Exchange** です。

## 2.2 Token Exchange とは何か

Token Exchange（[RFC 8693](https://www.rfc-editor.org/rfc/rfc8693.html)）は、「**今持っているトークンを認可サーバーに渡して、別のトークンに交換してもらう**」仕組みです。交換のときに、宛先（audience）と権限（scope）を指定します。

具体的には、認可サーバーのトークンエンドポイントへ、次のようなリクエストを送ります（要点だけ抜粋しています）。

```
POST /realms/gekko/protocol/openid-connect/token
grant_type = urn:ietf:params:oauth:grant-type:token-exchange
subject_token = （今持っている aud=frontend のトークン）
audience = account-service        ← 交換後に欲しい宛先
scope = account:read              ← 交換後に欲しい権限
```

- `grant_type` は、これが Token Exchange であることを示す長い URN です
- `subject_token` は「交換のもとにする、今持っているトークン」です。「私はこの権限を持つ者だ」という証拠になります
- `audience` と `scope` で「交換して何が欲しいか」を指定します

認可サーバー（Keycloak）は、「この要求元は、この audience・scope への交換を許されているか」を判定し、問題なければ **`aud=account-service` / `scope=account:read` の新しいトークン**を返します。frontend はそれを使って account-service を呼べるようになります。

ここで押さえておきたいのは、**交換の可否を判定するのは認可サーバー**だという点です。要求元が勝手に「私は account-service を呼べる」と主張しても通りません。Keycloak の設定上その交換が許可されていなければ、拒否されます。この「許可されているかどうか」をどう設計するかが、[第 3 章](03-scope-and-audience-topology.md)の主題です。

## 2.3 委任チェーンは Token Exchange の連鎖

先ほどの数珠つなぎは、Token Exchange を各ホップで繰り返すことで実現されます。このサンプルの「① 提案生成パス」を追ってみましょう（[docs/architecture.md](../docs/architecture.md) §5）。

```
アナリストのログイントークン (aud=frontend)
  │  frontend が Token Exchange
  ▼  audience=fraud-agent, scope=fraud-agent:read
トークン (aud=fraud-agent)
  │  fraud-agent が Token Exchange
  ▼  audience=fraud-mcp-server, scope=fraud-mcp-server:read
トークン (aud=fraud-mcp-server)
  │  fraud-mcp-server が Token Exchange
  ▼  audience=account-service, scope=account:read または account:propose
トークン (aud=account-service)
  │  account-service が使って処理する
  ▼
（さらに account-service が analyst-attribute-service を呼ぶときも Token Exchange）
```

各サービスは「自分宛てのトークンを受け取る」→「次の宛先へのトークンに交換する」→「次を呼ぶ」を繰り返します。1 枚のトークンが複数サービスを渡り歩くのではなく、**ホップごとに新しいトークンが生まれます**。ですから 1 枚が漏れても、その audience の 1 サービスにしか使えません。

## 2.4 誰が交換を実行するのか——サイドカーへの切り出し

ここで、実装上の悩みどころが出てきます。上の連鎖では、frontend・fraud-agent・fraud-mcp-server・account-service の**すべてが Token Exchange を実行する**必要があります。しかも、このサンプルのサービスは実装言語がバラバラです（TypeScript・Python・Java・Go・Rust）。

素朴に作ると、5 つの言語それぞれで「トークンエンドポイントへ `grant_type=...token-exchange` を POST し、レスポンスを解釈し、エラーを処理する」という**同じ RFC 8693 クライアントロジックを重複して実装する**ことになります。これは手間がかかり、後回しにされがちで、バグの温床にもなりやすいところです。

このサンプルでは、**Token Exchange をアプリ本体から切り離し、Envoy サイドカーにまとめる**という方法をとっています（[ADR 0002](../docs/adr/0002-token-exchange-in-envoy-sidecar.md)）。サイドカーとは、アプリと同じ Pod に同居して、ネットワーク通信を横取りするプロキシのことです。

- アプリは、相手サービスの**実名・実 API パスをそのまま呼ぶだけ**でよくなります。例：`GET http://account-service/accounts/123/transactions`
- そのリクエストを Envoy サイドカーが横取りし、`ext_authz` という仕組みを通じて Token Exchange を実行し、得たトークンを `Authorization` ヘッダーに載せてから、本当の account-service へ転送します
- アプリのコードには Token Exchange が一切現れません

こうすると、言語が何であっても「次のサービスを普通に呼ぶだけ」で RFC 8693 準拠の委任チェーンに参加できます。Token Exchange のロジックは 1 箇所（サイドカー）だけにまとまります。言語がバラバラな構成では、この切り出しの効果が分かりやすく出ます。逆に、言語が揃っている構成なら共通ライブラリでも代替できるため、この構成でどこまで効くのかを確かめたい、というのがこのサンプルの動機の一つでした（[docs/requirements.md](../docs/requirements.md)「背景」）。

> ここでは「Token Exchange はアプリではなくサイドカーが行っている」とだけ押さえていただければ十分です。サイドカーがどうやって自分の身元を Keycloak に証明して交換を要求するのか（クライアント認証）は、[第 5 章](05-workload-identity.md)で扱います。

## 2.5 Impersonation と Delegation：委任の 2 つのモデル

RFC 8693 には、委任のモデルが 2 種類あります。この違いは、このサンプルの監査の仕組みと、[第 6 章](06-sender-constraining.md)の送信者拘束の話に直結する大事なところなので、丁寧に見ておきます。

### Impersonation（なりすまし方式）

交換後のトークンが「**元の主体そのもの**」として振る舞います。田中さんのログイントークンを起点に交換したトークンは、何ホップ先でも `sub` が田中さんのまま維持されます。「今これを実際に提示しているのが fraud-mcp-server だ」という情報（誰が代理しているか）は、**トークンには記録されません**。

このサンプルは、この Impersonation 方式を採っています（Keycloak の Standard Token Exchange V2）。委任チェーンの端から端まで `sub` が田中さんのままなので、次のことが成り立ちます。

- **権限の判定が、常に「本人」に対して行われます**：account-service が「このリクエストは誰の権限で処理すべきか」を判定するとき、`sub` は田中さん本人です。ですから AI エージェント経由であっても、田中さんが直接見られる範囲しか見られません（AI を経由することで本人以上の情報が見えてしまう、ということが起きません）。これが業務要件 BR4 の土台になっています
- **監査で追跡できます**：後で説明します

### Delegation（委任方式）

交換後のトークンに「誰が・誰の代理で動いているか」を明示的に記録します。RFC 8693 では `act`（actor）クレームがこれを表し、ホップを重ねるごとに `act` が入れ子（ネスト）になっていきます。「田中さんの代理として fraud-mcp-server が、そのさらに代理として…」という連鎖がトークンに刻まれます。このサンプルでは**採用していません**。

### なぜこのサンプルは Impersonation を選んだか

このサンプルの監査は、「**同じ `sub`（田中さん）だが、`jti`（トークン固有 ID）と `scope` が違う**」ことを使って、委任チェーンの各ステップを区別・再構成します（[docs/architecture.md](../docs/architecture.md) §9）。たとえば次のように読み分けます。

- 「AI が何を見て、何を提案したか」＝ `sub=田中`, `scope=account:read`／`account:propose` のトークンでのアクセス
- 「人間が何を確定したか」＝ `sub=田中`, `scope=account:unfreeze` のトークンでのアクセス

`sub` が一貫して田中さんだからこそ「田中さんの一連の操作」としてまとめられ、`scope`/`jti` の違いで「AI の読み取り」と「人間の実行」を切り分けられます。Impersonation は、この追跡と相性がよい方式です。

Delegation にも利点はありますが、このサンプルの文脈ではコストの方が大きくなります（トークンがホップごとに肥大化する、Keycloak の該当機能の成熟度がまだ低い、など）。この判断の詳しい経緯は[第 6 章](06-sender-constraining.md)と [ADR 0048](../docs/adr/0048-sender-constraining-terminal-hop-only.md) で扱います。ここでは「**Impersonation ＝ `sub` が本人のまま／`act` を残さない**」「**Delegation ＝ `act` で代理の連鎖を記録する**」という違いを覚えておいていただければ大丈夫です。

## 2.6 この章のまとめ

- 単一 audience 原則のもとでは、あるサービス宛てのトークンを別のサービスにそのまま使えません。だからこそ、**宛先・権限を絞ったトークンに交換する**のが Token Exchange（RFC 8693）です
- `subject_token`（今持っているトークン）を認可サーバーに渡し、`audience`・`scope` を指定して新しいトークンをもらいます。**交換の可否を決めるのは認可サーバー**です
- 委任チェーンは Token Exchange の連鎖です。ホップごとに新しい単一 audience トークンが生まれます
- このサンプルは Token Exchange を **Envoy サイドカーにまとめ**、多言語のアプリが「普通に次を呼ぶだけ」で委任チェーンに参加できるようにしています（[ADR 0002](../docs/adr/0002-token-exchange-in-envoy-sidecar.md)）
- **Impersonation 方式**（`sub` が本人のまま維持され、代理者を記録しない）を採っています。これが本人ベースの権限判定（BR4）と、`jti`/`scope` による監査を支えています

次章では、この Token Exchange の「**交換の可否**」を認可サーバーの設定だけで制御し、AI エージェントに実行権限を「そもそも取得させない」ようにする方法に踏み込みます。

## gekko_07 ではどう確かめたか

- Token Exchange のサイドカー集約：[ADR 0002](../docs/adr/0002-token-exchange-in-envoy-sidecar.md)、egress の宛先・audience・scope の決め方：[docs/architecture.md](../docs/architecture.md) §3.2
- 委任チェーンのホップ一覧（全 9 ホップ）とトークンチェーン：[docs/architecture.md](../docs/architecture.md) §3.3・§5
- Impersonation 方式と監査での追跡：[docs/architecture.md](../docs/architecture.md) §9
- 手元で動かす：`make verify-hop` が、委任チェーン全ホップの Token Exchange が実際に通ることを確認します（[README.md](../README.md)）

---

前へ：[1. OAuth 2.0 の基礎](01-oauth-basics.md) ｜ 次へ：[3. スコープと audience で「構造的に」権限を封じる](03-scope-and-audience-topology.md)
