#!/bin/bash
# audit-serviceの実機検証(ADR 0040/0041/0042)。
# 前提:make deploy && make deploy-verify-hop && make verify-hop が完了していること
# (account-serviceに実際の凍結解除実行記録が、Keycloak/Envoyのログに対応するTOKEN_EXCHANGE
# イベントが、それぞれ実在する状態を作る)。
#
# ADR 0042でaudit-serviceのingressにmTLS+jwt_authn+rbac(audit:read限定)を追加したため、
# kubectl port-forwardへの素のcurl(ADR 0040/0041時点の検証方法)ではmTLSハンドシェイクで
# 弾かれ到達できない。本スクリプトはscripts/verify-hop.shと同じ実機ログイン手法
# (login_via_frontend)でfrontend経由の正規の経路を通す:
# 1. senior analyst(suzuki-senior)でログインし、GET /reconcile(frontend→audit-serviceへの
#    Token Exchange委任)が200で、自己申告全件が第三者記録(Keycloak TOKEN_EXCHANGE)と
#    一致することを確認する
# 2. junior analyst(yamada-analyst)でログインすると、同じGET /reconcileが403で拒否される
#    ことを確認する(senior限定閲覧ゲート、audit-service側でanalyst-attribute-serviceに
#    照会して判定)
set -euo pipefail

NAMESPACE=gekko
SECRETS_DIR=.secrets
LOCAL_EDGE_PORT=18081
EDGE="http://localhost:$LOCAL_EDGE_PORT"

echo "==> edge-proxyへport-forward中..."
kubectl -n "$NAMESPACE" port-forward svc/edge-proxy "$LOCAL_EDGE_PORT":80 >/tmp/verify-audit-service-edge-portforward.log 2>&1 &
EDGE_PF_PID=$!
cleanup() {
  kill "$EDGE_PF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 20); do
  curl -s -o /dev/null "$EDGE/realms/gekko" && break
  sleep 1
done

# scripts/verify-hop.shのlogin_via_frontend/keycloak_login_form_postと同じ実機ログイン手法
# (ヘッドレスブラウザなしでKeycloakのform_postログインフォームをcurlで直接POSTする)。
login_via_frontend() {
  local username="$1" password="$2" jar="$3"
  rm -f "$jar"
  local authorize_url
  authorize_url=$(curl -s -D - -o /dev/null -c "$jar" "$EDGE/login" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')
  authorize_url="$EDGE$(echo "$authorize_url" | sed -E 's#^https?://[^/]+##')"
  keycloak_login_form_post "$authorize_url" "$username" "$password" "$jar"
}

keycloak_login_form_post() {
  local authorize_url="$1" username="$2" password="$3" jar="$4"
  local login_page form_action body callback_action code state session_state iss
  login_page=$(curl -s -c "$jar" -b "$jar" "$authorize_url")
  form_action=$(printf '%s' "$login_page" | grep -o 'action="[^"]*"' | head -1 | sed -E 's/^action="//; s/"$//' | sed 's/&amp;/\&/g')
  if [ -z "$form_action" ]; then
    echo "Keycloakログインフォームのaction属性を取得できませんでした" >&2
    return 1
  fi
  form_action="$EDGE$(echo "$form_action" | sed -E 's#^https?://[^/]+##')"
  body=$(curl -s -c "$jar" -b "$jar" \
    --data-urlencode "username=$username" --data-urlencode "password=$password" \
    "$form_action")
  callback_action=$(printf '%s' "$body" | grep -ioP 'action="\K[^"]+' | head -1 | sed 's/&amp;/\&/g')
  if [ -z "$callback_action" ]; then
    echo "response_mode=form_postの自動送信フォームを取得できませんでした($username)" >&2
    return 1
  fi
  callback_action="$EDGE$(echo "$callback_action" | sed -E 's#^https?://[^/]+##')"
  code=$(printf '%s' "$body" | grep -ioP 'name="code"\s+value="\K[^"]*')
  state=$(printf '%s' "$body" | grep -ioP 'name="state"\s+value="\K[^"]*')
  session_state=$(printf '%s' "$body" | grep -ioP 'name="session_state"\s+value="\K[^"]*')
  iss=$(printf '%s' "$body" | grep -ioP 'name="iss"\s+value="\K[^"]*')
  if [ -z "$code" ] || [ -z "$state" ]; then
    echo "frontend経由のログインでcode/stateを取得できませんでした($username)" >&2
    return 1
  fi
  curl -s -o /dev/null -c "$jar" -b "$jar" \
    --data-urlencode "code=$code" --data-urlencode "state=$state" \
    --data-urlencode "session_state=$session_state" --data-urlencode "iss=$iss" \
    "$callback_action"
}

SENIOR_JAR=$(mktemp)
JUNIOR_JAR=$(mktemp)
SENIOR_BODY=$(mktemp)
JUNIOR_BODY=$(mktemp)
trap 'cleanup; rm -f "$SENIOR_JAR" "$JUNIOR_JAR" "$SENIOR_BODY" "$JUNIOR_BODY"' EXIT

echo "==> 1. suzuki-senior(senior)でログインし、GET /reconcileを叩く"
login_via_frontend "suzuki-senior" "$(cat "$SECRETS_DIR/suzuki-senior-password")" "$SENIOR_JAR"
SENIOR_STATUS=$(curl -s -o "$SENIOR_BODY" -w '%{http_code}' -b "$SENIOR_JAR" "$EDGE/reconcile")
echo "senior status: $SENIOR_STATUS"
cat "$SENIOR_BODY"
echo
if [ "$SENIOR_STATUS" != "200" ]; then
  echo "senior analystがGET /reconcileで200を得られませんでした" >&2
  exit 1
fi

EXEC_TOTAL=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['executions']['total'])" "$SENIOR_BODY")
EXEC_VERIFIED=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['executions']['verified'])" "$SENIOR_BODY")
if [ "$EXEC_TOTAL" -lt 1 ]; then
  echo "自己申告(unfreeze_executions)が1件も取得できませんでした。make verify-hopを先に実行してください" >&2
  exit 1
fi
if [ "$EXEC_VERIFIED" != "$EXEC_TOTAL" ]; then
  echo "自己申告と第三者記録(Keycloakイベントログ)の突合に失敗した項目があります" >&2
  exit 1
fi
echo "==> 自己申告${EXEC_TOTAL}件全てに対応する第三者記録が見つかりました"

echo "==> 2.(異常系)yamada-analyst(junior)でログインし、GET /reconcileが403になることを確認"
login_via_frontend "yamada-analyst" "$(cat "$SECRETS_DIR/yamada-analyst-password")" "$JUNIOR_JAR"
JUNIOR_STATUS=$(curl -s -o "$JUNIOR_BODY" -w '%{http_code}' -b "$JUNIOR_JAR" "$EDGE/reconcile")
echo "junior status: $JUNIOR_STATUS"
if [ "$JUNIOR_STATUS" != "403" ]; then
  echo "junior analystのGET /reconcileが403で拒否されませんでした(実際: $JUNIOR_STATUS)" >&2
  exit 1
fi

echo "==> 検証成功: senior=200(自己申告${EXEC_TOTAL}件全て突合成功)、junior=403(senior限定ゲート)"
