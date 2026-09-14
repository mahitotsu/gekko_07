# ADR 0010: egressは実サービス名への透過的な呼び出しとし、audienceはHostヘッダーから自動導出する

- **Status**: Accepted
- **Date**: 2026-09-14

## Context

architecture.md §3は「次ホップごとに専用のegressリスナーを1つずつ用意する」としていたが、これは**単一のegress関係（1サービスが1つの次ホップに対して1種類の目的だけを持つ）しか想定していなかった**。[services.md](../services.md)を棚卸しすると、同じ次ホップに対して複数の目的（＝複数のscope）を持つケースがすでに標準的であることが分かる。

| 呼び出し元 | 対象audience | scope | 目的 |
|---|---|---|---|
| frontend | account-service | `account:read` | 取引ダッシュボード |
| frontend | account-service | `account:freeze` | 凍結確定ボタン |
| frontend | fraud-mcp-server | `account:read` | チャットUI開始時 |
| fraud-mcp-server | account-service | `account:read` | 取引照会系MCPツール |
| fraud-mcp-server | account-service | `account:propose` | 凍結案記録MCPツール |
| payment-service | account-service | `account:transact` | 入出金・振込（client_credentials、subject_tokenの交換ではない） |
| account-service | analyst-attribute-service | `analyst:read` | アナリスト属性照会 |

当初この複数目的問題への対処として、egressの呼び出し先を`localhost:<ポート>`や`/_egress/<サービス名>/<目的>`のような**実APIとは無関係な人工的なURL**で区別する案を検討したが、いずれも撤回する。相手先サービスのAPIパスはそのサービスのAPI定義で決まる値であり、それをコード内で書き換えて別のURL体系にすると、コードから「実際に何を呼んでいるか」が読み取れなくなる。

## Decision

### 1. アプリは実サービス名を宛先ホスト名としてそのまま呼び出す

アプリは`http://account-service/accounts/123/transactions`のように、**相手サービスの実名・実APIパスをそのまま使って**HTTPリクエストを組み立てる。EnvoyのHTTPフィルタチェーンが`ext_authz`で横取りし、認証済みリクエストへ変換してから実際のアップストリームへ転送する。人工的なURLプレフィックス・専用ポートは使わない（アプリのコードを見ればそのまま何を呼んでいるか分かる）。

**実現方式**：

- Podの`spec.hostAliases`で、そのPodが呼ぶ必要のある次ホップのホスト名を`127.0.0.1`へ静的にマッピングする（例：fraud-mcp-serverのPodなら`hostAliases: [{ip: "127.0.0.1", hostnames: ["account-service"]}]`）。これはKubernetes標準のPodSpecフィールドで、追加のDNSサーバーやiptables操作は不要
- Envoyサイドカーは`127.0.0.1`の1つのリスナー（例：port 80）で、複数の`virtual_hosts`を持つ`route_config`を1つ用意する。各virtual_hostは`domains: ["account-service"]`のように実サービス名でマッチする（HTTPクライアントは接続先IPが127.0.0.1であっても`Host`ヘッダーには元のURLのホスト名をそのままセットするため、Envoyはこれでルーティング先を判別できる）。これはEnvoyの標準的なHTTPルーティング機能であり、特別な拡張は不要
- egressの入口はPod内`127.0.0.1`にのみ存在し、**KubernetesのServiceでは一切公開しない**（実アップストリーム側のPodのServiceに繋ぐのはEnvoyの仕事）

### 2. audienceはHostヘッダーから自動導出する（context_extensionsでの明示指定は不要）

[access-control-design.md](../access-control-design.md)表1の注記で、本システムは既に「各サービスのaudience名とKeycloakのクライアントidを同一にする」ことを前提にしている。この前提を**KubernetesのService名にも拡張し、audience名＝Keycloakクライアントid＝Kubernetes Service名＝アプリが呼び出すホスト名を、常に同一の文字列にする**（MUST）。

この結果、ext_authzサービスはCheckRequestに含まれる`Host`ヘッダーの値を、そのままToken Exchangeの`audience`パラメータとして使える。audienceをリスナー・ルートごとに静的設定する必要がなくなり、設定の重複が1つ減る。

**〔1ホップ先行検証で訂正〕** 当初はこの`Host`をEnvoyの`ExtAuthzPerRoute.check_settings.context_extensions`経由でext_authzサービスへ渡す想定だったが、実機検証の結果、`context_extensions`はgRPCモードのext_authz限定の機能であり、[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)で採用したHTTPモードのext_authzには一切伝わらない（Envoy公式v3 APIリファレンスで確認：「These settings are only applied to a filter configured with a grpc_service.」）ことが判明した。一方、HTTPモードのext_authzは`Host`・`Method`・`Path`・`Content-Length`・`Authorization`を、`authorization_request.allowed_headers`の設定とは無関係に**常に自動的に**外部認可サーバーへのリクエストへ含めることも確認した。したがって実際の実装では、Envoy側のroute設定にcontext_extensionsは一切登場せず、ext_authzサービス自身が受け取った`Host`と`Path`+`Method`から§3の対応表を解決する。選択（HTTPモードext_authz・Hostからのaudience自動導出）そのものは変わらないため、実装メカニズムのこの訂正のみ本文に反映する。

### 3. scopeは常に「(ホスト, パス, メソッド) → scope」という単一の仕組みで決める

scopeは最終的に相手サービスの**実際のAPIパス・メソッド**から決まるべきものであり、これは相手サービス自身が公開する契約（[access-control-design.md](../access-control-design.md)表2を拡張した`(パス, メソッド) → スコープ`対応表）を参照して解決する。**この対応表はext_authzサービス自身がコードとして持ち**、CheckRequestで自動転送される`Path`+`Method`（§2訂正箇所参照）から解決する。**これは全ての委任関係に対して同じ1つの仕組みであり、特別扱いするケースはない**（`audience`は§2の通り自動転送される`Host`から導出されるため、Envoy側のroute設定はどのクラスタへ転送するかという宛先の振り分けだけを担い、scope解決ロジックを持たない）。

[services.md](../services.md)の7つの委任関係を実際に当てはめると、結果として2種類の見た目になる。

| 呼び出し元 → 対象audience | scope | Envoyルートの形 |
|---|---|---|
| payment-service → account-service | `account:transact`のみ | パスに依存しないワイルドカードルート1本（`prefix: "/"`）でscopeを固定 |
| account-service → analyst-attribute-service | `analyst:read`のみ | 同上 |
| frontend → fraud-mcp-server | `account:read`のみ | 同上 |
| frontend → account-service | `account:read` または `account:freeze` | `GET /accounts/{id}/**` → `account:read`、`POST /accounts/{id}/freeze` → `account:freeze` |
| fraud-mcp-server → account-service | `account:read` または `account:propose` | `GET /accounts/{id}/**` → `account:read`、`POST /accounts/{id}/freeze-proposals` → `account:propose` |

「scopeがpathによらず1つだけ」なホスト（前者3つ）は、たまたまルートが1本（ワイルドカード）に潰れているだけであり、「scopeがpathで変わる」ホスト（後者2つ）はルートが複数本になる。**両者は設計上の別カテゴリではなく、同じ仕組みが生成する結果の違いにすぎない**。

パスパターンは[access-control-design.md](../access-control-design.md)表2に拡張済み（account-service自身のingress側rbacポリシーと、これを呼ぶ全ての呼び出し元のegress側scope解決の、両方が参照する単一の情報源）。「account-serviceの完全なAPI設計（レスポンス形式・ページネーション等）」を待つ必要はない——Envoyのroute解決に要るのは表2のパスパターンだけであり、これは既に決まっているため、この節はもう未解決ではない。アプリのコードは常に「実ホスト名・実パス・実メソッドで普通にAPIを呼ぶ」だけでよい。そのAPIコールに対応するEnvoyルートが1本のワイルドカードなのか複数の実パスマッチなのかは、アプリのコード側が意識する必要は一切ない。

### 4. egressの4パターン（維持・一部更新）

egressで必要な処理は4種類ある。①②③は透過的なプロキシ（実サービスを呼んでいるつもりでリクエストを組み立て、Envoyが横取りして転送する）という共通の形を持つ。④だけは性質が異なり、実サービスを一切呼ばない合成的な呼び出しである。

**① Token Exchange**：frontend→account-service/fraud-mcp-server、fraud-mcp-server→account-service、account-service→analyst-attribute-service。ext_authzは`authorization_response.allowed_upstream_headers`で交換後トークンを`Authorization`ヘッダーとして実アップストリームへの転送リクエストに乗せる。

**② client_credentials発行**：payment-service→account-service。①と同じ`allowed_upstream_headers`の仕組みを使うが、Token Exchangeではなくclient_credentials grantを使う（取得したトークンのキャッシュ・更新が主な仕事になる）。

**③ 素通し**：fraud-agent→fraud-mcp-server（frontendが交換済みのトークンをそのまま使い回す。services.md参照）。ext_authz自体を呼ぶ必要がなく、単純なプロキシとして構成する（Authorizationヘッダーを一切書き換えない）。

**④ トークンを値として取得**：frontend→fraud-mcp-server（チャットUI開始時。services.md参照）。①と同じext_authz呼び出しを行うが、実サービスを呼ぶための実パスが無いため、フロントエンドが「トークンを取得するためだけの」専用パス（例：`http://fraud-mcp-server/_mint-token`。実APIではなく、この呼び出しだけが唯一の例外として人工的なパスを持つ）を呼ぶ。ルート側を実アップストリームへの転送ではなく`route.direct_response`（例：HTTP 204）として構成し、ext_authzの`authorization_response.allowed_client_headers_on_success`で交換後トークンを**呼び出し元（frontendアプリ自身）への応答ヘッダー**として返す。アプリのコード上でも「実サービスを呼んでいるのではなくトークンを取得している」ことが明確に分かる、実パスのないURLである点を意図的なシグナルとして扱う。

以上①〜④とも、audience（Hostヘッダーから自動導出）・scope（相手サービスの対応表から解決、③④は例外）の組み合わせにより、[ADR 0002](0002-token-exchange-in-envoy-sidecar.md)が目指した「動的な解決ロジックを持たない」という設計目標を、宛先の文字列を人工的に発明することなく実現する。

### 5. 「アプリがscopeを指定する」方式は採用しない（変更なし）

検討した代替案：アプリが要求ヘッダー（例：`x-desired-scope: account:freeze`）でscopeを指定し、ext_authzがそれを読んでToken Exchangeする方式。採用しない。

- [ADR 0009](0009-envoy-ingress-responsibility-and-bypass-prevention.md)で「アプリの意図はトポロジーで構造的に強制し、自己申告のフラグや値に頼らない」という考え方を一貫して採用しており、scope選択だけをアプリの自己申告に委ねるのは一貫性を欠く
- ヘッダー方式では、アプリのバグ・実装ミス（例：本来`account:read`のはずの経路で誤って`account:freeze`をヘッダーにセットしてしまう）が、そのままより強い権限の要求につながりうる。frontendのように`account:read`と`account:freeze`の両方を許可されたクライアントでは、Keycloak側のクライアントスコープ制限だけではこの種の取り違えを防げない。実際に呼んだ実パス・実メソッドから対応表でscopeを機械的に決めるほうが、アプリの自己申告に頼るより堅い

## Consequences

- architecture.md §3の記述を「実サービス名への透過的呼び出し」「audienceはHostヘッダーから自動導出」「scopeは常に(ホスト,パス,メソッド)→scopeという単一の仕組みで決める（結果としてワイルドカード1本のホストと複数ルートが要るホストに分かれる）」に更新した
- **MUST**：Keycloakクライアントid＝Kubernetes Service名＝audience名は、常に同一の文字列にする（今後実装する全サービスのマニフェストで守る）
- 先行検証（ADR 0002が予定するfraud-mcp-server→account-service）で、`hostAliases`＋Envoy `virtual_hosts`による透過的ルーティングを実機確認**済み**（`account:read`/`account:propose`いずれも200・期待した`x-auth-*`ヘッダーで到達）。パスパターンは[access-control-design.md](../access-control-design.md)表2に拡張済みだったため、先行検証を妨げる未決定事項はなかった
- account-serviceの完全なAPI設計（レスポンス形式・ページネーション等の実装詳細）はaccount-service実装着手時に行うが、Envoyのroute解決に必要なパスパターン自体は表2に既に決まっているため、これはもう「egress設計のブロッカー」ではない
- ext_authzサービスと実際のEnvoy bootstrap設定（`hostAliases`、`virtual_hosts`、`ExtAuthzPerRoute`）は、パターン①（Token Exchange、fraud-mcp-server→account-service）について実機検証済み（`k8s/ext-authz/`・`k8s/account-service/`・`k8s/fraud-mcp-server/`。scopeは§2・§3訂正の通りcontext_extensionsを使わずext_authz側で解決する）。パターン②④（`direct_response`、`allowed_client_headers_on_success`）・パターン③（素通し）は未検証のまま（[backlog.md](../backlog.md)参照）
