# ADR 0005: トークンは常に単一audienceのみを持つ

- **Status**: Accepted
- **Date**: 2026-09-13

## Context

Token Exchangeで発行するトークンが複数のaudienceを同時に持つことを許すか、常に単一audienceに限定するかを検討した。

複数audienceを許す設計（例：frontendのログイントークンが最初からaccount-serviceを含む複数のaudienceを持つ）には以下の問題がある。

- あるサービスが受け取ったトークンの`aud`配列に自分以外の想定外の値が含まれていても、検証実装（「配列に自分の名前が含まれるか」という緩い判定）によっては見逃してしまう、オーディエンス混同のバグを構造的に許してしまう
- 「元audienceから先audienceへの交換可否」という認可トポロジー（[access-control-design.md](../access-control-design.md) 表1）を一意に定義しづらくなる。複数audienceだと「どのaudienceを基準に判定するか」が曖昧になる
- frontendが「ログイントークンをそのままaccount-serviceに使う経路」と「Token Exchangeで別audienceへ交換する経路」という2種類の異なるメカニズムが混在し、委任トポロジー表の行が実体（トークンの`aud`）と一致しなくなる

## Decision

**全てのトークンは常に単一のaudienceのみを持つ**。これに伴い、以下を統一する。

- ログイン直後のトークンは`aud=frontend`（frontend自身。単一）のみを持ち、それ以上の意味（特定のリソースサーバー向けスコープ）を持たせない
- frontendがaccount-serviceにアクセスする経路（ダッシュボード表示・凍結解除確定）も、ログイントークンを直接使う特別扱いをやめ、frontend自身が明示的にToken Exchangeを実行して`aud=account-service`の単一audienceトークンを得る、という形に統一する
- AIエージェントへの委任も同様に、frontendが別の明示的なToken Exchangeで`aud=fraud-agent`の単一audienceトークンを得る（〔[ADR 0014](0014-fraud-agent-token-exchange.md)で訂正〕当初は`aud=fraud-mcp-server`だった）
- 以降のホップ（fraud-agent→fraud-mcp-server、fraud-mcp-server→account-service、account-service→analyst-attribute-service）もすべて単一audienceの交換として一様に扱う

## Consequences

- 全ての「audienceの移動」が明示的なToken Exchangeとして一様に表現され、委任トポロジー表（[access-control-design.md](../access-control-design.md) 表1）を「元audience→先audience」という単純な行列として矛盾なく記述できる。frontendの直接アクセス経路も含めて全てが同じメカニズムを通るため、実装・監査の一貫性が増す
- 1つの元トークン（`aud=frontend`）から、目的の異なる複数のToken Exchangeが並行して発生しうる（account-service向けとfraud-agent向けをそれぞれ別に取得する）。これは単一audienceの制約に違反しない。「1トークンが複数audienceを持つ」ことと「1つの元トークンから複数の異なる単一audienceトークンを個別に発行できる」ことは別の話である
- frontendがaccount-serviceへの操作のたびに明示的なToken Exchangeを挟むことになり、レイテンシが増える。Token Exchange結果のキャッシュで緩和できる（[backlog.md](../backlog.md)参照）
