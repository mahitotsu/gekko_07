// 診断用ループバックAPI(ADR 0027)。Envoy ingress・Service・NetworkPolicy ingressのいずれにも
// 繋がっていない(fraud-detection-engineはservices.mdの通り着信する経路を持たない)。
// scripts/verify-hop.shがPod内から`kubectl exec`で直接叩き、自律的な検知・凍結の実行結果を
// 確認するためだけに存在する。認可判定の対象ではないため、127.0.0.1にのみbindする
// (ADR 0009主対策①と同じ考え方)。

use axum::{extract::State, routing::get, Json, Router};
use std::sync::Arc;

use crate::db;
use crate::detector::AppState;

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/detections", get(list_detections))
        .with_state(state)
}

async fn healthz() -> &'static str {
    "ok"
}

async fn list_detections(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    match db::list_detections(&state.db).await {
        Ok(rows) => Json(serde_json::json!(rows)),
        Err(e) => Json(serde_json::json!({ "error": e.to_string() })),
    }
}
