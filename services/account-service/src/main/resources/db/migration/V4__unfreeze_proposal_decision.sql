-- 凍結解除提案に承認/却下の状態遷移を追加する(ADR 0036)。propose_unfreeze直後はpending。
-- 承認・却下はいずれも「提案を依頼した本人アナリスト」のみが行える(4-eyesは導入しない。
-- account-service/AccountController.javaのdecide()で検証)。
ALTER TABLE unfreeze_proposals
    ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'rejected')),
    ADD COLUMN decided_by_sub TEXT,
    ADD COLUMN decided_at TIMESTAMPTZ;

-- ダッシュボード(GET /accounts/frozen)・chat.vue再訪時の「口座ごとの最新提案」照会
-- (AccountRepository.findLatestProposal)向け。findLatestFreezeRecordと同種の用途。
CREATE INDEX idx_unfreeze_proposals_account_id_created_at
    ON unfreeze_proposals (account_id, created_at DESC);
