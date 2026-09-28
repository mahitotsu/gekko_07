# 5. ワークロード ID とクライアント認証

> 対象読者：ここまで（トークン・Token Exchange・スコープ）を読んだ方。
> この章のねらい：「誰が何をしてよいか」（OAuth）と「誰と話しているか」（mTLS）はなぜ別のレイヤーなのかを理解し、サイドカーが自分の身元を Keycloak にどう証明するか（クライアント認証）を見ていきます。

## 5.1 2 つの「身元」を区別する

「身元検証」と一口に言いますが、このサンプルでは、はっきりと**別々の 2 つの関心事**として扱っています。ここを混同すると設計がこんがらがってしまうので、最初に整理しておきます。

| 関心事 | 問い | 担うもの | たとえると |
|---|---|---|---|
| **業務認可** | 誰が、何をしてよいか | OAuth / Token Exchange（Keycloak） | 「この人は口座を解除する権限を持つ」 |
| **通信路の身元** | 今、誰と通信しているか | mTLS（SPIFFE/SPIRE） | 「今、電話の向こうにいるのは本当に account-service か」 |

この 2 つは独立しています（[docs/architecture.md](../docs/architecture.md) §3.5）。トークンが「持ち主に何を許すか」を語る一方で、mTLS は「その通信の両端が、本当に名乗ったとおりの相手か」を保証します。

なぜ両方が必要なのでしょうか。[第 1 章 1.7](01-oauth-basics.md#17-ベアラートークン便利さと弱点)で見たとおり、トークンはベアラー（持参人）で、盗まれれば誰でも使えてしまいます。逆に mTLS は、「相手が誰か」は分かっても「その相手が何をしてよいか」までは分かりません。**片方だけでは守りに隙間が残る**ので、このサンプルではレイヤーを分けて両方を敷いています。

## 5.2 mTLS とワークロード ID（SPIFFE/SPIRE）

通常の TLS（HTTPS）は「サーバーが本物か」をクライアントが確認する、片方向の仕組みです。**mTLS（相互 TLS）**では、サーバーもクライアントを証明書で確認します。両端がお互いに「あなたは誰ですか」を証明書で確かめ合う、というものです。

ただ、マイクロサービスで mTLS をやろうとすると、「各サービスにどうやって証明書を配り、期限が切れる前にどう更新し続けるか」が悩みになります。これを自動化してくれるのが **SPIFFE/SPIRE** です。

- **SPIFFE** は「ワークロード（サービス）に、人間のアカウントとは別の、機械用の身元 ID を与える」ための標準です。このサンプルでは `spiffe://gekko.internal/ns/gekko/sa/default/account-service` のような ID が各サービスに割り当てられます
- **SPIRE** はその実装です。どのワークロードにどの ID を与えるかを判定（アテステーション）し、短命の X.509 証明書（X.509-SVID）を自動で発行・更新します

このサンプルでは、Envoy サイドカーが SPIRE から証明書を受け取り、サービス間の通信をすべて mTLS で行います。証明書のライフサイクル管理のコードは、アプリにも Envoy 設定にも現れません——SPIRE が裏で回してくれます。受信側は「どの SPIFFE ID の相手を受け入れるか」を設定でき（`match_typed_subject_alt_names`）、たとえば account-service は「fraud-mcp-server・fraud-detection-engine・frontend・audit-service からの mTLS だけを受ける」と限定しています（[docs/architecture.md](../docs/architecture.md) §3.5）。

## 5.3 3 層で守る

このサンプルは、独立した 3 つの層を重ねています。1 つが破れても次が残る、という多層防御の考え方です。

1. **業務認可（OAuth / Token Exchange）**：誰が何をしてよいか（[第 2・3 章](02-token-exchange.md)）
2. **通信路の身元（mTLS / SPIFFE/SPIRE）**：誰と話しているか（本章）
3. **ネットワーク到達性（NetworkPolicy）**：そもそも誰が誰に接続できるか。gekko namespace 全体をデフォルト拒否にし、実装済みの経路だけを L3/4 で明示的に許可します（[ADR 0018](../docs/adr/0018-network-policy-default-deny.md)）

「トークンが正しく、通信相手も正しく、ネットワーク経路も許可されている」——この 3 つすべてを満たさないと通らない、という形です。

## 5.4 クライアント認証：サイドカーはどうやって Keycloak に「私は fraud-mcp-server です」と証明するか

ここで、[第 2 章](02-token-exchange.md)で保留していた問いに戻ります。Token Exchange を要求するとき、Keycloak は「この要求を出しているクライアントは、本当に fraud-mcp-server か」を確かめる必要があります。この確認を**クライアント認証**と呼びます。

伝統的には、クライアントに `client_secret`（合言葉）を持たせ、それを Keycloak に提示させます。ですがこのサンプルでは、`client_secret` を**使っていません**。なぜでしょうか。ここには、実際に作ってみて分かった設計上の落とし穴——**身元検証のギャップ**——があります。

### 落とし穴：共有プロキシが合言葉を代理保持する構造の隙間

このサンプルは当初、Token Exchange を「共有の ext-authz-service」にまとめ、そこが各呼び出し元の `client_secret` を代理で持って交換を代行する設計でした（[ADR 0002](../docs/adr/0002-token-exchange-in-envoy-sidecar.md)）。一見きれいなのですが、レビューの過程で隙間が見つかりました（[ADR 0019](../docs/adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)）。

- Keycloak が最終的に見ている通信相手（mTLS の身元）は、**共有プロキシ自身**であって、fraud-mcp-server ではありません
- Keycloak が「これは fraud-mcp-server だ」と信じる根拠は、「fraud-mcp-server の `client_secret` を知っているから」だけです
- つまり Keycloak は「**合言葉を知っているか**」しか確かめておらず、「**本当にそのワークロードが要求しているか**」までは確かめられていませんでした

合言葉は漏れる可能性がありますし、代理で保持する構造では「名乗っている client_id」と「実際に通信している相手」がずれてしまいます。信頼の起点である Keycloak にとって、これは身元の証明として物足りない状態でした。

### 解決：ワークロード ID そのものでクライアント認証する

このサンプルでは、これを、**合言葉をやめて、SPIRE が発行するワークロード ID（JWT-SVID）そのものでクライアント認証する**ことで解消しました（[ADR 0019](../docs/adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)〜[0021](../docs/adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)）。

- Token Exchange を実行する主体を、共有プロキシから**各呼び出し元と同じ Pod 内のサイドカー**へ移しました。SPIRE のアテステーションは「そのプロセス（Pod）が誰か」に紐づくので、fraud-mcp-server 自身の Pod でしか fraud-mcp-server の JWT-SVID は手に入りません
- サイドカーは Keycloak を呼ぶとき、`client_secret` の代わりに**自分の JWT-SVID**（SPIRE が「これは確かに fraud-mcp-server だ」と署名した身分証）を提示します（Keycloak の `federated-jwt` 機能）
- これにより、Keycloak が検証する身元（JWT-SVID が証明する SPIFFE ID）と、要求元が名乗る client_id が**一致する**ようになりました。「合言葉を知っているか」ではなく「本当にそのワークロードか」を Keycloak が直接確かめられる、という形です

言い換えると、本章前半（[5.2](#52-mtls-とワークロード-idspiffespire)）の mTLS と、ここで見たクライアント認証が、**同じ SPIFFE 身元**の上で揃った、ということになります。通信路の身元（X.509-SVID）と、認可サーバーへのクライアント認証（JWT-SVID）が、どちらも「このワークロードは誰か」という同じ根っこにつながります。

> この解決には、いくつか実際に手を動かして分かった工夫が伴っています（distroless な spire-agent のバイナリを Kubernetes の ImageVolume でマウントする、SPIRE の bundle endpoint を有効化して Keycloak に検証鍵を渡す、など）。詳細は [ADR 0019](../docs/adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md) と [docs/insights.md](../docs/insights.md) にまとめてあります。設計図だけでは見えず、動かして初めて分かる部分でもあります。

## 5.5 この章のまとめ

- このサンプルは、身元を**2 つの独立した関心事**に分けています：業務認可（OAuth ＝ 誰が何をしてよいか）と、通信路の身元（mTLS ＝ 誰と話しているか）
- 通信路は **SPIFFE/SPIRE** がワークロードに機械用の ID を与え、mTLS 証明書を自動で発行・更新します
- さらに **NetworkPolicy** による L3/4 のデフォルト拒否を重ね、3 層で守っています
- Token Exchange のクライアント認証は、漏れる可能性のある `client_secret` ではなく、**SPIRE 発行の JWT-SVID** で行います。これにより「合言葉を知っているか」ではなく「本当にそのワークロードか」を Keycloak が直接確かめられます（**身元検証のギャップ**の解消。[ADR 0019](../docs/adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)）
- 通信路の身元と、認可サーバーへのクライアント認証が、同じ SPIFFE 身元の上で揃います

次章では、それでも残る「ベアラートークンの盗難・再利用」をトークン自体で防ぐ**送信者拘束**を扱います。そこで、送信者拘束と Token Exchange の**仕様間のギャップ**という難しさに触れます。

## gekko_07 ではどう確かめたか

- 3 層（業務認可・mTLS・NetworkPolicy）の全体像：[docs/architecture.md](../docs/architecture.md) §3.5・§3.6
- 身元検証のギャップの発見と解消：[ADR 0019](../docs/adr/0019-ext-authz-identity-gap-and-spiffe-jwt-svid-auth.md)・[ADR 0020](../docs/adr/0020-fraud-detection-engine-identity-gap-and-client-credentials-federated-jwt.md)・[ADR 0021](../docs/adr/0021-account-service-analyst-attribute-service-spiffe-jwt-svid.md)
- mTLS 導入の経緯：[ADR 0012](../docs/adr/0012-spiffe-spire-mtls-single-hop.md)、Keycloak の完全 mTLS 化：[ADR 0017](../docs/adr/0017-edge-proxy-full-keycloak-mtls.md)
- 実際に踏んだ罠：[docs/insights.md](../docs/insights.md)（Keycloak・Envoy・SPIRE の各節）
- 手元で確かめる：`make network-status` が、NetworkPolicy と Envoy の実プロトコル（mTLS/plaintext）を突き合わせて表示します

---

前へ：[4. AI エージェントのアイデンティティと認可](04-ai-agent-identity.md) ｜ 次へ：[6. 送信者拘束の難しさ（DPoP / RFC 8705）](06-sender-constraining.md)
