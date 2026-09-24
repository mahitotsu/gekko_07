# ADR 0045: 監査画面のsub表示に、解決できる場合はKeycloakのusernameを添える

- **Status**: Accepted
- **Date**: 2026-09-24

## Context

[ADR 0044](0044-audit-service-per-request-report.md)でリクエスト単位に再構成した監査画面（`/audit`）は、誰が提案・承認/却下・実行したかを`sub`（KeycloakのUUID）で表示している。閲覧者（senior analyst）にとってUUIDは他のどのアナリストか一目で判別しづらく、可読性の問題として指摘を受けた。

[ADR 0034](0034-frontend-display-username-instead-of-sub.md)で、ログイン中の本人の表示は`sub`から`preferred_username`へ変更済みだが、これはログイントークンのクレームを自分自身について読むだけの仕組みであり、監査画面のように**他人（過去に操作した任意のアナリスト）のsubをusernameへ解決する**用途には使えない。

Keycloakのイベントログ（[ADR 0025](0025-audit-log-aggregation.md)でLoki集約済み）には、audit-serviceが既に読んでいる`TOKEN_EXCHANGE`イベントに限らず、`LOGIN`等ほぼ全てのイベントに`userId`と`username`の組が記録されている。audit-serviceは既にこのログをLoki経由で読んでいるため、同じ経路で`userId`→`username`の対応表を作れる。

## Decision

### audit-service: `GET /reconcile`のレスポンスに`usernames`（sub→usernameの対応表）を追加する

Keycloakのイベントログから、`account:unfreeze`のTOKEN_EXCHANGEに限定せず対象期間内の全イベント（`userId`と`username`を含むもの）を対象に`userId`→`username`の対応表を作り、`usernames`フィールドとしてレスポンスに含める。対象を絞らない理由は、提案者（`proposedBySub`）は`account:unfreeze`のToken Exchangeを一度も行わない（提案作成は`account:propose`スコープ）ため、対象を絞ると解決できないケースが生じるため。

この対応表は**表示専用の補助情報であり、突合の判定には一切使わない**。判定基準（jtiの完全一致、ADR 0044）はこれまで通り変更しない。解決できなかった`sub`（対象期間内にKeycloakのイベントログに現れなかった等）は対応表に含めず、取得自体に失敗した場合も画面全体を止めずに空の対応表で応答する（`log.Printf`で記録するのみ）。usernameの解決可否が監査結果の閲覧可否や正しさに影響してはならないため。

### frontend: `sub`を表示している箇所で、解決できればusernameを表示する

`pages/audit.vue`の提案者・決定者・実行者の表示を、`usernames`にエントリがあればusernameを、無ければ`sub`をそのまま表示するように変更する。`sub`自体は`title`属性（ホバーで確認可能）として残し、閲覧者が正確な識別子を必要とする場合に確認できるようにする。

## Consequences

- 影響範囲：`services/audit-service/main.go`（`fetchUsernames`新設、`reconcileResult.Usernames`追加）、`services/frontend/pages/audit.vue`（`nameOf`ヘルパー追加、表示箇所の変更）、`docs/services.md`（audit-service節に`usernames`の説明を追記）
- 破壊的変更なし：既存フィールドの意味・突合ロジックは変更せず、`usernames`フィールドを追加するのみ
- `docs/architecture.md`は、§9の突合ロジック自体の説明に変更が無いため更新不要（`usernames`は表示専用の補助情報であり、architecture.mdが記述する「現在有効なアーキテクチャの断面」＝突合の判定基準には影響しない）
