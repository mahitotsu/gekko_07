-- ADR 0027: デモ用の凍結状態は、V2__seed.sqlによる事前投入ではなく、fraud-detection-engine
-- 自身の自動検知・凍結実行(UC0)で作り出す形へ置き換えた。V2は既に適用済みの環境がある
-- (Flywayはchecksumを検証するため本文を書き換えられない)ため、取り消しは新規マイグレーションで行う。
-- 取引データ(transactions)はfraud-detection-engineの観測シグナルとは独立のデモデータのため残す。

UPDATE accounts SET frozen = FALSE;
DELETE FROM freeze_records;
