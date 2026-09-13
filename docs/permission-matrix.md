# 権限マップ（ディシジョンテーブル）

architecture.mdで決めた認可設計を、条件と結果が漏れなく列挙できる形（ディシジョンテーブル）で整理する。性質の異なる認可判断ごとに表を分ける。

## 表1: 委任トポロジー（Keycloak層）

条件は「要求元（トークンの入手経路）」と「要求先audience」の2軸。frontendは「直接ログイン」と「fraud-mcp-server宛ての交換」の2種類のトークンを使い分けるため、別の行として扱う。payment-serviceはToken Exchangeに参加しない（client_credentials）ため、この表には含めない（表4で別に扱う）。

| 要求元 \ 要求先 | frontend | fraud-mcp-server | account-service | analyst-attribute-service |
|---|---|---|---|---|
| frontend（直接ログイン） | DENY | DENY | ALLOW | DENY |
| frontend（交換①、audience=fraud-mcp-server, scope=account:read） | DENY | ALLOW | DENY | DENY |
| fraud-mcp-server（交換②、audience=account-service） | DENY | DENY | ALLOW | DENY |
| account-service（交換③、audience=analyst-attribute-service） | DENY | DENY | DENY | ALLOW |
| analyst-attribute-service | DENY | DENY | DENY | DENY |

- ALLOWは4マスのみ。委任チェーンは`frontend → fraud-mcp-server → account-service → analyst-attribute-service`の一本道で、ホップ飛ばし（例：fraud-mcp-serverが直接analyst-attribute-serviceを呼ぶ）は構造上不可能（各クライアントへの`optionalClientScopes`の割当のみで実現。Client Policiesは使わない）
- 「frontend（交換①）」で発行されるトークンは`account:read`のみを持ち、`account:freeze`は含まれない。これがAIエージェントに凍結実行権限を渡さないための核心の仕組み（表2参照）

## 表2: account-serviceのスコープ別操作可否

条件は「トークンが保有するスコープ」と「操作種別」の2軸。

| 操作 | 必要スコープ |
|---|---|
| 取引履歴・不審取引の照会（read） | `account:read` |
| 凍結提案の記録（propose） | `account:propose` |
| 口座凍結の実行（freeze） | `account:freeze`（実行時にanalyst-attribute-serviceへの再照会あり。表5参照） |
| 入出金・振込処理（transact） | `account:transact`（業務属性チェックなし） |

### どのトークンがどのスコープを保有するか

| 発行対象 | 保有スコープ |
|---|---|
| frontendの直接ログイントークン | `account:read`, `account:freeze` |
| frontendが交換発行するトークン（fraud-mcp-server宛て） | `account:read`のみ |
| fraud-mcp-serverが交換発行するトークン（account-service宛て） | `account:read`, `account:propose` |
| payment-serviceのclient_credentialsトークン | `account:transact`のみ |

fraud-mcp-server（ひいてはAIエージェント）が`account:freeze`を持つ経路は存在しない。凍結を実行できるのはfrontendの直接ログイントークンのみであり、これはアナリストがUIで決定論的操作（「凍結を確定」ボタン）を行った場合にのみ使われる。

## 表3: analyst-attribute-serviceの照会可否

| 呼び出し元 | 照会可否 |
|---|---|
| account-service（交換③、scope=`analyst:read`） | ALLOW |
| その他すべて | DENY |

## 表4: payment-serviceのaccount-serviceアクセス（Token Exchange対象外）

payment-serviceはユーザー委任チェーンに参加しない機械間認証（client_credentials）のため、表1の委任トポロジーとは別枠で扱う。

| 認証方式 | スコープ | 業務属性チェック |
|---|---|---|
| client_credentials（payment-serviceの自クライアント） | `account:transact` | なし（スコープチェックのみ） |

## 表5: account-serviceの口座別アクセス可否（アナリスト経由、RBAC+ABAC）

アナリスト経由のリクエスト（`account:read`/`account:propose`/`account:freeze`のいずれか）にのみ適用される。payment-serviceの`account:transact`には適用しない（表4）。

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
