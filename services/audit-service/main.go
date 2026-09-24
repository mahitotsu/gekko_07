// audit-serviceの本実装(ADR 0007:Go標準ライブラリ。ADR 0040/0041/0042/0044)。
//
// account-service自身の自己申告(unfreeze_proposals.decided_*/unfreeze_executions.executed_*、
// /auditの読み取り専用API)と、2種類の第三者記録(account-serviceの外側で独立に生成される。
// ADR 0025でLokiへ集約済み)を突き合わせる。LLMは一切使わない(ADR 0040:検証者自身が検証対象の
// AIと同種の非決定性を持つと本ADRの前提が崩れるため)。
//
//  1. Keycloakのイベントログ(TOKEN_EXCHANGE)：account:unfreezeスコープのトークンが、
//     自己申告のjti(トークン識別子)と一致するもので実際に発行されたか
//  2. account-service自身のEnvoy ingressアクセスログ：そのjtiを持つリクエストが、
//     対応するAPIパス(承認/却下/実行)に実際に到達し、2xxで応答されたか
//
// 両方確認できて初めて「一致」とする(ADR 0044)。以前は自己申告のsub+時刻近接という近似一致
// だったが、account-serviceが受け取ったリクエストのjti(x-auth-jti)を自己申告に含めるように
// したため、あいまいさの無い完全一致に切り替えた。同じアナリストが短時間に別々の操作を行った
// 場合に、無関係な本物のイベントを誤って裏付けとして採用してしまう(近似一致特有の)偽陽性が
// 構造的に無くなる。jtiを持たない旧形式の自己申告データはこのバージョンでは扱わない
// (サポート対象外。移行期間は設けず、デモデータは初期化した)。
//
// ステートレス(ADR 0040):自身の永続ストアは持たず、呼び出しの都度取得して突合するのみ。
//
// ADR 0042:突合結果を閲覧できるのはsenior analystのみ(表5とは別の軸のゲート。口座ごとの
// 地域/ティア制限は適用しない単純な二値判定)。frontendから委任されたトークン(scope=audit:read)
// のsub(x-auth-sub)を使い、analyst-attribute-serviceへ照会してlevelを確認する。ADR 0009 §2の
// 多層防御①②③(loopback限定bind・接続元loopbackチェック・合言葉ヘッダー)を他サービスと同じ形で
// 引き継ぐ(jwt_authn/rbacが実在するようになったため、③の前提=rbac通過後にのみ付与、が成立する)。
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const defaultWindow = 24 * time.Hour

func main() {
	accountServiceURL := getenv("ACCOUNT_SERVICE_URL", "http://account-service")
	analystAttributeServiceURL := getenv("ANALYST_ATTRIBUTE_SERVICE_URL", "http://analyst-attribute-service")
	lokiURL := getenv("LOKI_URL", "http://otel-lgtm.observability.svc.cluster.local:3100")

	rec := &reconciler{
		httpClient:        &http.Client{Timeout: 15 * time.Second},
		accountServiceURL: accountServiceURL,
		lokiURL:           lokiURL,
	}
	gate := &seniorGate{
		httpClient:                 &http.Client{Timeout: 5 * time.Second},
		analystAttributeServiceURL: analystAttributeServiceURL,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /reconcile", gate.requireSenior(rec.handleReconcile))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handshakeFile := getenv("HANDSHAKE_TOKEN_FILE", "/handshake/token")
	handshakeHeader := getenv("HANDSHAKE_HEADER_NAME", "x-gekko-handshake")
	handler := withHandshakeCheck(handshakeFile, handshakeHeader, withLoopbackCheck(mux))

	bindHost := getenv("APP_BIND_HOST", "127.0.0.1")
	bindPort := getenv("APP_PORT", "9000")
	addr := net.JoinHostPort(bindHost, bindPort)

	srv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("audit-service listening on %s (account-service=%s analyst-attribute-service=%s loki=%s)",
		addr, accountServiceURL, analystAttributeServiceURL, lokiURL)
	log.Fatal(srv.ListenAndServe())
}

// --- senior限定閲覧ゲート(ADR 0042) ---

type analystAttributes struct {
	Level string `json:"level"`
}

type seniorGate struct {
	httpClient                 *http.Client
	analystAttributeServiceURL string
}

// requireSenior: x-auth-sub(jwt_authnがingressで注入済み)とAuthorizationヘッダーを使い、
// analyst-attribute-serviceへ照会してlevel=seniorであることを確認する。表5のABAC判定とは
// 独立な、単純な二値ゲート(地域/ティアによる絞り込みは行わない)。
func (g *seniorGate) requireSenior(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sub := r.Header.Get("x-auth-sub")
		authorization := r.Header.Get("Authorization")
		if sub == "" || authorization == "" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}

		req, err := http.NewRequestWithContext(r.Context(), http.MethodGet,
			g.analystAttributeServiceURL+"/analysts/"+sub, nil)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		req.Header.Set("x-auth-sub", sub)
		req.Header.Set("Authorization", authorization)

		resp, err := g.httpClient.Do(req)
		if err != nil {
			log.Printf("analyst-attribute-service lookup failed: %v", err)
			http.Error(w, "bad gateway", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		var attrs analystAttributes
		if err := json.NewDecoder(resp.Body).Decode(&attrs); err != nil || attrs.Level != "senior" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}

		next(w, r)
	}
}

// --- 自己申告(account-service)のDTO。フィールド名はUnfreezeProposal/UnfreezeExecution
// (services/account-service/.../domain/)のJSONシリアライズ結果とそのまま一致させる。
// DecidedJti/ExecutedJtiは、その決定/実行に使われたトークンのjti(x-auth-jtiヘッダーから
// account-serviceが受け取った値。ADR 0044)。 ---

type unfreezeProposal struct {
	ID             string     `json:"id"`
	AccountID      string     `json:"accountId"`
	ProposedBySub  string     `json:"proposedBySub"`
	CreatedAt      time.Time  `json:"createdAt"`
	Status         string     `json:"status"`
	DecidedBySub   *string    `json:"decidedBySub"`
	DecidedAt      *time.Time `json:"decidedAt"`
	DecidedJti     *string    `json:"decidedJti"`
	Recommendation string     `json:"recommendation"`
}

type unfreezeExecution struct {
	ID            int64     `json:"id"`
	AccountID     string    `json:"accountId"`
	ProposalID    *string   `json:"proposalId"`
	ExecutedBySub string    `json:"executedBySub"`
	ExecutedAt    time.Time `json:"executedAt"`
	ExecutedJti   string    `json:"executedJti"`
}

// --- 突合結果(ADR 0044:リクエスト単位の突合結果表示、jti+Envoyアクセスログによる完全一致判定) ---
//
// 提案(unfreeze_proposals)を単位とし、その提案に対する決定(decided_at)・実行(executed_at)
// それぞれの突合結果を1行にまとめる。提案に紐付かない実行(ProposalID省略の直接実行経路。
// account-service側の仕様上正常な経路)は別枠のDirectExecutionsに分離し、「対応する提案が無い
// こと自体は異常ではない」ことが画面上で区別できるようにする。

// checkResult: 1件の自己申告(sub, at, jti)に対する突合結果。TokenIssuedはKeycloakがこのjtiで
// account:unfreezeスコープのトークンを実際に発行したか、RequestReachedAccountServiceは
// account-service自身のEnvoy ingressアクセスログに、このjtiで対応するAPIパスへの2xxリクエストが
// 記録されているかを、それぞれ独立に示す。両方確認できて初めてVerified=trueとする(片方ずつの
// 結果を見せることで、「トークンは発行されたが実際には使われていない」のような中間状態も
// 閲覧者が区別できるようにするため)。
type checkResult struct {
	Sub                          string    `json:"sub"`
	At                           time.Time `json:"at"`
	Jti                          string    `json:"jti"`
	TokenIssued                  bool      `json:"tokenIssued"`
	RequestReachedAccountService bool      `json:"requestReachedAccountService"`
	Verified                     bool      `json:"verified"`
}

type unfreezeRequestAudit struct {
	ProposalID    string       `json:"proposalId"`
	AccountID     string       `json:"accountId"`
	ProposedBySub string       `json:"proposedBySub"`
	Status        string       `json:"status"`
	Decision      *checkResult `json:"decision,omitempty"`
	Execution     *checkResult `json:"execution,omitempty"`
}

// directExecutionAudit: 提案を経由しない凍結解除実行(unfreeze_executions.proposal_id IS NULL)。
type directExecutionAudit struct {
	AccountID string      `json:"accountId"`
	Check     checkResult `json:"check"`
}

type reconcileResult struct {
	Since            time.Time              `json:"since"`
	Until            time.Time              `json:"until"`
	Requests         []unfreezeRequestAudit `json:"requests"`
	DirectExecutions []directExecutionAudit `json:"directExecutions"`
}

type reconciler struct {
	httpClient        *http.Client
	accountServiceURL string
	lokiURL           string
}

func (rec *reconciler) handleReconcile(w http.ResponseWriter, r *http.Request) {
	since, err := parseSince(r.URL.Query().Get("since"))
	if err != nil {
		http.Error(w, fmt.Sprintf("invalid since: %v", err), http.StatusBadRequest)
		return
	}
	until := time.Now().UTC()

	proposals, err := rec.fetchDecidedProposals(r.Context(), since)
	if err != nil {
		log.Printf("fetch proposals failed: %v", err)
		http.Error(w, "failed to fetch self-reported proposals", http.StatusBadGateway)
		return
	}
	executions, err := rec.fetchExecutions(r.Context(), since)
	if err != nil {
		log.Printf("fetch executions failed: %v", err)
		http.Error(w, "failed to fetch self-reported executions", http.StatusBadGateway)
		return
	}
	issuedJtis, err := rec.fetchUnfreezeTokenIDs(r.Context(), since, until)
	if err != nil {
		log.Printf("fetch keycloak token exchange log failed: %v", err)
		http.Error(w, "failed to fetch third-party evidence from Loki (keycloak)", http.StatusBadGateway)
		return
	}
	accessLogs, err := rec.fetchAccountServiceAccessLogs(r.Context(), since, until)
	if err != nil {
		log.Printf("fetch account-service access log failed: %v", err)
		http.Error(w, "failed to fetch third-party evidence from Loki (envoy access log)", http.StatusBadGateway)
		return
	}

	result := buildReconcileResult(proposals, executions, issuedJtis, accessLogs, since, until)
	writeJSON(w, http.StatusOK, result)
}

// buildReconcileResult: 自己申告(proposals/executions)と第三者記録(issuedJtis/accessLogs)から
// 突合結果を組み立てる、I/Oを持たない純粋な処理(ユニットテストで検証しやすくするため、
// HTTP取得(handleReconcile)から分離)。
func buildReconcileResult(
	proposals []unfreezeProposal,
	executions []unfreezeExecution,
	issuedJtis map[string]bool,
	accessLogs []accountServiceAccessLogEntry,
	since, until time.Time,
) reconcileResult {
	executionsByProposal := make(map[string]unfreezeExecution, len(executions))
	var direct []unfreezeExecution
	for _, e := range executions {
		if e.ProposalID != nil && *e.ProposalID != "" {
			executionsByProposal[*e.ProposalID] = e
		} else {
			direct = append(direct, e)
		}
	}

	requests := make([]unfreezeRequestAudit, 0, len(proposals))
	for _, p := range proposals {
		req := unfreezeRequestAudit{
			ProposalID:    p.ID,
			AccountID:     p.AccountID,
			ProposedBySub: p.ProposedBySub,
			Status:        p.Status,
		}
		if p.DecidedBySub != nil && p.DecidedAt != nil && p.DecidedJti != nil {
			action := "reject"
			if p.Status == "approved" {
				action = "approve"
			}
			expectedPath := fmt.Sprintf("/accounts/%s/unfreeze-proposals/%s/%s", p.AccountID, p.ID, action)
			check := evaluateCheck(*p.DecidedBySub, *p.DecidedAt, *p.DecidedJti, issuedJtis, accessLogs, expectedPath)
			req.Decision = &check
		}
		if e, ok := executionsByProposal[p.ID]; ok {
			expectedPath := fmt.Sprintf("/accounts/%s/unfreeze", e.AccountID)
			check := evaluateCheck(e.ExecutedBySub, e.ExecutedAt, e.ExecutedJti, issuedJtis, accessLogs, expectedPath)
			req.Execution = &check
		}
		requests = append(requests, req)
	}

	directAudits := make([]directExecutionAudit, 0, len(direct))
	for _, e := range direct {
		expectedPath := fmt.Sprintf("/accounts/%s/unfreeze", e.AccountID)
		directAudits = append(directAudits, directExecutionAudit{
			AccountID: e.AccountID,
			Check:     evaluateCheck(e.ExecutedBySub, e.ExecutedAt, e.ExecutedJti, issuedJtis, accessLogs, expectedPath),
		})
	}

	return reconcileResult{
		Since:            since,
		Until:            until,
		Requests:         requests,
		DirectExecutions: directAudits,
	}
}

func parseSince(raw string) (time.Time, error) {
	if raw == "" {
		return time.Now().UTC().Add(-defaultWindow), nil
	}
	return time.Parse(time.RFC3339, raw)
}

// evaluateCheck: 自己申告(sub, at, jti)について、(1)Keycloakがこのjtiでaccount:unfreeze
// スコープのトークンを発行したか、(2)account-service自身のEnvoy ingressアクセスログに、
// このjtiで対応するAPIパスへの2xxリクエストが記録されているか、の2点を判定する
// (決定的なjti完全一致のみ。LLMは使わない。ADR 0044)。
func evaluateCheck(sub string, at time.Time, jti string, issuedJtis map[string]bool, accessLogs []accountServiceAccessLogEntry, expectedPath string) checkResult {
	tokenIssued := issuedJtis[jti]
	reached := accessLogHasSuccess(accessLogs, jti, expectedPath)
	return checkResult{
		Sub:                          sub,
		At:                           at,
		Jti:                          jti,
		TokenIssued:                  tokenIssued,
		RequestReachedAccountService: reached,
		Verified:                     tokenIssued && reached,
	}
}

func accessLogHasSuccess(logs []accountServiceAccessLogEntry, jti, expectedPath string) bool {
	for _, e := range logs {
		if e.Jti != jti {
			continue
		}
		if e.Method != "POST" {
			continue
		}
		if pathWithoutQuery(e.Path) != expectedPath {
			continue
		}
		if e.ResponseCode < 200 || e.ResponseCode > 299 {
			continue
		}
		return true
	}
	return false
}

func pathWithoutQuery(path string) string {
	if i := strings.IndexByte(path, '?'); i >= 0 {
		return path[:i]
	}
	return path
}

func (rec *reconciler) fetchDecidedProposals(ctx context.Context, since time.Time) ([]unfreezeProposal, error) {
	u := rec.accountServiceURL + "/audit/unfreeze-proposals?" + url.Values{"since": {since.Format(time.RFC3339)}}.Encode()
	var out []unfreezeProposal
	if err := rec.getJSON(ctx, u, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (rec *reconciler) fetchExecutions(ctx context.Context, since time.Time) ([]unfreezeExecution, error) {
	u := rec.accountServiceURL + "/audit/unfreeze-executions?" + url.Values{"since": {since.Format(time.RFC3339)}}.Encode()
	var out []unfreezeExecution
	if err := rec.getJSON(ctx, u, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (rec *reconciler) getJSON(ctx context.Context, u string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := rec.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: unexpected status %d", u, resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// --- Loki(第三者記録)からの取得 ---

var tokenIDPattern = regexp.MustCompile(`token_id="([^"]*)"`)

type lokiQueryRangeResponse struct {
	Data struct {
		Result []struct {
			Values [][2]string `json:"values"`
		} `json:"result"`
	} `json:"data"`
}

// lokiLogLine: Keycloakのイベントログの形(Quarkus/JBossロギングのJSON形式。実際のイベント
// フィールド(type/userId/token_id/scope等)はmessage文字列内にkey="value"の並びとして
// 埋め込まれているため、必要な値は正規表現で取り出す)。
type lokiLogLine struct {
	Timestamp time.Time `json:"timestamp"`
	Message   string    `json:"message"`
}

// fetchUnfreezeTokenIDs: Keycloakのイベントログ(container=keycloak)から、account:unfreeze
// スコープのTOKEN_EXCHANGEイベントのtoken_id(=発行されたトークンのjti。account-serviceが
// x-auth-jtiヘッダーとして受け取る値と同一であることを実機確認済み)を抽出する。このシステムでは
// account:unfreezeスコープは常にaudience=account-serviceの単一audienceトークンにのみ使われる
// (ADR 0005:単一audience原則)ため、"account:unfreeze"文字列の有無だけでaudience条件も兼ねられる。
func (rec *reconciler) fetchUnfreezeTokenIDs(ctx context.Context, since, until time.Time) (map[string]bool, error) {
	query := `{namespace="gekko", container="keycloak"} |= "TOKEN_EXCHANGE" |= "account:unfreeze"`
	lines, err := rec.queryLokiLines(ctx, query, since, until)
	if err != nil {
		return nil, err
	}

	ids := make(map[string]bool)
	for _, raw := range lines {
		var line lokiLogLine
		if err := json.Unmarshal([]byte(raw), &line); err != nil {
			// KeycloakのJSONログ以外が別ストリームに混じる可能性はクエリのlabelセレクタで
			// 排除済みだが、パース不能な行はfail closeせずskipする(このイベントが見つからない
			// ことは、対応する自己申告側のcheckResult.TokenIssuedがfalseになる形で結果に
			// 反映されるため、握りつぶしても安全側)。
			continue
		}
		if m := tokenIDPattern.FindStringSubmatch(line.Message); m != nil {
			ids[m[1]] = true
		}
	}
	return ids, nil
}

// accountServiceAccessLogEntry: account-service自身のEnvoy ingressアクセスログ1行
// (k8s/account-service/envoy-configmap.yamlのjson_format)。Keycloakのイベントログと違い
// ログ本文そのものがこの構造を持つJSONなので、lokiLogLineのようなラップは不要。
// jti/sub/scopeは未認証・機械間の一部リクエストではnull(空文字列)になりうる。
type accountServiceAccessLogEntry struct {
	Method       string `json:"method"`
	Path         string `json:"path"`
	ResponseCode int    `json:"response_code"`
	Jti          string `json:"jti"`
}

// fetchAccountServiceAccessLogs: account-serviceのEnvoy ingressアクセスログを取得する。
// Alloyのストリームラベルはnamespace/pod/containerのみでサービス名のラベルが無いため
// (k8s/observability/alloy-configmap.yaml、カーディナリティ抑制のためsub/jti等と同様に
// ラベル化していない)、pod名の前方一致で他サービスのenvoyコンテナと区別する。
func (rec *reconciler) fetchAccountServiceAccessLogs(ctx context.Context, since, until time.Time) ([]accountServiceAccessLogEntry, error) {
	query := `{namespace="gekko", container="envoy", pod=~"account-service-.*"} |= "unfreeze"`
	lines, err := rec.queryLokiLines(ctx, query, since, until)
	if err != nil {
		return nil, err
	}

	entries := make([]accountServiceAccessLogEntry, 0, len(lines))
	for _, raw := range lines {
		var entry accountServiceAccessLogEntry
		if err := json.Unmarshal([]byte(raw), &entry); err != nil {
			continue
		}
		if entry.Jti == "" {
			continue
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

// queryLokiLines: LogQLクエリを実行し、マッチした生ログ行(JSON文字列)をそのまま返す
// (Keycloak/Envoyでログ本文の構造が異なるため、パース自体は呼び出し元が行う)。
func (rec *reconciler) queryLokiLines(ctx context.Context, query string, since, until time.Time) ([]string, error) {
	params := url.Values{
		"query": {query},
		"start": {strconv.FormatInt(since.UnixNano(), 10)},
		"end":   {strconv.FormatInt(until.UnixNano(), 10)},
		"limit": {"5000"},
	}
	u := rec.lokiURL + "/loki/api/v1/query_range?" + params.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := rec.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("loki query_range: unexpected status %d", resp.StatusCode)
	}

	var parsed lokiQueryRangeResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, err
	}

	var lines []string
	for _, stream := range parsed.Data.Result {
		for _, v := range stream.Values {
			lines = append(lines, v[1])
		}
	}
	return lines, nil
}

// ADR 0009 主対策②と同じ考え方:bindアドレスの設定に関係なく、接続元がloopbackでなければ拒否する。
func withLoopbackCheck(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !isLoopback(host) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func isLoopback(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// ADR 0009 §2③と同じ考え方:rbac通過後にのみEnvoyのLuaフィルタが合言葉ヘッダーを付与する。
// 欠落・不一致はどちらも同じfail closeとして扱い、検証をバイパスするフラグは持たない(CWE-489)。
func withHandshakeCheck(handshakeFile, headerName string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		expected, err := os.ReadFile(handshakeFile)
		got := r.Header.Get(headerName)
		if err != nil || got == "" || strings.TrimSpace(string(expected)) != got {
			http.Error(w, "handshake verification failed", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
