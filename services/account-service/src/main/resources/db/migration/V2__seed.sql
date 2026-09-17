-- デモ・実機検証用の口座データ。id="123"はscripts/verify-hop.shが1ホップ先行検証の頃から
-- 直接参照しているIDのため据え置く。他は表5(ABAC)の全分岐をverify-hop.shで検証できるよう、
-- 地域・ティアの組み合わせを網羅する(ADR 0026)。

INSERT INTO accounts (id, region, tier, frozen) VALUES
    ('123', 'tokyo', 'standard',   TRUE),  -- yamada(junior)・suzuki(senior)ともにALLOW
    ('456', 'osaka', 'high-value', TRUE),  -- suzuki(senior)のみALLOW。tanaka(junior)はBR2でDENY
    ('789', 'tokyo', 'high-value', TRUE),  -- suzuki(senior)のみALLOW。yamada(junior)はBR2でDENY
    ('999', 'osaka', 'standard',   TRUE);  -- tanaka(junior)・suzuki(senior)がALLOW。yamadaは地域不一致でDENY

INSERT INTO freeze_records (account_id, reason, rule_fired, score) VALUES
    ('123', '短時間に連続する高額送金を検知', 'RULE_RAPID_TRANSFER', 0.8200),
    ('456', '普段と異なる国からのログイン後の送金を検知', 'RULE_GEO_ANOMALY', 0.9100),
    ('789', '短時間に連続する高額送金を検知', 'RULE_RAPID_TRANSFER', 0.7800),
    ('999', '普段と異なる受取先への初回送金を検知', 'RULE_NEW_PAYEE', 0.6500);

INSERT INTO transactions (account_id, amount, occurred_at, description) VALUES
    ('123', 1500000.00, now() - interval '2 hours', '振込 (受取人: 不明な口座)'),
    ('123',  980000.00, now() - interval '3 hours', '振込 (受取人: 不明な口座)'),
    ('456', 3200000.00, now() - interval '1 hours', '海外送金'),
    ('789', 1500000.00, now() - interval '2 hours', '振込 (受取人: 不明な口座)'),
    ('999',  450000.00, now() - interval '5 hours', '振込 (新規受取先)');
