#!/bin/bash
# 監査ログ集約基盤(Alloy+otel-lgtm)の実機検証(ADR 0025)。
# 前提:make deploy && make deploy-observability && make deploy-verify-hopが完了していること。
#
# scripts/verify-hop.shと同じ要領でfrontendにログインし、実際の委任チェーンを1本流したうえで、
# Loki(otel-lgtm)へ直接LogQLクエリを投げて以下を確認する(GrafanaのUIは介さない。scriptable
# であることを優先):
# 1. Envoyのアクセスログ(k8s/*/envoy-configmap.yamlのaccess_log、ADR 0025)に、ログインで得た
#    sub(yamada-analystのuser id)が実際に記録されていること
# 2. Keycloakのイベントログ(eventsEnabled、k8s/keycloak/realm-configmap.yaml)に、同じユーザーの
#    TOKEN_EXCHANGEイベント(userId/username)が記録されていること
set -euo pipefail

NAMESPACE=gekko
SECRETS_DIR=.secrets
LOCAL_EDGE_PORT=18080
LOCAL_LOKI_PORT=13100

YAMADA_ANALYST_PASSWORD=$(cat "$SECRETS_DIR/yamada-analyst-password")

echo "==> edge-proxy・otel-lgtm(Loki)へport-forward中..."
kubectl -n "$NAMESPACE" port-forward svc/edge-proxy "$LOCAL_EDGE_PORT":80 >/tmp/verify-observability-edge-portforward.log 2>&1 &
EDGE_PF_PID=$!
kubectl -n observability port-forward svc/otel-lgtm "$LOCAL_LOKI_PORT":3100 >/tmp/verify-observability-loki-portforward.log 2>&1 &
LOKI_PF_PID=$!
cleanup() {
  kill "$EDGE_PF_PID" "$LOKI_PF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://localhost:$LOCAL_EDGE_PORT/realms/gekko" && break
  sleep 1
done
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://localhost:$LOCAL_LOKI_PORT/ready" && break
  sleep 1
done

EDGE="http://localhost:$LOCAL_EDGE_PORT"
LOKI="http://localhost:$LOCAL_LOKI_PORT"

echo "==> 0. yamada-analystがfrontendの/loginでログイン"
LOGIN_TOKEN=$(curl -s -X POST "$EDGE/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"yamada-analyst\",\"password\":\"$YAMADA_ANALYST_PASSWORD\"}" | jq -r .access_token)
if [ "$LOGIN_TOKEN" = "null" ] || [ -z "$LOGIN_TOKEN" ]; then
  echo "ログイントークンの取得に失敗しました" >&2
  exit 1
fi

# access tokenのpayload(2番目のセグメント)をbase64url decodeしてsubクレームを取り出す
# (ADR 0025:frontendクライアントにsubjectclaim mapperを追加済みのため、ログイントークン
# 自体にsubが乗るようになった)。
SUB=$(python3 -c "
import base64, json, sys
t = sys.argv[1]
p = t.split('.')[1]
p += '=' * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p)).get('sub', ''))
" "$LOGIN_TOKEN")
if [ -z "$SUB" ]; then
  echo "ログイントークンにsubクレームがありません(ADR 0025のsubject-claimマッパーが効いていない可能性)" >&2
  exit 1
fi
echo "sub=$SUB"

echo "==> 1. frontend経由でaccount-serviceのGETを叩き、fraud-agent経由でfraud-mcp-serverのchatも叩く(委任チェーンを実際に1本流す)"
curl -s -o /dev/null -X GET "$EDGE/accounts/123/transactions" -H "Authorization: Bearer $LOGIN_TOKEN"
curl -s -o /dev/null -X POST "$EDGE/chat" -H "Authorization: Bearer $LOGIN_TOKEN" -d '{}'

echo "==> ログ集約の反映を待機中(Alloyのtail間隔・Lokiの取り込みに数秒かかる)..."
sleep 10

query_loki() {
  local logql="$1"
  curl -s -G "$LOKI/loki/api/v1/query_range" \
    --data-urlencode "query=$logql" \
    --data-urlencode "start=$(date -u -d '5 minutes ago' +%s)000000000" \
    --data-urlencode "end=$(date -u +%s)000000000" \
    --data-urlencode "limit=20"
}

echo "==> 2. Envoyアクセスログ(account-service/frontend/fraud-agent)にこのsubが記録されていることを確認"
ENVOY_HITS=$(query_loki "{namespace=\"gekko\", container=\"envoy\"} |= \"$SUB\"" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(len(s['values']) for s in d['data']['result']))
")
echo "Envoyアクセスログでの一致件数: $ENVOY_HITS"
if [ "$ENVOY_HITS" -lt 1 ]; then
  echo "Envoyアクセスログにsubが見つかりませんでした" >&2
  exit 1
fi
echo "Envoyアクセスログでの相関確認(期待通り。ADR 0025)"

echo "==> 3. Keycloakイベントログ(TOKEN_EXCHANGE)にこのユーザーのイベントが記録されていることを確認"
KEYCLOAK_HITS=$(query_loki "{container=\"keycloak\"} |= \"TOKEN_EXCHANGE\" |= \"$SUB\"" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(len(s['values']) for s in d['data']['result']))
")
echo "Keycloakイベントログでの一致件数: $KEYCLOAK_HITS"
if [ "$KEYCLOAK_HITS" -lt 1 ]; then
  echo "Keycloakイベントログにこのユーザーのイベントが見つかりませんでした" >&2
  exit 1
fi
echo "Keycloakイベントログでの相関確認(期待通り。ADR 0025)"

echo "==> 検証完了"
