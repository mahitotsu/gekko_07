// fraud-detection-engineの本実装(ADR 0027)。ADR 0007のRust選定・analyst-attribute-service
// (Go標準ライブラリ)が確立した「ORM/マイグレーションフレームワークを持ち込まず、アプリ自身が
// 起動時にスキーマを用意する」方針をそのまま踏襲する。account-service(Flyway)と異なり、
// この方針の一貫性を優先した。

use serde::Serialize;
use std::time::Duration;
use tokio_postgres::{Client, Error, NoTls};

pub async fn connect() -> Client {
    let host = std::env::var("DB_HOST").unwrap_or_else(|_| "postgres".into());
    let port = std::env::var("DB_PORT").unwrap_or_else(|_| "5432".into());
    let name = std::env::var("DB_NAME").expect("DB_NAME is required");
    let user = std::env::var("DB_USER").expect("DB_USER is required");
    let password = std::env::var("DB_PASSWORD").expect("DB_PASSWORD is required");

    let conn_str = format!("host={host} port={port} dbname={name} user={user} password={password}");

    for attempt in 1..=30 {
        match tokio_postgres::connect(&conn_str, NoTls).await {
            Ok((client, connection)) => {
                tokio::spawn(async move {
                    if let Err(e) = connection.await {
                        eprintln!("postgres connection error: {e}");
                    }
                });
                return client;
            }
            Err(e) => {
                eprintln!("postgresへの接続待機中({attempt}/30): {e}");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
    panic!("timed out waiting for database");
}

pub async fn init_schema(client: &Client) {
    client
        .batch_execute(
            "
            CREATE TABLE IF NOT EXISTS detection_rules (
                name      TEXT PRIMARY KEY,
                threshold NUMERIC(5, 4) NOT NULL
            );
            CREATE TABLE IF NOT EXISTS signals (
                account_id TEXT PRIMARY KEY,
                rule_fired TEXT NOT NULL REFERENCES detection_rules(name),
                score      NUMERIC(5, 4) NOT NULL,
                reason     TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS detections (
                account_id TEXT PRIMARY KEY REFERENCES signals(account_id),
                frozen_at  TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            ",
        )
        .await
        .expect("failed to initialize schema");
}

// ADR 0027:本来は取引イベントストリームから供給されるべきデータだが、このプロジェクトには
// その上流基盤が無く、fraud-detection-engine自身もBR7によりaccount-serviceの取引を読み返せない
// (表4)。account-service旧V2__seed.sqlのfreeze_recordsが使っていたのと同じ4件を移送した固定
// シードで代用する(実運用ではここが実際の監視入力に置き換わる)。
pub async fn seed(client: &Client) {
    client
        .batch_execute(
            "
            INSERT INTO detection_rules (name, threshold) VALUES
                ('RULE_RAPID_TRANSFER', 0.75),
                ('RULE_GEO_ANOMALY',    0.85),
                ('RULE_NEW_PAYEE',      0.60)
            ON CONFLICT (name) DO NOTHING;

            INSERT INTO signals (account_id, rule_fired, score, reason) VALUES
                ('123', 'RULE_RAPID_TRANSFER', 0.8200, '短時間に連続する高額送金を検知'),
                ('456', 'RULE_GEO_ANOMALY',    0.9100, '普段と異なる国からのログイン後の送金を検知'),
                ('789', 'RULE_RAPID_TRANSFER', 0.7800, '短時間に連続する高額送金を検知'),
                ('999', 'RULE_NEW_PAYEE',      0.6500, '普段と異なる受取先への初回送金を検知')
            ON CONFLICT (account_id) DO NOTHING;
            ",
        )
        .await
        .expect("failed to seed detection data");
}

pub struct PendingDetection {
    pub account_id: String,
    pub rule_fired: String,
    pub score: f64,
    pub reason: String,
}

// score::float8: NUMERIC型をtokio-postgresへ直接マップするにはrust_decimal依存の追加が要る。
// SELECT時にキャストするだけで済ませ、追加の依存を増やさない(analyst-attribute-serviceが
// text[]専用のScannerを自前実装したのと同じ「必要最小限で済ませる」考え方)。
pub async fn find_pending(client: &Client) -> Result<Vec<PendingDetection>, Error> {
    let rows = client
        .query(
            "SELECT s.account_id, s.rule_fired, s.score::float8, s.reason
             FROM signals s
             JOIN detection_rules r ON r.name = s.rule_fired
             WHERE s.score >= r.threshold
               AND NOT EXISTS (SELECT 1 FROM detections d WHERE d.account_id = s.account_id)
             ORDER BY s.account_id",
            &[],
        )
        .await?;
    Ok(rows
        .into_iter()
        .map(|row| PendingDetection {
            account_id: row.get(0),
            rule_fired: row.get(1),
            score: row.get(2),
            reason: row.get(3),
        })
        .collect())
}

pub async fn record_detection(client: &Client, account_id: &str) -> Result<(), Error> {
    client
        .execute(
            "INSERT INTO detections (account_id) VALUES ($1) ON CONFLICT (account_id) DO NOTHING",
            &[&account_id],
        )
        .await?;
    Ok(())
}

#[derive(Serialize)]
pub struct DetectionView {
    #[serde(rename = "accountId")]
    pub account_id: String,
    #[serde(rename = "ruleFired")]
    pub rule_fired: String,
    pub score: f64,
    pub reason: String,
    #[serde(rename = "frozenAt")]
    pub frozen_at: String,
}

pub async fn list_detections(client: &Client) -> Result<Vec<DetectionView>, Error> {
    let rows = client
        .query(
            "SELECT s.account_id, s.rule_fired, s.score::float8, s.reason, d.frozen_at::text
             FROM detections d
             JOIN signals s ON s.account_id = d.account_id
             ORDER BY d.frozen_at",
            &[],
        )
        .await?;
    Ok(rows
        .into_iter()
        .map(|row| DetectionView {
            account_id: row.get(0),
            rule_fired: row.get(1),
            score: row.get(2),
            reason: row.get(3),
            frozen_at: row.get(4),
        })
        .collect())
}
