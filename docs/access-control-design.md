# アクセス制御設計（ディシジョンテーブル）

[access-control-requirements.md](access-control-requirements.md)で定めた業務要件（BR0〜BR8）を、architecture.mdの認可設計がどう実現しているかを、条件と結果が漏れなく列挙できる形（ディシジョンテーブル）で示す。各表の見出しに対応する要件番号を明記し、業務要件と実装の対応関係を追跡できるようにする。性質の異なる認可判断ごとに表を分ける。

## 認証（アナリストのログイントークン、BR0に対応）

以降の表は全て「認証済みの主体が保持するトークン」を前提にしている。ここではその出発点、すなわちアナリストがログインした時点で何が発行されるかを定める。BR0（認証の必須化）は、ここで発行されるログイントークンを持たない限り、以降のどのToken Exchangeも開始できない、という形で実現される。

アナリストはOAuth 2.0 Authorization Code + PKCEでKeycloakにログインする。frontendはconfidential clientとして、ブラウザから受け取ったauthorization codeをKeycloakのトークンエンドポイントで自身のクライアント資格情報とともにアクセストークンに交換する（このやり取り自体はToken Exchangeではない、通常のOIDC認可コードフロー）。

ここで発行される**ログイントークン**の内容は以下の通り。

| クレーム | 値 |
|---|---|
| `sub` | アナリストの一意識別子（uid）。以降の全てのToken Exchangeを通じて維持され、委任チェーン全体を追跡するキーになる |
| `aud` | `frontend`（単一。[ADR 0005](adr/0005-single-audience-tokens-only.md)） |
| `iss` | Keycloakのrealm発行者 |
| scope | 最小限（`openid`程度）。`account:read`・`account:freeze`等のスコープはこの時点では一切持たない |

このトークンには、アナリストの担当地域・権限レベルは一切含まれない。これらはanalyst-attribute-serviceが保持する外部属性であり、必要になった都度、後続のToken Exchangeの先で照会される（表5）。クレームにするか業務データとして外部化するかの判断基準（役割・オーナーシップ・機密性の3軸）は[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)を参照。担当地域・権限レベルは3軸全てで「外部化すべき」側に該当する：これは実行時の個別業務判断（今このアナリストが何をできるか）のもとになるデータであり、正典は業務ドメイン（人事上の配属情報）であり、fraud-mcp-server等の中継者に見せる必要がないため。

このログイントークンをそのままaccount-service等の呼び出しに使う経路は存在しない。account-serviceへのアクセスが必要になった時点で、frontendが目的別に明示的なToken Exchangeを実行する（表1、architecture.md §5）。ログイントークンをDPoP等で送信者拘束するかどうかは未決定（[backlog.md](backlog.md)参照）。

## 表1: Audience間のToken Exchange可否（BR5・BR6に対応）

この表は「あるaudience宛てのトークンを、別のどのaudience宛てのトークンに交換できるか」を示す。行は交換前トークンの`aud`（元audience）、列は交換後に要求する`aud`（先audience）である。全てのトークンは常に単一のaudienceのみを持つ（[ADR 0005](adr/0005-single-audience-tokens-only.md)）ため、「元audience」は常に一意に定まる。payment-serviceはToken Exchangeに参加しない（client_credentials）ため、この表には含めない（表4で別に扱う）。

**注意点（重要）**：

- Keycloakの実際の許可判定は「トークンのaudienceそのもの」ではなく、「Token Exchangeを要求しているクライアント自身の認証情報（client_id/secret）が、要求先audienceについて許可されているか」、かつ「提示された`subject_token`の`aud`に、その要求元クライアント自身が含まれているか」の2点で行われる。本システムでは各サービスの`audience名`と`Keycloakのクライアントid`を同一にしており、かつ各サービスは自分宛て（＝自分のクライアントidと一致するaudience）のトークンしか受け取らない設計にしているため、結果として「元audience」と「それを正当に提示できる唯一のクライアント」が1対1に対応する。だからこそ本表を「audience→audience」の単純な遷移表として記述できる。この前提（audience名＝client id、1トークン1保持者）が崩れる場合、この単純化は成立しなくなる
- 「実際に交換をリクエストしたプロセスが誰か」という素性は、この表のALLOW/DENY判定に一切現れない。判定に使われるのは「提示されたトークンのaudience」と「要求元として認証されたクライアント資格情報」だけである
- この表はあくまで「どのaudience間でToken Exchangeが許可されているか」という認可トポロジーを示すものであり、「そのトークンを提示しているプロセスが本当にその正当な保持者かどうか」は別の関心事である。ベアラートークンである以上、盗まれたトークン文字列は誰でも提示できてしまう。これを防ぐには送信者拘束（DPoP、RFC 9449等）のような別の仕組みが必要で、本表の許可トポロジー単体では保証されない（DPoPの適用範囲は未決定。[backlog.md](backlog.md)参照）

| 元audience \ 先audience | account-service | fraud-mcp-server | analyst-attribute-service |
|---|---|---|---|
| frontend | ALLOW | ALLOW | DENY |
| fraud-mcp-server | ALLOW | DENY | DENY |
| account-service | DENY | DENY | ALLOW |
| analyst-attribute-service | DENY | DENY | DENY |

- ALLOWは3マスのみ。frontendの行に2つALLOWがあるのは、frontendが1つのログイントークン（`aud=frontend`）から、目的の異なる2つの単一audienceトークン（account-service向け・fraud-mcp-server向け）をそれぞれ個別のToken Exchangeで取得するため（[ADR 0005](adr/0005-single-audience-tokens-only.md)）。1つのトークンが複数audienceを同時に持つわけではない
- fraud-mcp-server→account-serviceの1マス以外、AIエージェント側の経路にはanalyst-attribute-serviceへの到達手段がない。ホップ飛ばし（例：fraud-mcp-serverが直接analyst-attribute-serviceを呼ぶ）は構造上不可能（各クライアントへの`optionalClientScopes`の割当のみで実現。Client Policiesは使わない）
- frontend→fraud-mcp-serverの交換で発行されるトークンは`account:read`のみを持ち、`account:freeze`は含まれない。これがAIエージェントに凍結実行権限を渡さないための核心の仕組み（表2参照）

## 表2: account-serviceのスコープ別操作可否（BR5・BR6に対応）

条件は「トークンが保有するスコープ」と「操作種別」の2軸。

| 操作 | 必要スコープ |
|---|---|
| 取引履歴・不審取引の照会（read） | `account:read` |
| 凍結提案の記録（propose） | `account:propose` |
| 口座凍結の実行（freeze） | `account:freeze`（実行時にanalyst-attribute-serviceへの再照会あり。表5参照） |
| 入出金・振込処理（transact） | `account:transact`（業務属性チェックなし） |

### どのトークンがどのスコープを保有するか

architecture.md §4のクライアント別スコープ割当を前提に、実際に発生する交換パスごとにトークンが保有するスコープを列挙したものが以下の表である。

| トークン | 発行経路 | 保有スコープ |
|---|---|---|
| frontendが発行するトークン（account-service宛て、確定パス用） | frontendが`aud=frontend`のログイントークンを`subject_token`にToken Exchange | `account:read`, `account:freeze` |
| frontendが発行するトークン（fraud-mcp-server宛て、提案生成パス用） | 同上、target audienceのみ異なる | `account:read`のみ |
| fraud-mcp-serverが発行するトークン（account-service宛て） | fraud-mcp-serverがToken Exchange | `account:read`, `account:propose` |
| payment-serviceのclient_credentialsトークン | client_credentials（委任チェーン外） | `account:transact`のみ |

fraud-mcp-server（ひいてはAIエージェント）が`account:freeze`を持つ経路は存在しない。凍結を実行できるのは、frontendが確定パス用に発行するトークンのみであり、これはアナリストがUIで決定論的操作（「凍結を確定」ボタン）を行った場合にのみ発行・使用される。

### scopeチェックの実施箇所（MUST）

この表のスコープチェックは、**Envoyサイドカーの受信側（アプリの外）で行うか、やむを得ずaccount-serviceのアプリ内で行う場合もリクエストの入口（ハンドラの先頭、表5のABAC判定より前）でのみ**行う。ビジネスロジックの途中や、表5のABAC判定の後にスコープチェックを行ってはならない。理由は[ADR 0006](adr/0006-claim-vs-external-attribute-criteria.md)を参照。

## 表3: analyst-attribute-serviceの照会可否（BR4に対応）

account-service以外の経路（fraud-mcp-server等）がanalyst-attribute-serviceへ直接到達できないことを保証する表。これにより、表5のABAC判定は必ずaccount-serviceを経由した最新の属性照会に基づいて行われ、BR4（AIエージェントの閲覧範囲はアナリスト本人を超えない）の前提が成り立つ。

| 呼び出し元 | 照会可否 |
|---|---|
| account-service（`aud=account-service`のトークンを`subject_token`に交換、scope=`analyst:read`） | ALLOW |
| その他すべて | DENY |

## 表4: payment-serviceのaccount-serviceアクセス（Token Exchange対象外、BR7に対応）

payment-serviceはユーザー委任チェーンに参加しない機械間認証（client_credentials）のため、表1の委任トポロジーとは別枠で扱う。

| 認証方式 | スコープ | 業務属性チェック |
|---|---|---|
| client_credentials（payment-serviceの自クライアント） | `account:transact` | なし（スコープチェックのみ） |

## 表5: account-serviceの口座別アクセス可否（アナリスト経由、RBAC+ABAC、BR1・BR2・BR3に対応）

アナリスト経由のリクエスト（`account:read`/`account:propose`/`account:freeze`のいずれか）にのみ適用される。payment-serviceの`account:transact`には適用しない（表4、BR7）。

`sub`がアナリスト本人のまま委任チェーンを通じて維持されるため（表1）、この判定はfrontend直接・AIエージェント経由のどちらのリクエストであっても同じアナリスト本人の属性に対して行われる。これによりBR4（AIエージェントの閲覧範囲はアナリスト本人を超えない）が成り立つ。

条件は「アナリストの権限レベル」と「口座の地域一致・ティア」の2軸。

| 権限レベル \ 口座の地域・ティア | 担当地域一致・standard | 担当地域一致・high-value | 担当地域不一致 |
|---|---|---|---|
| senior | ALLOW | ALLOW | DENY |
| junior | ALLOW | DENY | DENY |
| 属性未登録 | DENY | DENY | DENY |

- 担当地域はアナリストごとに複数持てる（表6参照）
- 「地域不一致」は、読み取り系エンドポイントでは個別のDENYではなく**結果セットから除外**という形で現れる可能性がある（実装時に確定。use-cases.md参照）
- juniorがhigh-value口座の凍結を試みた場合、AIエージェント経由（提案止まり）でも人間の確定操作でも、この表に従ってaccount-serviceが拒否する

## 表6: テストアナリスト

| アナリスト | 担当地域 | 権限レベル |
|---|---|---|
| yamada-analyst | 東京 | junior |
| suzuki-senior | 東京, 大阪 | senior |
| tanaka-junior | 大阪 | junior |
