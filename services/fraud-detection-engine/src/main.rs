// fraud-detection-engineの本実装(ADR 0007:Rust/Axum、ADR 0027)。
//
// 取引パターンを監視し、疑わしい口座を自動的に凍結する(UC0)。ユーザー委任チェーンには
// 参加せず、account-serviceへは常にclient_credentials(scope=account:freeze)でのみアクセスする
// (access-control-design.md表4)。ADR 0009 §2の多層防御(loopback限定bind等)のうち、合言葉
// ヘッダー検証はこのサービスには適用されない(Envoy ingressの受け口を持たないため)。

mod db;
mod detector;
mod http_api;

use std::sync::Arc;
use std::time::Duration;

#[tokio::main]
async fn main() {
    let client = db::connect().await;
    db::init_schema(&client).await;
    db::seed(&client).await;

    let account_service_url =
        std::env::var("ACCOUNT_SERVICE_URL").unwrap_or_else(|_| "http://account-service".into());
    let scan_interval_secs: u64 = std::env::var("SCAN_INTERVAL_SECONDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(5);

    let state = Arc::new(detector::AppState {
        db: client,
        account_service_url,
        http: reqwest::Client::new(),
    });

    {
        let state = state.clone();
        tokio::spawn(async move {
            loop {
                detector::scan_once(&state).await;
                tokio::time::sleep(Duration::from_secs(scan_interval_secs)).await;
            }
        });
    }

    let bind_host = std::env::var("APP_BIND_HOST").unwrap_or_else(|_| "127.0.0.1".into());
    let bind_port = std::env::var("APP_PORT").unwrap_or_else(|_| "9000".into());
    let addr = format!("{bind_host}:{bind_port}");
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap_or_else(|e| panic!("failed to bind {addr}: {e}"));
    println!("fraud-detection-engine listening on {addr}");
    axum::serve(listener, http_api::router(state))
        .await
        .expect("server error");
}
