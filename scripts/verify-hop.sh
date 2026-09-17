#!/bin/bash
# account-serviceへの1ホップ先行検証(ADR 0002/0009/0010)。
# 前提:make deploy && make deploy-verify-hopでstub一式がデプロイ済みであること。
#
# パターン⓪(簡易ログイン、frontend。ADR 0024):
# 0. yamada-analystがfrontendの/login(ROPCのHTTPエンドポイント化。本実装のAuthorization
#    Code+PKCEの代用)でログインし、ログイントークン(aud=frontend)を得る。frontend/fraud-agent
#    は共にclientAuthenticatorType: federated-jwtのため、cluster外からclient_secretで
#    これらを名乗ってKeycloakを直接叩く手段はもう無い(以前はここをKeycloakへの直接呼び出しで
#    代用していたが、federated-jwt化により技術的に不可能になった。これ自体が望ましい設計:
#    呼び出し元の身元がSPIRE mTLS/JWT-SVIDに一元化された)。
#
# パターン①(Token Exchange、fraud-mcp-server→account-service):
# 1. account-service向けのaccount:readトークンを、frontend→fraud-agent→fraud-mcp-serverの
#    実チェーン(各サービス自身のtoken-exchangeサイドカーへ、Envoyが送るのと同じ形で直接
#    リクエストする)経由で取得する
# 2. そのトークンを持ってfraud-mcp-server-stub Pod内からaccount-serviceを叩き、
#    Envoy egress(ext_authzによるToken Exchange)→Envoy ingress(jwt_authn/rbac/合言葉)→
#    account-service-stubアプリ、という経路全体が正しく動くことを確認する
# 3. account-service-stubのアプリポートにPod外から直接到達できないことを確認する(ADR 0009主対策①)
#
# パターン②(client_credentials、fraud-detection-engine→account-service):
# 4. fraud-detection-engine-stub Pod内から、Authorizationヘッダーを一切持たずにaccount-serviceの
#    freezeエンドポイントを叩き、Envoy egress(ext_authzによるclient_credentials取得)→
#    Envoy ingress(jwt_authn/rbac/合言葉)という経路が正しく動くことを確認する
#
# パターン③(Token Exchange、account-service→analyst-attribute-service。表3)：
# account-service自身のegress Envoy(ext_authzによるToken Exchange、JWT-SVIDクライアント認証)を
# 経由してanalyst-attribute-serviceへ委任する。account-service宛てGETリクエストを起点に、
# account-serviceのapp自身がこの委任を行う
#
# パターン④(Token Exchange、frontend→account-service。確定パス。ADR 0024):
# frontendの/login→/accounts/{id}/unfreezeを、edge-proxy経由の実呼び出しとして叩く。
# account-serviceのingressに今回追加したunfreeze rbacポリシーもここで検証される
#
# パターン⑤(Token Exchange、frontend→fraud-agent→fraud-mcp-server。ADR 0023/0024):
# frontendの/login→/chatを、edge-proxy経由の実呼び出しとして叩く。ADR 0023が「frontend実装
# まで検証できない」としていたfraud-agent自身のingress側(mTLS+jwt_authn+rbac+合言葉)も、
# ここで実際のfrontendから初めて実機検証される
set -euo pipefail

NAMESPACE=gekko
SECRETS_DIR=.secrets
LOCAL_EDGE_PORT=18080

# make deploy-verify-hopはスタブPodを常に再起動する(Makefile参照)ため、直後に実行すると
# 旧Podがterminating中でも`-l`セレクタのlist順で先頭に来ることがある(phaseはterminating中も
# Runningのまま)。creationTimestampで最新のPodを選ぶことで、terminating中の旧Podを掴まないようにする。
newest_pod() {
  kubectl -n "$NAMESPACE" get pod -l "app=$1" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | tail -1
}

YAMADA_ANALYST_PASSWORD=$(cat "$SECRETS_DIR/yamada-analyst-password")

echo "==> edge-proxyへport-forward中(ADR 0017)..."
kubectl -n "$NAMESPACE" port-forward svc/edge-proxy "$LOCAL_EDGE_PORT":80 >/tmp/verify-hop-portforward.log 2>&1 &
PF_PID=$!
cleanup() {
  kill "$PF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://localhost:$LOCAL_EDGE_PORT/realms/gekko" && break
  sleep 1
done

# edge-proxyのroute_config分割(ADR 0024:`/realms/`→keycloak、それ以外→frontend)を経由する
# 唯一の外部エントリポイント。
EDGE="http://localhost:$LOCAL_EDGE_PORT"

echo "==> 0. yamada-analystがfrontendの/loginでログイン(簡易ログイン、ROPCの代用。ADR 0024)"
LOGIN_TOKEN=$(curl -s -X POST "$EDGE/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"yamada-analyst\",\"password\":\"$YAMADA_ANALYST_PASSWORD\"}" | jq -r .access_token)
if [ "$LOGIN_TOKEN" = "null" ] || [ -z "$LOGIN_TOKEN" ]; then
  echo "ログイントークンの取得に失敗しました" >&2
  exit 1
fi

FRONTEND_POD=$(newest_pod frontend)
FRAUD_AGENT_POD=$(newest_pod fraud-agent)

# frontend/fraud-agent自身のtoken-exchangeサイドカー(ext_authzプロトコル)へ、Envoyのegress
# ext_authzフィルタが送るのと同じ形(Host/Authorization、Method/Pathは実際のリクエストラインで
# 代用)で直接リクエストし、Authorizationヘッダーとして返る交換後トークンを取り出す。パターン①
# (fraud-mcp-server→account-service)の試験に使う個別トークンを、実チェーン経由で正しく取得する
# ために使う。
sidecar_exchange() {
  local pod="$1" host="$2" method="$3" path="$4" token="$5"
  kubectl -n "$NAMESPACE" exec "$pod" -c token-exchange -- env \
    TOKEN="$token" HOST="$host" METHOD="$method" PATH_="$path" \
    python3 -c '
import os, urllib.error, urllib.request
req = urllib.request.Request(
    "http://127.0.0.1:9002" + os.environ["PATH_"],
    method=os.environ["METHOD"],
    headers={"Host": os.environ["HOST"], "Authorization": "Bearer " + os.environ["TOKEN"]},
)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(resp.headers.get("Authorization", "").split(" ", 1)[-1])
except urllib.error.HTTPError:
    print("", end="")
'
}

echo "==> 1a. frontendがfraud-agent宛てにToken Exchange(scope=account:read)する経路を直接検証"
FRAUD_AGENT_TOKEN=$(sidecar_exchange "$FRONTEND_POD" fraud-agent POST /chat "$LOGIN_TOKEN")
if [ -z "$FRAUD_AGENT_TOKEN" ]; then
  echo "fraud-agent宛てトークンの取得に失敗しました" >&2
  exit 1
fi

echo "==> 1b. fraud-agentがfraud-mcp-server宛てにToken Exchange(scope=account:read)する経路を直接検証"
DELEGATED_TOKEN=$(sidecar_exchange "$FRAUD_AGENT_POD" fraud-mcp-server GET / "$FRAUD_AGENT_TOKEN")
if [ -z "$DELEGATED_TOKEN" ]; then
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

echo "==> 2a. fraud-mcp-server egress Envoy経由でaccount-serviceのGET(account:read)を叩く"
echo "     (account-serviceは自身のegress Envoy経由でanalyst-attribute-serviceへさらに委任する。表3)"
ACCOUNT_SERVICE_RESPONSE=$(call_account_service GET /accounts/123/transactions "$DELEGATED_TOKEN")
echo "$ACCOUNT_SERVICE_RESPONSE"
if echo "$ACCOUNT_SERVICE_RESPONSE" | grep -q '"analyst_attribute_service": {"status": 200'; then
  echo "==> 2a'. account-service→analyst-attribute-serviceへの委任(表3)を確認(期待通り)"
else
  echo "警告:account-service経由でanalyst-attribute-serviceへ到達できませんでした" >&2
fi

echo "==> 2b. fraud-mcp-server egress Envoy経由でaccount-serviceのPOST(account:propose)を叩く"
call_account_service POST /accounts/123/unfreeze-proposals "$DELEGATED_TOKEN"

echo "==> 2c.(異常系)aud=frontendのログイントークンでそのまま叩く(拒否されるはず)"
call_account_service GET /accounts/123/transactions "$LOGIN_TOKEN" || true

echo "==> 3. account-serviceのアプリポートへPod外から直接到達できないことを確認"
ACCOUNT_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$(newest_pod account-service)" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${ACCOUNT_POD_IP}:9000/accounts/123/transactions" || \
  echo "direct app port unreachable(期待通り。ADR 0009主対策①)"

ANALYST_POD=$(newest_pod analyst-attribute-service)
ANALYST_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$ANALYST_POD" -o jsonpath='{.status.podIP}')
echo "==> 3. analyst-attribute-serviceのアプリポートへPod外から直接到達できないことを確認(表3)"
kubectl -n "$NAMESPACE" run verify-hop-analyst-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${ANALYST_POD_IP}:9000/" || \
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

echo "==> 4. fraud-detection-engine egress Envoy経由でaccount-serviceのfreeze(account:freeze、client_credentials)を叩く(Authorizationヘッダーなし)"
call_account_service_no_auth POST /accounts/123/freeze

echo "==> 4b.(異常系)fraud-detection-engine egress Envoy経由でaccount-serviceのGET(account:read)を叩く(account:freezeしか持たないため拒否されるはず)"
call_account_service_no_auth GET /accounts/123/transactions || true

echo "==> 5. frontend経由でaccount-serviceのGET(account:read)を叩く(edge-proxy→frontend ingress(mTLS+jwt_authn)"
echo "     →frontend egress(Token Exchange)→account-service ingress、全区間を実際のfrontendから検証。ADR 0024)"
FRONTEND_READ_RESPONSE=$(curl -s -X GET "$EDGE/accounts/123/transactions" -H "Authorization: Bearer $LOGIN_TOKEN")
echo "$FRONTEND_READ_RESPONSE"
if echo "$FRONTEND_READ_RESPONSE" | grep -q '"analyst_attribute_service": {"status": 200'; then
  echo "==> 5'. frontend→account-service→analyst-attribute-serviceの全区間委任を確認(期待通り)"
else
  echo "警告:frontend経由でaccount-serviceへ到達できませんでした" >&2
fi

echo "==> 6. frontend経由でaccount-serviceのPOST /unfreeze(account:unfreeze、確定パス。account-serviceの新規rbacポリシー)を叩く"
FRONTEND_UNFREEZE_RESPONSE=$(curl -s -X POST "$EDGE/accounts/123/unfreeze" -H "Authorization: Bearer $LOGIN_TOKEN" -d '{}')
echo "$FRONTEND_UNFREEZE_RESPONSE"
if echo "$FRONTEND_UNFREEZE_RESPONSE" | grep -q '"scope": "account:unfreeze"'; then
  echo "==> 6'. account-serviceのunfreeze rbacポリシー(ADR 0024で新規追加)を確認(期待通り)"
else
  echo "警告:frontend経由でaccount-serviceのunfreezeへ到達できませんでした" >&2
fi

echo "==> 7. frontend経由でfraud-agentのチャット開始(/chat、audience=fraud-agent)を叩く(edge-proxy→frontend ingress→"
echo "     frontend egress→fraud-agent ingress→fraud-agent egress→fraud-mcp-server ingress、全区間を実際のfrontendから検証。"
echo "     ADR 0023が『frontend実装まで検証できない』としていたfraud-agent自身のingress側もここで初めて実機検証される)"
FRONTEND_CHAT_RESPONSE=$(curl -s -X POST "$EDGE/chat" -H "Authorization: Bearer $LOGIN_TOKEN" -d '{}')
echo "$FRONTEND_CHAT_RESPONSE"
if echo "$FRONTEND_CHAT_RESPONSE" | grep -q '"fraud_mcp_server": {"status": 200'; then
  echo "==> 7'. frontend→fraud-agent→fraud-mcp-serverの全区間委任を確認(期待通り)"
else
  echo "警告:frontend経由でfraud-agent→fraud-mcp-serverへ到達できませんでした" >&2
fi

echo "==> 8.(異常系)frontend/fraud-agent/fraud-mcp-serverのappポートへPod外から直接到達できないことを確認(ADR 0009主対策①と同じ考え方)"
FRONTEND_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$FRONTEND_POD" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-frontend-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${FRONTEND_POD_IP}:9000/login" || \
  echo "direct app port unreachable(期待通り)"
kubectl -n "$NAMESPACE" run verify-hop-frontend-token-exchange-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${FRONTEND_POD_IP}:9002/" || \
  echo "direct app port unreachable(期待通り)"

FRAUD_AGENT_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$FRAUD_AGENT_POD" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-fraud-agent-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${FRAUD_AGENT_POD_IP}:9000/chat" || \
  echo "direct app port unreachable(期待通り)"
kubectl -n "$NAMESPACE" run verify-hop-fraud-agent-token-exchange-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${FRAUD_AGENT_POD_IP}:9002/" || \
  echo "direct app port unreachable(期待通り)"

FRAUD_MCP_POD_IP2=$(kubectl -n "$NAMESPACE" get pod "$FRAUD_MCP_POD" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-fraud-mcp-server-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${FRAUD_MCP_POD_IP2}:9000/" || \
  echo "direct app port unreachable(期待通り)"

# SPIRE mTLS(ADR 0012/0014。fraud-mcp-server・fraud-detection-engine両方からaccount-serviceへの
# 全ホップがmTLS必須)。2a/2b/4は既にfraud-mcp-server/fraud-detection-engineのegress Envoy
# (account_service_upstreamクラスタ)経由でaccount-serviceを叩いており、そのクラスタには
# 既にmTLS+ALPN h2のtransport_socketが設定済みのため、アプリレベルのレスポンスが変わらず
# 200のままであることは「mTLSが暗黙に効いた上でアプリ層は無風」の裏付けになる。ここでは加えて、
# 実際にTLSハンドシェイクが行われたことをEnvoyの管理APIで直接確認する(正常系)。
ACCOUNT_POD=$(newest_pod account-service)
echo "==> 9. account-serviceのEnvoy管理ポート(:9901)でTLSハンドシェイクが実際に発生したことを確認"
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
echo "==> 10.(異常系)クライアント証明書なしのTLS接続がaccount-serviceのmTLS必須filter_chainに拒否されることを確認"
kubectl -n "$NAMESPACE" run verify-hop-mtls-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -k -o /dev/null -w 'no-client-cert TLS to mTLS listener status: %{http_code}\n' \
  --max-time 5 "https://${ACCOUNT_POD_IP}:8080/accounts/123/transactions" || \
  echo "クライアント証明書なしのTLS接続は拒否された(期待通り。ADR 0012)"

# analyst-attribute-serviceへの委任(表3、ステップ2a')が既に発生しているため、account-serviceの
# egress Envoy→analyst-attribute-serviceのmTLS接続も同じ手法で確認できる。
echo "==> 9. analyst-attribute-serviceのEnvoy管理ポート(:9901)でTLSハンドシェイクが実際に発生したことを確認(表3)"
kubectl -n "$NAMESPACE" exec "$ANALYST_POD" -c envoy -- bash -c '
  exec 3<>/dev/tcp/127.0.0.1/9901
  printf "GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
  cat <&3
' | grep -E 'listener\..*\.ssl\.handshake: [1-9]' \
  && echo "mTLSハンドシェイク成功を確認(期待通り)" \
  || echo "警告:ssl.handshakeカウンタが検出できませんでした(統計名が異なる可能性。config_dumpで要確認)" >&2

echo "==> 10.(異常系)クライアント証明書なしのTLS接続がanalyst-attribute-serviceのmTLS必須filter_chainに拒否されることを確認(表3)"
kubectl -n "$NAMESPACE" run verify-hop-analyst-mtls-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -k -o /dev/null -w 'no-client-cert TLS to mTLS listener status: %{http_code}\n' \
  --max-time 5 "https://${ANALYST_POD_IP}:8080/" || \
  echo "クライアント証明書なしのTLS接続は拒否された(期待通り。ADR 0012)"

# KeycloakへのSPIRE mTLS拡張(ADR 0016)。2a/2b/4が既にfraud-mcp-server/fraud-detection-engineの
# egress Envoy→Keycloakのext_authzチェック呼び出し(=mTLS化された新ホップ)を経由して200/403を
# 返しており、そのレスポンスが変わらないことは「mTLSが暗黙に効いた上でアプリ層は無風」の裏付けに
# なる。ここでは加えて、account-serviceと同じ手法でTLSハンドシェイクの実発生・直接到達不可・
# 証明書なし接続の拒否を確認する。
#
# ADR 0019/0020でfraud-mcp-server/fraud-detection-engine→Keycloakは、それぞれ自身のEnvoy
# (egress、keycloak_upstreamクラスタ)がmTLSを担うようになった(旧ext-authz-service(-cc)は廃止)。
# 両者ともmTLS必須のingressリスナーを持たない(account-serviceのような着信専用サービスでは
# ないため)ので、edge-proxyと同じくcluster側のssl.handshake統計で確認する。
ext_authz_ssl_handshake_check() {
  local pod="$1" label="$2"
  echo "==> 11. ${label}のEnvoy管理ポート(:9901)でTLSハンドシェイクが実際に発生したことを確認"
  kubectl -n "$NAMESPACE" exec "$pod" -c envoy -- bash -c '
    exec 3<>/dev/tcp/127.0.0.1/9901
    printf "GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
    cat <&3
  ' | grep -E 'listener\..*\.ssl\.handshake: [1-9]' \
    && echo "mTLSハンドシェイク成功を確認(期待通り)" \
    || echo "警告:ssl.handshakeカウンタが検出できませんでした(統計名が異なる可能性。config_dumpで要確認)" >&2
}

# クラスタ名を指定できる版(keycloak_upstream固定を含む複数のegressクラスタの確認に使う)。
ssl_handshake_check_named_cluster() {
  local pod="$1" label="$2" cluster="$3"
  echo "==> 11. ${label}のEnvoy管理ポート(:9901)でTLSハンドシェイクが実際に発生したことを確認"
  kubectl -n "$NAMESPACE" exec "$pod" -c envoy -- bash -c "
    exec 3<>/dev/tcp/127.0.0.1/9901
    printf 'GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
    cat <&3
  " | grep -E "cluster\.${cluster}\.ssl\.handshake: [1-9]" \
    && echo "mTLSハンドシェイク成功を確認(期待通り)" \
    || echo "警告:ssl.handshakeカウンタが検出できませんでした(統計名が異なる可能性。config_dumpで要確認)" >&2
}

KEYCLOAK_POD=$(newest_pod keycloak)
EDGE_PROXY_POD=$(newest_pod edge-proxy)

ext_authz_ssl_handshake_check "$KEYCLOAK_POD" "keycloak"
ssl_handshake_check_named_cluster "$FRAUD_MCP_POD" "fraud-mcp-server(token-exchangeサイドカー、ADR 0019)" "keycloak_upstream"
ssl_handshake_check_named_cluster "$FRAUD_DETECTION_ENGINE_POD" "fraud-detection-engine(client-credentialsサイドカー、ADR 0020)" "keycloak_upstream"
ssl_handshake_check_named_cluster "$ACCOUNT_POD" "account-service(token-exchangeサイドカー、表3)" "keycloak_upstream"

# edge-proxyはinbound(:80)が平文でoutbound(→keycloak_upstream/frontend_upstream)だけmTLSのため、
# listener側ではなくcluster側のssl.handshake統計を見る(他はinboundがmTLS必須なので
# listener側で検出できる。ADR 0017)。
ssl_handshake_check_named_cluster "$EDGE_PROXY_POD" "edge-proxy(→keycloak)" "keycloak_upstream"
ssl_handshake_check_named_cluster "$EDGE_PROXY_POD" "edge-proxy(→frontend、ADR 0024)" "frontend_upstream"

# ADR 0023/0024:frontend→fraud-agent→fraud-mcp-serverホップ。frontendのegress(2クラスタ)・
# fraud-agentのingress/egress・fraud-mcp-serverのingressの全区間でmTLSが実際に発生したことを
# 確認する。frontend自身のingress(edge-proxyから)はlistener側で確認する。
ext_authz_ssl_handshake_check "$FRONTEND_POD" "frontend(ingress、edge-proxyから。ADR 0024)"
ssl_handshake_check_named_cluster "$FRONTEND_POD" "frontend(egress→account-service、ADR 0024)" "account_service_upstream"
ssl_handshake_check_named_cluster "$FRONTEND_POD" "frontend(egress→fraud-agent、ADR 0024)" "fraud_agent_upstream"
ssl_handshake_check_named_cluster "$FRONTEND_POD" "frontend(egress→keycloak、ログイン含む。ADR 0024)" "keycloak_upstream"
ext_authz_ssl_handshake_check "$FRAUD_AGENT_POD" "fraud-agent(ingress、frontendから実際に呼び出された。ADR 0023/0024)"
ssl_handshake_check_named_cluster "$FRAUD_AGENT_POD" "fraud-agent(egress→fraud-mcp-server、ADR 0023)" "fraud_mcp_server_upstream"
ext_authz_ssl_handshake_check "$FRAUD_MCP_POD" "fraud-mcp-server(ingress、ADR 0023で活性化)"

echo "==> 12.(異常系)クライアント証明書なしのTLS接続がfrontend/fraud-agentのmTLS必須filter_chainに拒否されることを確認"
kubectl -n "$NAMESPACE" run verify-hop-frontend-mtls-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -k -o /dev/null -w 'no-client-cert TLS to mTLS listener status: %{http_code}\n' \
  --max-time 5 "https://${FRONTEND_POD_IP}:8080/login" || \
  echo "クライアント証明書なしのTLS接続は拒否された(期待通り。ADR 0024)"
kubectl -n "$NAMESPACE" run verify-hop-fraud-agent-mtls-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -k -o /dev/null -w 'no-client-cert TLS to mTLS listener status: %{http_code}\n' \
  --max-time 5 "https://${FRAUD_AGENT_POD_IP}:8080/chat" || \
  echo "クライアント証明書なしのTLS接続は拒否された(期待通り。ADR 0023)"

echo "==> 13. fraud-mcp-serverのtoken-exchangeサイドカーのポート(9002)にPod外から直接到達できないことを確認(ADR 0009主対策①と同じ考え方。ADR 0019)"
FRAUD_MCP_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$FRAUD_MCP_POD" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-token-exchange-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${FRAUD_MCP_POD_IP}:9002/" || \
  echo "direct app port unreachable(期待通り。ADR 0009主対策①と同じ考え方)"

echo "==> 13. fraud-detection-engineのclient-credentialsサイドカーのポート(9002)にPod外から直接到達できないことを確認(ADR 0009主対策①と同じ考え方。ADR 0020)"
FRAUD_DETECTION_ENGINE_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$FRAUD_DETECTION_ENGINE_POD" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-client-credentials-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${FRAUD_DETECTION_ENGINE_POD_IP}:9002/" || \
  echo "direct app port unreachable(期待通り。ADR 0009主対策①と同じ考え方)"

echo "==> 13. account-serviceのtoken-exchangeサイドカーのポート(9002)にPod外から直接到達できないことを確認(ADR 0009主対策①と同じ考え方。表3)"
kubectl -n "$NAMESPACE" run verify-hop-account-token-exchange-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct app port HTTP status: %{http_code}\n' \
  --max-time 5 "http://${ACCOUNT_POD_IP}:9002/" || \
  echo "direct app port unreachable(期待通り。ADR 0009主対策①と同じ考え方)"

echo "==> 14.(異常系)クライアント証明書なしのTLS接続がKeycloakのmTLS必須ポート(8443)に拒否されることを確認"
kubectl -n "$NAMESPACE" run verify-hop-keycloak-mtls-bypass-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -k -o /dev/null -w 'no-client-cert TLS to keycloak mTLS listener status: %{http_code}\n' \
  --max-time 5 "https://keycloak.${NAMESPACE}.svc.cluster.local:8443/" || \
  echo "クライアント証明書なしのTLS接続は拒否された(期待通り。ADR 0016)"

# ADR 0017:edge-proxy導入によりKeycloakの8080は完全に撤廃した(9000はkubelet用として維持)。
# ステップ0がedge-proxy経由(port-forward svc/edge-proxy)で引き続き成功していること自体が、
# 非mTLS呼び出し元向けの経路が回帰せず意図通り機能していることの裏付けになる。ここでは加えて、
# Keycloak Service自体に8080ポートがもう存在しないことを直接確認する。
echo "==> 15. KeycloakのServiceに8080(平文)ポートが存在しないことを確認(ADR 0017)"
if kubectl -n "$NAMESPACE" get svc keycloak -o jsonpath='{.spec.ports[*].port}' | grep -qw 8080; then
  echo "警告:Keycloak Serviceに8080ポートが残っています(ADR 0017の想定と異なる)" >&2
else
  echo "8080ポートは存在しない(期待通り)"
fi

echo "==> 16.(異常系)NetworkPolicy適用後、素のPodからpostgres:5432に直接到達できないことを確認(ADR 0018)"
kubectl -n "$NAMESPACE" run verify-hop-netpol-postgres-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -sv -o /dev/null --max-time 5 "http://postgres:5432/" 2>&1 | tail -3 || \
  echo "postgres:5432への到達不可(期待通り。ADR 0018。NetworkPolicyでブロックされていれば" \
       "connect timed outに、許可されていればpostgresプロトコルエラーで即座に失敗するはず)"

echo "==> 17.(異常系)NetworkPolicy適用後、素のPodからkeycloakのhttp-mgmt(9000)に直接到達できないことを確認(ADR 0022でexecプローブ化・KC_HTTP_MANAGEMENT_HOST=127.0.0.1化して以降、誰からもネットワーク経由で到達不能)"
KEYCLOAK_POD_IP=$(kubectl -n "$NAMESPACE" get pod "$KEYCLOAK_POD" -o jsonpath='{.status.podIP}')
kubectl -n "$NAMESPACE" run verify-hop-netpol-keycloak-mgmt-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct keycloak mgmt reach: %{http_code}\n' \
  --max-time 5 "http://${KEYCLOAK_POD_IP}:9000/health/ready" || \
  echo "keycloakのhttp-mgmt(9000)への到達不可(期待通り。ADR 0022。kubeletもexecプローブ経由でしか到達できない)"

echo "==> 18.(異常系)NetworkPolicy適用後、素のPodからanalyst-attribute-serviceに直接到達できないことを確認(ADR 0018。表3:account-service以外はDENY)"
kubectl -n "$NAMESPACE" run verify-hop-netpol-analyst-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct analyst-attribute-service reach: %{http_code}\n' \
  --max-time 5 "http://analyst-attribute-service:8080/" || \
  echo "analyst-attribute-serviceへの到達不可(期待通り。ADR 0018)"

echo "==> 18.(異常系)NetworkPolicy適用後、素のPodからfraud-agentに直接到達できないことを確認(ADR 0018/0023:frontend以外はDENY)"
kubectl -n "$NAMESPACE" run verify-hop-netpol-fraud-agent-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct fraud-agent reach: %{http_code}\n' \
  --max-time 5 "http://fraud-agent:8080/" || \
  echo "fraud-agentへの到達不可(期待通り。ADR 0018/0023)"

echo "==> 18.(異常系)NetworkPolicy適用後、素のPodからfraud-mcp-serverに直接到達できないことを確認(ADR 0018/0023:fraud-agent以外はDENY)"
kubectl -n "$NAMESPACE" run verify-hop-netpol-fraud-mcp-server-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct fraud-mcp-server reach: %{http_code}\n' \
  --max-time 5 "http://fraud-mcp-server:8080/" || \
  echo "fraud-mcp-serverへの到達不可(期待通り。ADR 0018/0023)"

echo "==> 18.(異常系)NetworkPolicy適用後、素のPodからfrontendに直接到達できないことを確認(ADR 0018/0024:edge-proxy以外はDENY)"
kubectl -n "$NAMESPACE" run verify-hop-netpol-frontend-check --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -s -o /dev/null -w 'direct frontend reach: %{http_code}\n' \
  --max-time 5 "http://frontend:8080/" || \
  echo "frontendへの到達不可(期待通り。ADR 0018/0024)"

echo "==> 検証完了"
