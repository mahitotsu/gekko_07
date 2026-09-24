-- audit-serviceの突合をsub+時刻近接という近似一致から、jti(トークン識別子)完全一致へ
-- 切り替える(ADR 0044)。承認/却下・実行それぞれで使われたトークンのjti(account-serviceが
-- x-auth-jtiヘッダーとして受け取る値)を自己申告に含めることで、Keycloakのイベントログ・
-- account-service自身のEnvoyアクセスログの両方と決定的に突合できるようにする。

-- jtiを持たない既存の自己申告データは新しい突合ロジックでは意味を持たない(サポート対象外。
-- デモ用データのため、移行措置は設けず削除する。ユーザー指示)。
DELETE FROM unfreeze_executions;
DELETE FROM unfreeze_proposals;

-- decided_by_sub/decided_atと同様、決定前はNULL(pending)。
ALTER TABLE unfreeze_proposals ADD COLUMN decided_jti TEXT;

-- unfreeze_executionsは実行時に全カラムが確定した状態でのみ挿入される追記専用ログのため、
-- executed_by_sub/executed_atと同じくNOT NULL。
ALTER TABLE unfreeze_executions ADD COLUMN executed_jti TEXT NOT NULL;
