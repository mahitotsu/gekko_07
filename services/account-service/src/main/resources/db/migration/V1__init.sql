-- services.md: account-serviceの保有データ(口座・取引履歴・凍結記録・凍結解除提案・
-- 凍結解除実行記録)。regionは表5・表6が使う"tokyo"/"osaka"の内部コードで統一する
-- (analyst-attribute-serviceのanalystsテーブルと同じコードを使う。ADR 0026)。

CREATE TABLE accounts (
    id      TEXT PRIMARY KEY,
    region  TEXT NOT NULL CHECK (region IN ('tokyo', 'osaka')),
    tier    TEXT NOT NULL CHECK (tier IN ('standard', 'high-value')),
    frozen  BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE transactions (
    id          BIGSERIAL PRIMARY KEY,
    account_id  TEXT NOT NULL REFERENCES accounts(id),
    amount      NUMERIC(14, 2) NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL,
    description TEXT NOT NULL
);
CREATE INDEX idx_transactions_account_id ON transactions(account_id);

-- fraud-detection-engineによる自動凍結の判定根拠(UC0)。account:freezeはBR7によりABAC対象外。
CREATE TABLE freeze_records (
    id          BIGSERIAL PRIMARY KEY,
    account_id  TEXT NOT NULL REFERENCES accounts(id),
    reason      TEXT NOT NULL,
    rule_fired  TEXT NOT NULL,
    score       NUMERIC(5, 4),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- fraud-agentがfraud-mcp-server経由で記録する凍結解除提案(低リスク・可逆。BR8の追跡対象)。
CREATE TABLE unfreeze_proposals (
    id             TEXT PRIMARY KEY,
    account_id     TEXT NOT NULL REFERENCES accounts(id),
    reasoning      TEXT NOT NULL,
    proposed_by_sub TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- アナリストによる確定操作の実行記録(不可逆・高リスク。BR6・BR8)。proposal_idは
-- 「AIの提案に基づかない実行」(アナリストが独自に判断するケース)を許すためNULL可。
CREATE TABLE unfreeze_executions (
    id              BIGSERIAL PRIMARY KEY,
    account_id      TEXT NOT NULL REFERENCES accounts(id),
    proposal_id     TEXT REFERENCES unfreeze_proposals(id),
    executed_by_sub TEXT NOT NULL,
    executed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
