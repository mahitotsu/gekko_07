# 権限マップ（ディシジョンテーブル）

[access-control-requirements.md](access-control-requirements.md)で定めた業務要件（BR1〜BR8）を、architecture.mdの認可設計がどう実現しているかを、条件と結果が漏れなく列挙できる形（ディシジョンテーブル）で示す。各表の見出しに対応する要件番号を明記し、業務要件と実装の対応関係を追跡できるようにする。性質の異なる認可判断ごとに表を分ける。

## 表1: 委任トポロジー（Keycloak層、BR5・BR6に対応）

条件は「要求元」と「要求先audience」の2軸。委任チェーンには「アナリスト自身のトークンをfrontendが中継するだけの区間」と「frontendが自らToken Exchangeを実行する区間」の両方が登場し、どちらも表面上は"frontend"に見えるため、行のラベルは実際にトークンを行使する主体の名前にしている（1.と2.の違い）。誰にも呼ばれない`frontend`は要求先の列からも外した。payment-serviceはToken Exchangeに参加しない（client_credentials）ため、この表には含めない（表4で別に扱う）。

1. **アナリスト**：frontendにログインした直後のトークンをそのまま使う。frontendは中継するだけで、これ自体はToken Exchangeではない
2. **frontend**：アナリストのトークンを`subject_token`として、frontend自身のクライアント資格情報でToken Exchange①を実行する主体
3. **fraud-mcp-server**：frontendが発行したトークンを`subject_token`として、Token Exchange②を実行する主体
4. **account-service**：Token Exchange③を実行する主体
5. **analyst-attribute-service**：チェーンの終端。誰も呼ばない

| 要求元 \ 要求先 | fraud-mcp-server | account-service | analyst-attribute-service |
|---|---|---|---|
| 1. アナリスト（frontendが中継、交換なし） | DENY | ALLOW | DENY |
| 2. frontend（Token Exchange①の実行者） | ALLOW | DENY | DENY |
| 3. fraud-mcp-server（Token Exchange②の実行者） | DENY | ALLOW | DENY |
| 4. account-service（Token Exchange③の実行者） | DENY | DENY | ALLOW |
| 5. analyst-attribute-service（チェーンの終端） | DENY | DENY | DENY |

- ALLOWは4マスのみ。委任チェーンは`アナリスト → frontend → fraud-mcp-server → account-service → analyst-attribute-service`の一本道で、ホップ飛ばし（例：fraud-mcp-serverが直接analyst-attribute-serviceを呼ぶ）は構造上不可能（各クライアントへの`optionalClientScopes`の割当のみで実現。Client Policiesは使わない）
- 2.（frontendが発行するトークン、audience=fraud-mcp-server）は`account:read`のみを持ち、`account:freeze`は含まれない。これがAIエージェントに凍結実行権限を渡さないための核心の仕組み（表2参照）

## 表2: account-serviceのスコープ別操作可否（BR5・BR6に対応）

条件は「トークンが保有するスコープ」と「操作種別」の2軸。

| 操作 | 必要スコープ |
|---|---|
| 取引履歴・不審取引の照会（read） | `account:read` |
| 凍結提案の記録（propose） | `account:propose` |
| 口座凍結の実行（freeze） | `account:freeze`（実行時にanalyst-attribute-serviceへの再照会あり。表5参照） |
| 入出金・振込処理（transact） | `account:transact`（業務属性チェックなし） |

### どのトークンがどのスコープを保有するか

| トークン（表1の番号） | 保有スコープ |
|---|---|
| 1. アナリストのログイントークン | `account:read`, `account:freeze` |
| 2. frontendが発行するトークン（fraud-mcp-server宛て） | `account:read`のみ |
| 3. fraud-mcp-serverが発行するトークン（account-service宛て） | `account:read`, `account:propose` |
| payment-serviceのclient_credentialsトークン | `account:transact`のみ |

fraud-mcp-server（ひいてはAIエージェント）が`account:freeze`を持つ経路は存在しない。凍結を実行できるのは1.のアナリストのログイントークンのみであり、これはアナリストがUIで決定論的操作（「凍結を確定」ボタン）を行った場合にのみ使われる。

## 表3: analyst-attribute-serviceの照会可否

| 呼び出し元 | 照会可否 |
|---|---|
| account-service（交換③、scope=`analyst:read`） | ALLOW |
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
