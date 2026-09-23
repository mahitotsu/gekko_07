// audit-serviceの本実装(ADR 0007:Go標準ライブラリ。ADR 0040/0041)。
//
// account-service自身の自己申告(unfreeze_proposals.decided_*/unfreeze_executions.executed_*、
// /auditの読み取り専用API)と、Keycloakのイベントログ(第三者記録、account-serviceの外側で
// 独立に生成される。ADR 0025でLokiへ集約済み)を突き合わせ、決定的なキー一致判定(sub+時刻の
// 近接)のみで不整合を検知する。LLMは一切使わない(ADR 0040:検証者自身が検証対象のAIと同種の
// 非決定性を持つと本ADRの前提が崩れるため)。
//
// ステートレス(ADR 0040):自身の永続ストアは持たず、呼び出しの都度2系統を取得して突合するのみ。
//
// ADR 0009 §2の多層防御のうち①②(loopback限定bind・接続元loopbackチェック)のみ引き継ぐ。
// ③(合言葉ヘッダー)は、このサービスのEnvoy ingressにjwt_authn/rbacを一切持たせていない
// (ADR 0040/0041:誰が結果を閲覧できるかは未決定の将来課題。今回はkubectl port-forwardでの
// 到達のみを前提にする、Grafanaと同じ位置づけ)ため、"rbac通過後にのみ付与"という③の前提自体が
// 成立しない(検知すべきバイパス対象が無い)。jwt_authn/rbacを追加する際に③も追加する。
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
	"time"
)

const defaultWindow = 24 * time.Hour

func main() {
	accountServiceURL := getenv("ACCOUNT_SERVICE_URL", "http://account-service")
	lokiURL := getenv("LOKI_URL", "http://otel-lgtm.observability.svc.cluster.local:3100")
	tolerance := durationSecondsEnv("TOLERANCE_SECONDS", 60)

	rec := &reconciler{
		httpClient:        &http.Client{Timeout: 15 * time.Second},
		accountServiceURL: accountServiceURL,
		lokiURL:           lokiURL,
		tolerance:         tolerance,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /reconcile", rec.handleReconcile)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := withLoopbackCheck(mux)

	bindHost := getenv("APP_BIND_HOST", "127.0.0.1")
	bindPort := getenv("APP_PORT", "9000")
	addr := net.JoinHostPort(bindHost, bindPort)

	srv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("audit-service listening on %s (account-service=%s loki=%s tolerance=%s)",
		addr, accountServiceURL, lokiURL, tolerance)
	log.Fatal(srv.ListenAndServe())
}

// --- 自己申告(account-service)のDTO。フィールド名はUnfreezeProposal/UnfreezeExecution
// (services/account-service/.../domain/)のJSONシリアライズ結果とそのまま一致させる。 ---

type unfreezeProposal struct {
	ID             string     `json:"id"`
	AccountID      string     `json:"accountId"`
	ProposedBySub  string     `json:"proposedBySub"`
	CreatedAt      time.Time  `json:"createdAt"`
	Status         string     `json:"status"`
	DecidedBySub   *string    `json:"decidedBySub"`
	DecidedAt      *time.Time `json:"decidedAt"`
	Recommendation string     `json:"recommendation"`
}

type unfreezeExecution struct {
	ID            int64     `json:"id"`
	AccountID     string    `json:"accountId"`
	ProposalID    *string   `json:"proposalId"`
	ExecutedBySub string    `json:"executedBySub"`
	ExecutedAt    time.Time `json:"executedAt"`
}

// --- 突合結果 ---

type unverifiedRecord struct {
	Kind       string    `json:"kind"` // "decision" | "execution"
	ProposalID string    `json:"proposalId,omitempty"`
	AccountID  string    `json:"accountId"`
	Sub        string    `json:"sub"`
	At         time.Time `json:"at"`
}

type categoryResult struct {
	Total      int                `json:"total"`
	Verified   int                `json:"verified"`
	Unverified []unverifiedRecord `json:"unverified"`
}

type reconcileResult struct {
	Since            time.Time      `json:"since"`
	Until            time.Time      `json:"until"`
	ToleranceSeconds int            `json:"toleranceSeconds"`
	Decisions        categoryResult `json:"decisions"`
	Executions       categoryResult `json:"executions"`
}

type reconciler struct {
	httpClient        *http.Client
	accountServiceURL string
	lokiURL           string
	tolerance         time.Duration
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
	tokenExchanges, err := rec.fetchUnfreezeTokenExchanges(r.Context(), since, until)
	if err != nil {
		log.Printf("fetch loki events failed: %v", err)
		http.Error(w, "failed to fetch third-party evidence from Loki", http.StatusBadGateway)
		return
	}

	result := reconcileResult{
		Since:            since,
		Until:            until,
		ToleranceSeconds: int(rec.tolerance.Seconds()),
		Decisions:        categoryResult{Unverified: []unverifiedRecord{}},
		Executions:       categoryResult{Unverified: []unverifiedRecord{}},
	}

	for _, p := range proposals {
		if p.DecidedBySub == nil || p.DecidedAt == nil {
			continue
		}
		result.Decisions.Total++
		if hasMatch(tokenExchanges, *p.DecidedBySub, *p.DecidedAt, rec.tolerance) {
			result.Decisions.Verified++
		} else {
			result.Decisions.Unverified = append(result.Decisions.Unverified, unverifiedRecord{
				Kind: "decision", ProposalID: p.ID, AccountID: p.AccountID, Sub: *p.DecidedBySub, At: *p.DecidedAt,
			})
		}
	}
	for _, e := range executions {
		result.Executions.Total++
		if hasMatch(tokenExchanges, e.ExecutedBySub, e.ExecutedAt, rec.tolerance) {
			result.Executions.Verified++
		} else {
			proposalID := ""
			if e.ProposalID != nil {
				proposalID = *e.ProposalID
			}
			result.Executions.Unverified = append(result.Executions.Unverified, unverifiedRecord{
				Kind: "execution", ProposalID: proposalID, AccountID: e.AccountID, Sub: e.ExecutedBySub, At: e.ExecutedAt,
			})
		}
	}

	writeJSON(w, http.StatusOK, result)
}

func parseSince(raw string) (time.Time, error) {
	if raw == "" {
		return time.Now().UTC().Add(-defaultWindow), nil
	}
	return time.Parse(time.RFC3339, raw)
}

// tokenExchangeEvent: Keycloakの第三者記録(TOKEN_EXCHANGE、audience=account-service・
// scope=account:unfreeze)から抽出した最小限のフィールド。
type tokenExchangeEvent struct {
	sub string
	at  time.Time
}

// hasMatch: 自己申告(sub, at)に対応する第三者記録が、許容時間内に存在するかを判定する
// (決定的なキー一致のみ。LLMは使わない)。
func hasMatch(events []tokenExchangeEvent, sub string, at time.Time, tolerance time.Duration) bool {
	for _, ev := range events {
		if ev.sub != sub {
			continue
		}
		diff := ev.at.Sub(at)
		if diff < 0 {
			diff = -diff
		}
		if diff <= tolerance {
			return true
		}
	}
	return false
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

var userIDPattern = regexp.MustCompile(`userId="([^"]*)"`)

type lokiQueryRangeResponse struct {
	Data struct {
		Result []struct {
			Values [][2]string `json:"values"`
		} `json:"result"`
	} `json:"data"`
}

type lokiLogLine struct {
	Timestamp time.Time `json:"timestamp"`
	Message   string    `json:"message"`
}

// fetchUnfreezeTokenExchanges: Keycloakのイベントログ(container=keycloak)から、
// account:unfreezeスコープのTOKEN_EXCHANGEイベントのみを抽出する。このシステムでは
// account:unfreezeスコープは常にaudience=account-serviceの単一audienceトークンにのみ
// 使われる(ADR 0005:単一audience原則。k8s/keycloak/realm-configmap.yamlのoptionalClientScopes
// 割当上、account:unfreezeはfrontendにしか付与されていない)ため、"account:unfreeze"文字列の
// 有無だけでaudience条件も兼ねられる。
func (rec *reconciler) fetchUnfreezeTokenExchanges(ctx context.Context, since, until time.Time) ([]tokenExchangeEvent, error) {
	query := `{namespace="gekko", container="keycloak"} |= "TOKEN_EXCHANGE" |= "account:unfreeze"`
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

	var events []tokenExchangeEvent
	for _, stream := range parsed.Data.Result {
		for _, v := range stream.Values {
			var line lokiLogLine
			if err := json.Unmarshal([]byte(v[1]), &line); err != nil {
				// KeycloakのJSONログ以外(envoyアクセスログ等)が別ストリームに混じる可能性は
				// クエリのlabelセレクタで排除済みだが、パース不能な行はfail closeせずskipする
				// (このイベントが見つからないことは、対応する自己申告側が"unverified"として
				// 検知される形で結果に反映されるため、握りつぶしても安全側)。
				continue
			}
			m := userIDPattern.FindStringSubmatch(line.Message)
			if m == nil {
				continue
			}
			events = append(events, tokenExchangeEvent{sub: m[1], at: line.Timestamp})
		}
	}
	return events, nil
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

func durationSecondsEnv(key string, fallbackSeconds int) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return time.Duration(fallbackSeconds) * time.Second
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return time.Duration(fallbackSeconds) * time.Second
	}
	return time.Duration(n) * time.Second
}
