#!/bin/bash
# account-serviceへの1ホップ先行検証(ADR 0002/0009/0010)。
# 前提:make deploy(frontendを含むbase track全体)実行済みであること。
#
# パターン⓪(ログイン、frontend。ADR 0031):
# 0. yamada-analystがfrontendの本物のAuthorization Code + PKCEブラウザフローでログインする。
#    ヘッドレスブラウザなしでKeycloakのログインフォームをcurlで直接POSTする一般的な手法
#    (login_via_frontend、下記)で、Cookie jarにgekko_session(暗号化Cookie、ADR 0031)を
#    確立する。以降frontend向けの呼び出しは全てこのjarを使う(`-H "Authorization: Bearer"`では
#    なく`-b <jar>`)。frontend/fraud-agentは共にclientAuthenticatorType: federated-jwtのため、
#    cluster外からclient_secretでこれらを名乗ってKeycloakを直接叩く手段はもう無い。
#
#    パターン①検証(1a/1b/2c)用に、frontendのtoken-exchangeサイドカーへkubectl exec経由で
#    直接authorization_code交換をリクエストして生のaud=frontendトークンも別途取得する
#    (raw_login_token、下記)。BFFパターン(ADR 0031)によりブラウザ/verify-hop.shは通常
#    このトークンの値そのものを知り得ない(gekko_sessionは復号鍵を持つfrontend自身にしか
#    読めない不透明なCookie)ため、Envoyのext_authzが送るのと同じ形でサイドカーを直接叩く
#    既存の技法(sidecar_exchange)をログイン自体にも適用したもの。
#
# パターン①(Token Exchange、fraud-mcp-server→account-service):
# 1. account-service向けのaccount:readトークンを、frontend→fraud-agent→fraud-mcp-serverの
#    実チェーン(各サービス自身のtoken-exchangeサイドカーへ、Envoyが送るのと同じ形で直接
#    リクエストする)経由で取得する
# 2. そのトークンを持ってfraud-mcp-server Pod内からaccount-serviceを叩き、
#    Envoy egress(ext_authzによるToken Exchange)→Envoy ingress(jwt_authn/rbac/合言葉)→
#    account-serviceアプリ(本実装)、という経路全体が正しく動くことを確認する
# 3. account-serviceのアプリポートにPod外から直接到達できないことを確認する(ADR 0009主対策①)
#
# パターン②(client_credentials、fraud-detection-engine→account-service。ADR 0027で本実装):
# 4. fraud-detection-engineは本実装後、起動後まもなく自律的にaccount 123を検知・凍結する
#    (UC0)。診断用ループバックAPI(GET 127.0.0.1:9000/detections、client-credentialsコンテナ
#    から`kubectl exec`で到達)でこれを確認する。appコンテナはコンパイル済みのRustバイナリで
#    シェル・curlを持たないため、Envoy egress(ext_authzによるclient_credentials取得)→
#    Envoy ingress(jwt_authn/rbac/合言葉)という経路自体の検証(異常系4bのGET拒否含む)は
#    引き続きclient-credentialsコンテナ(Python)から行う
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
# パターン⑤(Token Exchange、frontend→fraud-agent→fraud-mcp-server。ADR 0023/0024/0030):
# frontendの/login→/chatを、edge-proxy経由の実呼び出しとして叩く。ADR 0023が「frontend実装
# まで検証できない」としていたfraud-agent自身のingress側(mTLS+jwt_authn+rbac+合言葉)も、
# ここで実際のfrontendから初めて実機検証される。
# ADR 0030でfraud-agentが本実装(TypeScript/Claude Agent SDK)に置き換わったため、/chatは
# 「即時のJSONエコー」ではなく実際にAnthropic APIを呼びfraud-mcp-server経由でaccount-service
# へ問い合わせる処理になった。CLAUDE_CODE_OAUTH_TOKEN・外部ネットワーク(egress-anthropic、
# ipBlock 0.0.0.0/0)の実在に依存し、スタブ時代より応答に時間がかかる。レスポンスボディの
# 厳密な形("fraud_mcp_server"キー等)は問わず、200が返り"reply"に何らかのテキストが
# 含まれることのみを確認する
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
  rm -f "${YAMADA_JAR:-}" "${SUZUKI_JAR:-}" "${TANAKA_JAR:-}" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 20); do
  curl -s -o /dev/null "http://localhost:$LOCAL_EDGE_PORT/realms/gekko" && break
  sleep 1
done

# edge-proxyのroute_config分割(ADR 0024:`/realms/`→keycloak、それ以外→frontend)を経由する
# 唯一の外部エントリポイント。
EDGE="http://localhost:$LOCAL_EDGE_PORT"

FRONTEND_POD=$(newest_pod frontend)
FRAUD_AGENT_POD=$(newest_pod fraud-agent)

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

# Keycloakのログインフォームを実際にPOSTする(ヘッドレスブラウザなしでKeycloakのログイン
# フォームをcurlで直接叩く一般的な手法)。$jarでKeycloakのセッションCookieを引き継ぎつつ、
# フォームのaction属性(セッションコード等を含む送信先URL)をHTMLから抽出してPOSTし、
# 最終的なリダイレクト先URL全体(code=...&state=...を含む)を返す。テストフィクスチャで
# email/firstName/lastNameを埋めてあるため(k8s/keycloak/test-fixtures-configmap.yaml)
# 追加の確認画面は出ず、ログインフォームのPOST1回でcodeまで到達する。
#
# raw_login_token()専用(response_mode=query、既定値)。login_via_frontend()は
# response_mode=form_post(ADR 0032)のため下記keycloak_login_form_post()を使う。
keycloak_login_redirect() {
  local authorize_url="$1" username="$2" password="$3" jar="$4"
  local login_page form_action
  login_page=$(curl -s -c "$jar" -b "$jar" "$authorize_url")
  form_action=$(printf '%s' "$login_page" | grep -o 'action="[^"]*"' | head -1 | sed -E 's/^action="//; s/"$//' | sed 's/&amp;/\&/g')
  if [ -z "$form_action" ]; then
    echo "Keycloakログインフォームのaction属性を取得できませんでした" >&2
    return 1
  fi
  # フォームのaction属性もKC_HOSTNAME固定(localhost:3000)のまま埋め込まれているため、
  # authorize_urlと同じ理由でホスト部分を$EDGEへ付け替える。
  form_action="$EDGE$(echo "$form_action" | sed -E 's#^https?://[^/]+##')"
  curl -s -D - -o /dev/null -c "$jar" -b "$jar" \
    --data-urlencode "username=$username" --data-urlencode "password=$password" \
    "$form_action" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r'
}

# login_via_frontend()専用。response_mode=form_post(ADR 0032、server/routes/login.get.ts)
# ではKeycloakはログインフォームPOST後302ではなく200+自動送信フォーム(<FORM METHOD="POST"
# ACTION=".../callback"><INPUT TYPE="HIDDEN" NAME="code" VALUE="...">...)を返す
# (ブラウザはonload="document.forms[0].submit()"でこれを自動的にPOSTする)。ヘッドレス
# ブラウザを持たないこのスクリプトでは、隠しinputをHTMLから抽出してそのまま/callbackへ
# POSTすることでブラウザのJS自動送信を代替する。成功すればgekko_session Cookieが$jarに
# 確立される(callback.post.tsが302 /dashboardを返すが、ここでは戻り値は使わない)。
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
  # form_post応答はKeycloakのFreeMarkerテンプレート由来で大文字タグ(<FORM>/<INPUT>)のため
  # 大文字小文字を区別しない(-i)。
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

# パターン⓪:本物のAuthorization Code + PKCEブラウザフロー(ADR 0031)でログインし、
# gekko_session Cookieを$jarに確立する。以降のfrontend呼び出しは全てこの$jarを使う。
login_via_frontend() {
  local username="$1" password="$2" jar="$3"
  rm -f "$jar"
  local authorize_url
  authorize_url=$(curl -s -D - -o /dev/null -c "$jar" "$EDGE/login" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')
  # KC_HOSTNAME固定(http://localhost:3000、ADR 0004)によりfrontendの/loginが返すLocationは
  # 常にlocalhost:3000だが、verify-hop.sh自身のport-forwardは$LOCAL_EDGE_PORT(18080)。
  # edge-proxyのルーティングはpathのみで決まる(Host非依存)ため、ホスト部分だけ$EDGEへ
  # 付け替えて実際に到達可能なURLにする。
  authorize_url="$EDGE$(echo "$authorize_url" | sed -E 's#^https?://[^/]+##')"
  keycloak_login_form_post "$authorize_url" "$username" "$password" "$jar"
}

# パターン①検証(1a/1b/2c)向けに、frontendの/loginを経由せず独自のPKCEパラメータで直接
# Keycloakへログインし、frontendのtoken-exchangeサイドカーへkubectl exec経由でauthorization_code
# 交換をリクエストして生のaud=frontendトークンを得る。BFFパターン(ADR 0031)により
# gekko_session Cookieの中身(暗号化済み)からはこのトークンを取り出せないため、Envoyの
# ext_authzが送るのと同じ形でサイドカーを直接叩く既存の技法(sidecar_exchange、後述)を
# ログイン自体にも適用したもの。
raw_login_token() {
  local username="$1" password="$2"
  local jar verifier challenge state redirect_uri authorize_url redirect_location code token_response
  jar=$(mktemp)
  verifier=$(openssl rand -base64 96 | tr -d '=+/\n' | cut -c1-64)
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '=')
  state=$(openssl rand -hex 16)
  redirect_uri="http://localhost:3000/callback"
  authorize_url="$EDGE/realms/gekko/protocol/openid-connect/auth?client_id=frontend&response_type=code&redirect_uri=$(urlencode "$redirect_uri")&scope=openid&code_challenge=${challenge}&code_challenge_method=S256&state=${state}"
  redirect_location=$(keycloak_login_redirect "$authorize_url" "$username" "$password" "$jar")
  rm -f "$jar"
  code=$(echo "$redirect_location" | grep -oE '[?&]code=[^&]+' | head -1 | cut -d= -f2-)
  if [ -z "$code" ]; then
    echo "raw_login_token: codeを取得できませんでした($username)" >&2
    return 1
  fi
  token_response=$(kubectl -n "$NAMESPACE" exec "$FRONTEND_POD" -c token-exchange -- env \
    CODE="$code" REDIRECT_URI="$redirect_uri" VERIFIER="$verifier" \
    python3 -c '
import json, os, urllib.error, urllib.request
data = json.dumps({
    "code": os.environ["CODE"],
    "redirectUri": os.environ["REDIRECT_URI"],
    "codeVerifier": os.environ["VERIFIER"],
}).encode()
req = urllib.request.Request(
    "http://127.0.0.1:9002/login/complete", data=data, headers={"Content-Type": "application/json"}
)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(resp.read().decode())
except urllib.error.HTTPError as e:
    print(e.read().decode())
')
  echo "$token_response" | jq -r .access_token
}

echo "==> 0. yamada-analystがfrontendの本物のAuthorization Code + PKCEブラウザフローでログイン(ADR 0031)"
YAMADA_JAR=$(mktemp)
login_via_frontend yamada-analyst "$YAMADA_ANALYST_PASSWORD" "$YAMADA_JAR"
if ! curl -s -o /dev/null -w '%{http_code}' -b "$YAMADA_JAR" "$EDGE/me" | grep -q 200; then
  echo "gekko_session Cookieの確立に失敗しました(GET /meが200になりません)" >&2
  exit 1
fi

echo "==> 0b. パターン①検証(1a/1b/2c)用に生のaud=frontendトークンを別途取得"
YAMADA_RAW_TOKEN=$(raw_login_token yamada-analyst "$YAMADA_ANALYST_PASSWORD")
if [ -z "$YAMADA_RAW_TOKEN" ] || [ "$YAMADA_RAW_TOKEN" = "null" ]; then
  echo "生のログイントークンの取得に失敗しました" >&2
  exit 1
fi

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
FRAUD_AGENT_TOKEN=$(sidecar_exchange "$FRONTEND_POD" fraud-agent POST /chat "$YAMADA_RAW_TOKEN")
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
  local method="$1" path="$2" token="$3" body="${4:-{\}}"
  kubectl -n "$NAMESPACE" exec "$FRAUD_MCP_POD" -c app -- env \
    TOKEN="$token" METHOD="$method" URL="http://account-service${path}" BODY="$body" \
    python3 -c '
import json, os, urllib.error, urllib.request
headers = {"Authorization": "Bearer " + os.environ["TOKEN"]}
data = None
if os.environ["METHOD"] == "POST":
    data = os.environ["BODY"].encode()
    headers["Content-Type"] = "application/json"
req = urllib.request.Request(os.environ["URL"], method=os.environ["METHOD"], data=data, headers=headers)
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
echo "     (account-serviceは自身のegress Envoy経由でanalyst-attribute-serviceへさらに委任し、表5のABAC判定を行う。表3)"
ACCOUNT_SERVICE_RESPONSE=$(call_account_service GET /accounts/123/transactions "$DELEGATED_TOKEN")
echo "$ACCOUNT_SERVICE_RESPONSE"
if echo "$ACCOUNT_SERVICE_RESPONSE" | grep -q '"region":"tokyo"'; then
  echo "==> 2a'. account-service→analyst-attribute-serviceへの委任(表3)・表5のABAC判定(yamada-analyst=東京担当→ALLOW)を確認(期待通り)"
else
  echo "警告:account-service経由でanalyst-attribute-serviceへ到達できませんでした、またはABAC判定が期待と異なります" >&2
fi

echo "==> 2b. fraud-mcp-server egress Envoy経由でaccount-serviceのPOST(account:propose)を叩く"
call_account_service POST /accounts/123/unfreeze-proposals "$DELEGATED_TOKEN" '{"reasoning":"直近の取引パターンを確認したが誤検知の疑いが強い"}'

echo "==> 2c.(異常系)aud=frontendのログイントークンでそのまま叩く(拒否されるはず)"
call_account_service GET /accounts/123/transactions "$YAMADA_RAW_TOKEN" || true

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
  local method="$1" path="$2" body="${3:-{\}}"
  kubectl -n "$NAMESPACE" exec "$FRAUD_DETECTION_ENGINE_POD" -c client-credentials -- env \
    METHOD="$method" URL="http://account-service${path}" BODY="$body" \
    python3 -c '
import os, urllib.error, urllib.request
headers = {}
data = None
if os.environ["METHOD"] == "POST":
    data = os.environ["BODY"].encode()
    headers["Content-Type"] = "application/json"
req = urllib.request.Request(os.environ["URL"], method=os.environ["METHOD"], data=data, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(resp.status)
        print(resp.read().decode())
except urllib.error.HTTPError as e:
    print(e.code)
    print(e.read().decode())
'
}

# ADR 0027:診断用ループバックAPI(127.0.0.1:9000、Envoyを経由しないPod内直接到達。
# Pod内は全コンテナがネットワーク名前空間を共有するため、appコンテナ以外からも到達できる)を
# client-credentialsコンテナ(Pythonが残っている)から叩く。
fraud_detection_engine_detections() {
  kubectl -n "$NAMESPACE" exec "$FRAUD_DETECTION_ENGINE_POD" -c client-credentials -- \
    python3 -c '
import urllib.request
with urllib.request.urlopen("http://127.0.0.1:9000/detections", timeout=5) as resp:
    print(resp.read().decode())
'
}

echo "==> 4. fraud-detection-engineが起動後に自律的にデモ用4口座(123/456/789/999)を検知・凍結したことを確認する(UC0。ADR 0027)"
echo "     (6c以降のABAC検証がaccount-service /accounts/frozen の結果セットに依存するため、4口座全てを待ち合わせる)"
DETECTIONS=""
for _ in $(seq 1 30); do
  DETECTIONS=$(fraud_detection_engine_detections || true)
  ALL_FOUND=1
  for id in 123 456 789 999; do
    echo "$DETECTIONS" | grep -q "\"accountId\":\"$id\"" || ALL_FOUND=0
  done
  [ "$ALL_FOUND" = 1 ] && break
  sleep 1
done
echo "$DETECTIONS"
if [ "$ALL_FOUND" = 1 ]; then
  echo "==> 4'. fraud-detection-engineの自律的な検知・凍結(client_credentials、scope=account:freeze)を確認(期待通り)"
else
  echo "警告:fraud-detection-engineが4口座全てを検知・凍結しませんでした" >&2
fi

echo "==> 4b.(異常系)fraud-detection-engine egress Envoy経由でaccount-serviceのGET(account:read)を叩く(account:freezeしか持たないため拒否されるはず)"
call_account_service_no_auth GET /accounts/123/transactions || true

# fraud-detection-engineの検知記録(detections)は一度凍結を依頼した口座を二度と再依頼しない
# (実際の不正検知エンジンが、人間が確定解除した口座を毎スキャン周期ごとに勝手に再凍結しては
# ならないのと同じ理由。ADR 0027)。そのため、このスクリプトを2回連続実行すると前回のステップ6
# (確定パスの凍結解除)で既にaccount 123が未凍結になっており、以降の確定パステストの前提が
# 崩れる。UC0自体の検証は既にステップ4で完了しているため、ここでは純粋にテストフィクスチャとして
# (旧パターン②の手動freeze呼び出しと同じ技法で)account 123を確実に凍結状態へ戻す。
echo "==> 4c. (テストフィクスチャ)確定パス(ステップ6)の前提として、account 123が凍結状態であることを保証する"
call_account_service_no_auth POST /accounts/123/freeze '{"reason":"短時間に連続する高額送金を検知","ruleFired":"RULE_RAPID_TRANSFER","score":0.82}'

echo "==> 5. frontend経由でaccount-serviceのGET(account:read)を叩く(edge-proxy→frontend ingress(mTLS)"
echo "     →frontend app(gekko_session Cookie復号)→frontend egress(Token Exchange)→account-service ingress、"
echo "     全区間を実際のfrontendから検証。ADR 0024/0031)"
FRONTEND_READ_RESPONSE=$(curl -s -X GET "$EDGE/accounts/123/transactions" -b "$YAMADA_JAR")
echo "$FRONTEND_READ_RESPONSE"
if echo "$FRONTEND_READ_RESPONSE" | grep -q '"region":"tokyo"'; then
  echo "==> 5'. frontend→account-service→analyst-attribute-serviceの全区間委任・表5のABAC判定を確認(期待通り)"
else
  echo "警告:frontend経由でaccount-serviceへ到達できませんでした、またはABAC判定が期待と異なります" >&2
fi

echo "==> 6. frontend経由でaccount-serviceのPOST /unfreeze(account:unfreeze、確定パス。account-serviceの新規rbacポリシー)を叩く"
echo "     (直前のステップ4でaccount 123を凍結済みにしてあるため、何度スクリプトを再実行してもこのunfreezeは成功するはず)"
FRONTEND_UNFREEZE_RESPONSE=$(curl -s -X POST "$EDGE/accounts/123/unfreeze" -b "$YAMADA_JAR" -H "Content-Type: application/json" -d '{}')
echo "$FRONTEND_UNFREEZE_RESPONSE"
if echo "$FRONTEND_UNFREEZE_RESPONSE" | grep -q '"accountId":"123"'; then
  echo "==> 6'. account-serviceのunfreeze rbacポリシー(ADR 0024で新規追加)・凍結解除の実行を確認(期待通り)"
else
  echo "警告:frontend経由でaccount-serviceのunfreezeへ到達できませんでした" >&2
fi

echo "==> 6b.(異常系)ログアウト後にgekko_session Cookieが失効し、別ユーザーへ切り替えられることを確認(ADR 0031設計判断3・4)"
YAMADA_JAR_SPENT=$(mktemp)
cp "$YAMADA_JAR" "$YAMADA_JAR_SPENT"
curl -s -o /dev/null -X POST -c "$YAMADA_JAR_SPENT" -b "$YAMADA_JAR_SPENT" "$EDGE/logout"
LOGOUT_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -b "$YAMADA_JAR_SPENT" "$EDGE/me")
[ "$LOGOUT_STATUS" = "401" ] && echo "     期待通り:ログアウト後は/meが401(セッション失効)" || echo "     警告:ログアウト後も/meが$LOGOUT_STATUS(セッションが残っている可能性)" >&2
rm -f "$YAMADA_JAR_SPENT"

echo "==> 6c. 表5のABAC判定を実機検証する(BR1・BR2・BR3)"
SUZUKI_SENIOR_PASSWORD=$(cat "$SECRETS_DIR/suzuki-senior-password")
TANAKA_JUNIOR_PASSWORD=$(cat "$SECRETS_DIR/tanaka-junior-password")
SUZUKI_JAR=$(mktemp)
TANAKA_JAR=$(mktemp)
login_via_frontend suzuki-senior "$SUZUKI_SENIOR_PASSWORD" "$SUZUKI_JAR"
login_via_frontend tanaka-junior "$TANAKA_JUNIOR_PASSWORD" "$TANAKA_JAR"

echo "     6c-1. yamada-analyst(junior・東京)が東京のhigh-value口座(789)を読もうとして404になること(BR2)"
YAMADA_789_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X GET "$EDGE/accounts/789/transactions" -b "$YAMADA_JAR")
[ "$YAMADA_789_STATUS" = "404" ] && echo "        期待通り(404)" || echo "        警告:期待は404だが実際は$YAMADA_789_STATUS" >&2

echo "     6c-2. yamada-analyst(担当地域=東京)が大阪の口座(999)を読もうとして404になること(BR1)"
YAMADA_999_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X GET "$EDGE/accounts/999/transactions" -b "$YAMADA_JAR")
[ "$YAMADA_999_STATUS" = "404" ] && echo "        期待通り(404)" || echo "        警告:期待は404だが実際は$YAMADA_999_STATUS" >&2

echo "     6c-3. suzuki-senior(senior・東京/大阪)は大阪のhigh-value口座(456)を読めること(BR3)"
SUZUKI_456_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X GET "$EDGE/accounts/456/transactions" -b "$SUZUKI_JAR")
[ "$SUZUKI_456_STATUS" = "200" ] && echo "        期待通り(200)" || echo "        警告:期待は200だが実際は$SUZUKI_456_STATUS" >&2

echo "     6c-4. tanaka-junior(junior・大阪)は大阪のstandard口座(999)を読めること(BR1・BR2)"
TANAKA_999_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X GET "$EDGE/accounts/999/transactions" -b "$TANAKA_JAR")
[ "$TANAKA_999_STATUS" = "200" ] && echo "        期待通り(200)" || echo "        警告:期待は200だが実際は$TANAKA_999_STATUS" >&2

echo "     6c-5. GET /accounts/frozen はアナリストごとに異なる結果セットを返す(architecture.md UC3/UC4の「除外」)"
YAMADA_FROZEN=$(curl -s -X GET "$EDGE/accounts/frozen" -b "$YAMADA_JAR")
SUZUKI_FROZEN=$(curl -s -X GET "$EDGE/accounts/frozen" -b "$SUZUKI_JAR")
echo "        yamada-analyst(junior・東京): $YAMADA_FROZEN"
echo "        suzuki-senior(senior・東京/大阪): $SUZUKI_FROZEN"
if echo "$YAMADA_FROZEN" | grep -q '"id":"789"'; then
  echo "        警告:yamada-analystの結果に東京のhigh-value口座(789)が含まれています(BR2違反)" >&2
else
  echo "        期待通り:yamada-analystの結果セットから789(high-value)は除外されている"
fi
if echo "$SUZUKI_FROZEN" | grep -q '"id":"456"'; then
  echo "        期待通り:suzuki-seniorの結果セットに大阪のhigh-value口座(456)が含まれている"
else
  echo "        警告:suzuki-seniorの結果セットに456が含まれていません(BR3違反の疑い)" >&2
fi

echo "==> 7. frontend経由でfraud-agentのチャット開始(/chat、audience=fraud-agent)を叩く(edge-proxy→frontend ingress→"
echo "     frontend egress→fraud-agent ingress→fraud-agent egress→fraud-mcp-server ingress、全区間を実際のfrontendから検証。"
echo "     ADR 0023が『frontend実装まで検証できない』としていたfraud-agent自身のingress側もここで初めて実機検証される)"
# ADR 0030:fraud-agentはAG-UIプロトコル(公式`@ag-ui/claude-agent-sdk`アダプタ)に準拠し、
# レスポンスをSSE(text/event-stream)で返す。実際にAnthropic APIを呼ぶため実行時間は不定長だが、
# Envoy側は総時間の上限ではなくidle_timeout(無活動時間の上限)で制御する方式にした
# (k8s/frontend・edge-proxy/envoy-configmap.yaml参照)。このテストスクリプト自身の待ち時間予算
# として--max-time 240を設定する(本番の制御方式とは別に、テストが無限に待ち続けないための保険)。
FRONTEND_CHAT_RESPONSE=$(curl -s --max-time 240 -X POST "$EDGE/chat" -b "$YAMADA_JAR" -d '{}')
echo "$FRONTEND_CHAT_RESPONSE"
if echo "$FRONTEND_CHAT_RESPONSE" | grep -q '"type":"RUN_FINISHED"' && ! echo "$FRONTEND_CHAT_RESPONSE" | grep -q '"type":"RUN_ERROR"'; then
  echo "==> 7'. frontend→fraud-agent→fraud-mcp-serverの全区間委任を確認(期待通り。fraud-agentが"
  echo "     実際にAnthropic APIを呼びfraud-mcp-server経由でaccount-serviceへ問い合わせ、"
  echo "     AG-UIイベントストリームがRUN_ERROR無しでRUN_FINISHEDまで到達した)"
else
  echo "警告:frontend経由でfraud-agent→fraud-mcp-serverへ到達できなかった、またはRUN_ERRORが発生しました" >&2
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
