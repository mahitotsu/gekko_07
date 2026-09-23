-- AIの精査結論を「解除推奨」と「根拠なし(凍結維持)」の2種類に区別できるようにする(ADR 0039)。
-- status(pending/approved/rejected、人間の判断)とは独立した軸。既定値'unfreeze'は、この列を
-- 追加する前から存在した提案(=常に解除推奨だった)の意味をそのまま保つための後方互換値。
ALTER TABLE unfreeze_proposals
    ADD COLUMN recommendation TEXT NOT NULL DEFAULT 'unfreeze'
        CHECK (recommendation IN ('unfreeze', 'keep_frozen'));
