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

echo "==> Keycloakへport-forward中(edge-proxy経由。ADR 0017でKeycloak自体の8080は撤廃済み)..."
kubectl -n "$NAMESPACE" port-forward svc/edge-proxy "$LOCAL_KC_PORT":80 >/tmp/verify-hop-portforward.log 2>&1 &
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

# SPIRE mTLS(ADR 0012/0014。fraud-mcp-server・fraud-detection-engine両方からaccount-serviceへの
# 全ホップがmTLS必須)。3a/3b/5は既にfraud-mcp-server/fraud-detection-engineのegress Envoy
# (account_service_upstreamクラスタ)経由でaccount-serviceを叩いており、そのクラスタには
# 既にmTLS+ALPN h2のtransport_socketが設定済みのため、アプリレベルのレスポンスが変わらず
# 200のままであることは「mTLSが暗黙に効いた上でアプリ層は無風」の裏付けになる。ここでは加えて、
# 実際にTLSハンドシェイクが行われたことをEnvoyの管理APIで直接確認する(正常系)。
ACCOUNT_POD=$(newest_pod account-service)
echo "==> 6. account-serviceのEnvoy管理ポート(:9901)でTLSハンドシェイクが実際に発生したことを確認"
# envoyproxy/envoyイメージにはcurl/wgetが入っていない(実機検証で判明)。bashの/dev/tcpで
# 生のHTTPリクエストを組み立てる。
kubectl -n "$NAMESPACE" exec "$ACCOUNT_POD" -c envoy -- bash -c '
  exec 3<>/dev/tcp/127.0.0.1/9901
  printf "GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
  cat <&3
' | grep -E 'listener\..*\.ssl\.handshake: [1-9]' \
  && echo "mTLSハンドシェイク成功を確認(期待通り)" \
  || echo "警告:ssl.handshakeカウンタが検出できませんでした(統計名が異なる可能性。config_dumpで要確認)" >&2

# account-serviceのingressリスナーは単一のfilter_chainで全呼び出し元にmTLS必須を課している
# (ADR 0012/0014。fraud-detection-engineもSPIRE化したためplaintext受け口は完全に撤廃した)。
# 「SPIFFE身元を持たない接続の拒否」を検証するには、TLSハンドシェイク自体を試み、
# クライアント証明書なしで拒否されることを確認する(-kは自己署名ルートCAを検証しないだけで、
# クライアント証明書は一切提示しない。require_client_certificate: trueにより拒否されるはず)。
echo "==> 7.(異常系)クライアント証明書なしのTLS接続がaccount-serviceのmTLS必須filter_chainに拒否されることを確認"
kubectl -n "$NAMESPACE" run verify-hop-mtls-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -k -o /dev/null -w 'no-client-cert TLS to mTLS listener status: %{http_code}\n' \
  --max-time 5 "https://${ACCOUNT_POD_IP}:8080/accounts/123/transactions" || \
  echo "クライアント証明書なしのTLS接続は拒否された(期待通り。ADR 0012)"

# ext-authz-service-cc・KeycloakへのSPIRE mTLS拡張(ADR 0016)。
# 3a/3b/5が既にfraud-mcp-server/fraud-detection-engineのegress Envoy→ext-authz-service-ccの
# ext_authzチェック呼び出し(=mTLS化された新ホップ)を経由して200/403を返しており、そのレスポンスが
# 変わらないことは「mTLSが暗黙に効いた上でアプリ層は無風」の裏付けになる。ここでは加えて、
# account-serviceと同じ手法でTLSハンドシェイクの実発生・直接到達不可・証明書なし接続の拒否を確認する。
#
# ADR 0019でfraud-mcp-server→Keycloakは、fraud-mcp-server自身のEnvoy(egress、
# keycloak_upstreamクラスタ)がmTLSを担うようになった(旧ext-authz-serviceは廃止)。
# fraud-mcp-serverはmTLS必須のingressリスナーを持たない(account-serviceのような
# 着信専用サービスではないため)ので、edge-proxyと同じくcluster側のssl.handshake統計で確認する。
ext_authz_ssl_handshake_check() {
  local pod="$1" label="$2"
  echo "==> 8. ${label}のEnvoy管理ポート(:9901)でTLSハンドシェイクが実際に発生したことを確認"
  kubectl -n "$NAMESPACE" exec "$pod" -c envoy -- bash -c '
    exec 3<>/dev/tcp/127.0.0.1/9901
    printf "GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
    cat <&3
  ' | grep -E 'listener\..*\.ssl\.handshake: [1-9]' \
    && echo "mTLSハンドシェイク成功を確認(期待通り)" \
    || echo "警告:ssl.handshakeカウンタが検出できませんでした(統計名が異なる可能性。config_dumpで要確認)" >&2
}

ext_authz_ssl_handshake_check_cluster() {
  local pod="$1" label="$2"
  echo "==> 8. ${label}のEnvoy管理ポート(:9901)でTLSハンドシェイクが実際に発生したことを確認"
  kubectl -n "$NAMESPACE" exec "$pod" -c envoy -- bash -c '
    exec 3<>/dev/tcp/127.0.0.1/9901
    printf "GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
    cat <&3
  ' | grep -E 'cluster\.keycloak_upstream\.ssl\.handshake: [1-9]' \
    && echo "mTLSハンドシェイク成功を確認(期待通り)" \
    || echo "警告:ssl.handshakeカウンタが検出できませんでした(統計名が異なる可能性。config_dumpで要確認)" >&2
}

EXT_AUTHZ_CC_POD=$(newest_pod ext-authz-service-cc)
KEYCLOAK_POD=$(newest_pod keycloak)
EDGE_PROXY_POD=$(newest_pod edge-proxy)

ext_authz_ssl_handshake_check "$EXT_AUTHZ_CC_POD" "ext-authz-service-cc"
ext_authz_ssl_handshake_check "$KEYCLOAK_POD" "keycloak"
ext_authz_ssl_handshake_check_cluster "$FRAUD_MCP_POD" "fraud-mcp-server(token-exchangeサイドカー、ADR 0019)"

# edge-proxyはinbound(:80)が平文でoutbound(→keycloak_upstream)だけmTLSのため、
# listener側ではなくcluster側のssl.handshake統計を見る(他3者はinboundがmTLS必須なので
# listener側で検出できる。ADR 0017)。
ext_authz_ssl_handshake_check_cluster "$EDGE_PROXY_POD" "edge-proxy"

echo "==> 9. fraud-mcp-serverのtoken-exchangeサイドカーのポート(9002)にPod外から直接到達できないことを確認(ADR 0009主対策①と同じ考え方。ADR 0019)"
FRAUD_MCP_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$FRAUD_MCP_POD" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-token-exchange-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${FRAUD_MCP_POD_IP}:9002/" || \
  echo "direct app port unreachable(期待通り。ADR 0009主対策①と同じ考え方)"

echo "==> 10.(異常系)クライアント証明書なしのTLS接続がext-authz-service-ccのmTLS必須filter_chainに拒否されることを確認"
EXT_AUTHZ_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$EXT_AUTHZ_CC_POD" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-ext-authz-mtls-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -k -o /dev/null -w 'no-client-cert TLS to mTLS listener status: %{http_code}\n' \
  --max-time 5 "https://${EXT_AUTHZ_POD_IP}:8080/" || \
  echo "クライアント証明書なしのTLS接続は拒否された(期待通り。ADR 0016)"

echo "==> 11.(異常系)クライアント証明書なしのTLS接続がKeycloakのmTLS必須ポート(8443)に拒否されることを確認"
kubectl -n "$NAMESPACE" run verify-hop-keycloak-mtls-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -k -o /dev/null -w 'no-client-cert TLS to keycloak mTLS listener status: %{http_code}\n' \
  --max-time 5 "https://keycloak.${NAMESPACE}.svc.cluster.local:8443/" || \
  echo "クライアント証明書なしのTLS接続は拒否された(期待通り。ADR 0016)"

# ADR 0017:edge-proxy導入によりKeycloakの8080は完全に撤廃した(9000はkubelet用として維持)。
# ステップ1・2がedge-proxy経由(port-forward svc/edge-proxy)で引き続き成功していること自体が、
# 非mTLS呼び出し元向けの経路が回帰せず意図通り機能していることの裏付けになる。ここでは加えて、
# Keycloak Service自体に8080ポートがもう存在しないことを直接確認する。
echo "==> 12. KeycloakのServiceに8080(平文)ポートが存在しないことを確認(ADR 0017)"
if kubectl -n "$NAMESPACE" get svc keycloak -o jsonpath='{.spec.ports[*].port}' | grep -qw 8080; then
  echo "警告:Keycloak Serviceに8080ポートが残っています(ADR 0017の想定と異なる)" >&2
else
  echo "8080ポートは存在しない(期待通り)"
fi

echo "==> 13.(異常系)NetworkPolicy適用後、素のPodからpostgres:5432に直接到達できないことを確認(ADR 0018)"
kubectl -n "$NAMESPACE" run verify-hop-netpol-postgres-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -sv -o /dev/null --max-time 5 "http://postgres:5432/" 2>&1 | tail -3 || \
  echo "postgres:5432への到達不可(期待通り。ADR 0018。NetworkPolicyでブロックされていれば" \
       "connect timed outに、許可されていればpostgresプロトコルエラーで即座に失敗するはず)"

echo "==> 14.(異常系)NetworkPolicy適用後、素のPodからkeycloakのhttp-mgmt(9000)に直接到達できないことを確認(ADR 0018)"
KEYCLOAK_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$KEYCLOAK_POD" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-netpol-keycloak-mgmt-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct keycloak mgmt reach: %{http_code}\n' \
  --max-time 5 "http://${KEYCLOAK_POD_IP}:9000/health/ready" || \
  echo "keycloakのhttp-mgmt(9000)への到達不可(期待通り。ADR 0018。許可されるのはkubeletのprobeのみ)"

echo "==> 検証完了"
