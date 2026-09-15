#!/bin/bash
# account-serviceへの1ホップ先行検証(ADR 0002/0009/0010)。
# 前提:make deploy && make deploy-verify-hopでstub一式がデプロイ済みであること。
#
# パターン①(Token Exchange、fraud-mcp-server→account-service):
# 1. yamada-analystとしてROPCログイン(aud=frontend)
# 2. frontendがToken Exchangeでfraud-mcp-server宛てトークン(scope=account:read)を発行
#    (フロントエンド未実装のため、frontendが将来行う処理を直接Keycloakに対して行い代用する)
# 3. そのトークンを持ってfraud-mcp-server-stub Pod内からaccount-serviceを叩き、
#    Envoy egress(ext_authzによるToken Exchange)→Envoy ingress(jwt_authn/rbac/合言葉)→
#    account-service-stubアプリ、という経路全体が正しく動くことを確認する
# 4. account-service-stubのアプリポートにPod外から直接到達できないことを確認する(ADR 0009主対策①)
#
# パターン②(client_credentials、fraud-detection-engine→account-service):
# 5. fraud-detection-engine-stub Pod内から、Authorizationヘッダーを一切持たずにaccount-serviceの
#    freezeエンドポイントを叩き、Envoy egress(ext_authzによるclient_credentials取得)→
#    Envoy ingress(jwt_authn/rbac/合言葉)という経路が正しく動くことを確認する
set -euo pipefail

NAMESPACE=gekko
SECRETS_DIR=.secrets
LOCAL_KC_PORT=18080

# make deploy-verify-hopはスタブPodを常に再起動する(Makefile参照)ため、直後に実行すると
# 旧Podがterminating中でも`-l`セレクタのlist順で先頭に来ることがある(phaseはterminating中も
# Runningのまま)。creationTimestampで最新のPodを選ぶことで、terminating中の旧Podを掴まないようにする。
newest_pod() {
  kubectl -n "$NAMESPACE" get pod -l "app=$1" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tail -1
}

FRONTEND_CLIENT_SECRET=$(cat "$SECRETS_DIR/frontend-client-secret")
YAMADA_ANALYST_PASSWORD=$(cat "$SECRETS_DIR/yamada-analyst-password")

echo "==> Keycloakへport-forward中..."
kubectl -n "$NAMESPACE" port-forward svc/keycloak "$LOCAL_KC_PORT":8080 >/tmp/verify-hop-portforward.log 2>&1 &
PF_PID=$!
cleanup() {
  kill "$PF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://localhost:$LOCAL_KC_PORT/realms/gekko" && break
  sleep 1
done

KC="http://localhost:$LOCAL_KC_PORT"

echo "==> 1. yamada-analystとしてROPCログイン(aud=frontend)"
LOGIN_TOKEN=$(curl -s -X POST "$KC/realms/gekko/protocol/openid-connect/token" \
  -d grant_type=password \
  -d client_id=frontend \
  -d client_secret="$FRONTEND_CLIENT_SECRET" \
  -d username=yamada-analyst \
  -d password="$YAMADA_ANALYST_PASSWORD" | jq -r .access_token)
if [ "$LOGIN_TOKEN" = "null" ] || [ -z "$LOGIN_TOKEN" ]; then
  echo "ログイントークンの取得に失敗しました" >&2
  exit 1
fi

echo "==> 2. frontendがfraud-mcp-server宛てにToken Exchange(scope=account:read)"
DELEGATED_TOKEN=$(curl -s -X POST "$KC/realms/gekko/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d client_id=frontend \
  -d client_secret="$FRONTEND_CLIENT_SECRET" \
  -d subject_token="$LOGIN_TOKEN" \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d audience=fraud-mcp-server \
  -d scope=account:read | jq -r .access_token)
if [ "$DELEGATED_TOKEN" = "null" ] || [ -z "$DELEGATED_TOKEN" ]; then
  echo "fraud-mcp-server宛てトークンの取得に失敗しました" >&2
  exit 1
fi

FRAUD_MCP_POD=$(newest_pod fraud-mcp-server)

call_account_service() {
  local method="$1" path="$2" token="$3"
  kubectl -n "$NAMESPACE" exec "$FRAUD_MCP_POD" -c app -- env \
    TOKEN="$token" METHOD="$method" URL="http://account-service${path}" \
    python3 -c '
import json, os, urllib.error, urllib.request
req = urllib.request.Request(os.environ["URL"], method=os.environ["METHOD"], headers={"Authorization": "Bearer " + os.environ["TOKEN"]})
if os.environ["METHOD"] == "POST":
    req.data = b"{}"
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(resp.status)
        print(resp.read().decode())
except urllib.error.HTTPError as e:
    print(e.code)
    print(e.read().decode())
'
}

echo "==> 3a. fraud-mcp-server egress Envoy経由でaccount-serviceのGET(account:read)を叩く"
call_account_service GET /accounts/123/transactions "$DELEGATED_TOKEN"

echo "==> 3b. fraud-mcp-server egress Envoy経由でaccount-serviceのPOST(account:propose)を叩く"
call_account_service POST /accounts/123/unfreeze-proposals "$DELEGATED_TOKEN"

echo "==> 3c.(異常系)aud=frontendのログイントークンでそのまま叩く(拒否されるはず)"
call_account_service GET /accounts/123/transactions "$LOGIN_TOKEN" || true

echo "==> 4. account-serviceのアプリポートへPod外から直接到達できないことを確認"
ACCOUNT_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$(newest_pod account-service)" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${ACCOUNT_POD_IP}:9000/accounts/123/transactions" || \
  echo "direct app port unreachable(期待通り。ADR 0009主対策①)"

FRAUD_DETECTION_ENGINE_POD=$(newest_pod fraud-detection-engine)

call_account_service_no_auth() {
  local method="$1" path="$2"
  kubectl -n "$NAMESPACE" exec "$FRAUD_DETECTION_ENGINE_POD" -c app -- env \
    METHOD="$method" URL="http://account-service${path}" \
    python3 -c '
import os, urllib.error, urllib.request
req = urllib.request.Request(os.environ["URL"], method=os.environ["METHOD"])
if os.environ["METHOD"] == "POST":
    req.data = b"{}"
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(resp.status)
        print(resp.read().decode())
except urllib.error.HTTPError as e:
    print(e.code)
    print(e.read().decode())
'
}

echo "==> 5. fraud-detection-engine egress Envoy経由でaccount-serviceのfreeze(account:freeze、client_credentials)を叩く(Authorizationヘッダーなし)"
call_account_service_no_auth POST /accounts/123/freeze

echo "==> 5b.(異常系)fraud-detection-engine egress Envoy経由でaccount-serviceのGET(account:read)を叩く(account:freezeしか持たないため拒否されるはず)"
call_account_service_no_auth GET /accounts/123/transactions || true

echo "==> 検証完了"
