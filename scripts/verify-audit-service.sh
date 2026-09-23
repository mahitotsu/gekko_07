#!/bin/bash
# audit-serviceの実機検証(ADR 0040/0041)。
# 前提:make deploy && make deploy-verify-hop && make verify-hop が完了していること
# (account-serviceに実際の凍結解除実行記録が、Keycloak/Envoyのログに対応するTOKEN_EXCHANGE
# イベントが、それぞれ実在する状態を作る)。
#
# audit-serviceへkubectl port-forwardし、GET /reconcileを呼んで以下を確認する:
# 1. account-serviceの自己申告(unfreeze_executions)が1件以上取得できること
# 2. それら全てに対応するKeycloakの第三者記録(TOKEN_EXCHANGE、account:unfreeze)が見つかり、
#    unverifiedが0件であること(自己申告と第三者記録が矛盾なく突合できることの実証)
#
# 自己申告のみを改ざんした場合にunverifiedとして検知されること自体は、account-serviceの
# DB認証情報を直接操作する必要がありこのスクリプトの範囲外のため、
# services/audit-service/main_test.go(hasMatch関数のユニットテスト)で決定的に検証している。
set -euo pipefail

NAMESPACE=gekko
LOCAL_AUDIT_PORT=19000
SINCE=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)

echo "==> audit-serviceへport-forward中..."
kubectl -n "$NAMESPACE" port-forward svc/audit-service "$LOCAL_AUDIT_PORT":8080 >/tmp/verify-audit-service-portforward.log 2>&1 &
PF_PID=$!
cleanup() {
  kill "$PF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://localhost:$LOCAL_AUDIT_PORT/healthz" && break
  sleep 1
done

echo "==> GET /reconcile?since=$SINCE"
RESULT=$(curl -s "http://localhost:$LOCAL_AUDIT_PORT/reconcile?since=$SINCE")
echo "$RESULT" | jq .

EXEC_TOTAL=$(echo "$RESULT" | jq '.executions.total')
EXEC_VERIFIED=$(echo "$RESULT" | jq '.executions.verified')
EXEC_UNVERIFIED_COUNT=$(echo "$RESULT" | jq '.executions.unverified | length')

if [ "$EXEC_TOTAL" -lt 1 ]; then
  echo "自己申告(unfreeze_executions)が1件も取得できませんでした。make verify-hopを先に実行してください" >&2
  exit 1
fi
if [ "$EXEC_VERIFIED" -ne "$EXEC_TOTAL" ] || [ "$EXEC_UNVERIFIED_COUNT" -ne 0 ]; then
  echo "自己申告と第三者記録(Keycloakイベントログ)の突合に失敗した項目があります" >&2
  exit 1
fi

echo "==> 検証成功: 自己申告${EXEC_TOTAL}件全てに対応する第三者記録(Keycloak TOKEN_EXCHANGE)が見つかりました"
