// 監視ループ本体(ADR 0027、UC0)。scope=account:freezeのみを持つ(access-control-design.md表4・
// BR7)ため、account-serviceへの呼び出しはfreeze以外に一切行わない。Authorizationヘッダーは
// アプリが持たず、Pod自身のEnvoy egress(ext_authzがclient_credentialsで取得)が透過的に付与する
// (architecture.md §3)ため、ここではhttp://account-service/...を実サービス名でそのまま呼ぶだけでよい。

use crate::db;
use tokio_postgres::Client;

pub struct AppState {
    pub db: Client,
    pub account_service_url: String,
    pub http: reqwest::Client,
}

pub async fn scan_once(state: &AppState) {
    let pending = match db::find_pending(&state.db).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("検知対象の照会に失敗しました: {e}");
            return;
        }
    };

    for detection in pending {
        match freeze(state, &detection).await {
            Ok(()) => {
                if let Err(e) = db::record_detection(&state.db, &detection.account_id).await {
                    eprintln!(
                        "口座{}の凍結実行後、検知記録に失敗しました(次周期で再度凍結依頼される可能性): {e}",
                        detection.account_id
                    );
                    continue;
                }
                println!(
                    "口座{}を凍結しました(rule={}, score={})",
                    detection.account_id, detection.rule_fired, detection.score
                );
            }
            Err(e) => {
                // フェイルオープンにしない:記録せず次のスキャン周期で再試行する。
                eprintln!("口座{}の凍結依頼に失敗しました: {e}", detection.account_id);
            }
        }
    }
}

async fn freeze(state: &AppState, detection: &db::PendingDetection) -> Result<(), String> {
    let url = format!(
        "{}/accounts/{}/freeze",
        state.account_service_url, detection.account_id
    );
    let body = serde_json::json!({
        "reason": detection.reason,
        "ruleFired": detection.rule_fired,
        "score": detection.score,
    });
    let resp = state
        .http
        .post(&url)
        .json(&body)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("account-serviceがステータス{}を返しました", resp.status()));
    }
    Ok(())
}
