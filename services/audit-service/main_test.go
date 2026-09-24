// evaluateCheckが本ADRの核心の主張(自己申告に対応する第三者記録が無ければ不整合として検知する)を
// 実際に満たすことを検証する。実機(kubectl port-forward svc/audit-service経由)での確認は
// 正常系(自己申告と第三者記録が揃っている場合に全件verifiedになる)のみ行った。account-serviceの
// DBを直接改ざんして不整合系を実機再現するには本番相当の認証情報操作が要るため、ここでは
// 決定的なロジックそのものをユニットテストで検証する(ADR 0040/0041/0044)。
package main

import (
	"testing"
	"time"
)

func TestEvaluateCheck_TokenIssuedAndRequestReached(t *testing.T) {
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	issued := map[string]bool{"jti-1": true}
	logs := []accountServiceAccessLogEntry{
		{Method: "POST", Path: "/accounts/123/unfreeze", ResponseCode: 200, Jti: "jti-1"},
	}
	got := evaluateCheck("analyst-1", at, "jti-1", issued, logs, "/accounts/123/unfreeze")
	if !got.TokenIssued {
		t.Fatal("expected TokenIssued=true: Keycloak issued a token with this jti")
	}
	if !got.RequestReachedAccountService {
		t.Fatal("expected RequestReachedAccountService=true: access log shows a 2xx POST to the expected path with this jti")
	}
	if !got.Verified {
		t.Fatal("expected Verified=true when both checks pass")
	}
}

func TestEvaluateCheck_NoTokenIssuedAtAll(t *testing.T) {
	// 自己申告(account-serviceのDB)は存在するが、対応するKeycloak TOKEN_EXCHANGEイベントが
	// 第三者記録に一切無いケース。account-serviceが改ざん・侵害された場合に生じる不整合そのもの。
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	issued := map[string]bool{}
	var logs []accountServiceAccessLogEntry
	got := evaluateCheck("analyst-1", at, "jti-1", issued, logs, "/accounts/123/unfreeze")
	if got.TokenIssued {
		t.Fatal("expected TokenIssued=false: no third-party token issuance evidence exists")
	}
	if got.Verified {
		t.Fatal("expected Verified=false")
	}
}

func TestEvaluateCheck_TokenIssuedButNeverUsedAgainstAccountService(t *testing.T) {
	// Keycloakはこのjtiでトークンを発行したが、account-service自身のEnvoy ingressアクセスログには
	// 対応するリクエストが記録されていないケース(発行されたが使われなかった、または全く別の
	// パスに使われた)。トークンの存在だけでは「その操作が実際に行われた」ことの裏付けにならない
	// ことを示す(ADR 0044がEnvoyアクセスログを追加した理由そのもの)。
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	issued := map[string]bool{"jti-1": true}
	var logs []accountServiceAccessLogEntry
	got := evaluateCheck("analyst-1", at, "jti-1", issued, logs, "/accounts/123/unfreeze")
	if !got.TokenIssued {
		t.Fatal("expected TokenIssued=true")
	}
	if got.RequestReachedAccountService {
		t.Fatal("expected RequestReachedAccountService=false: no matching access log entry")
	}
	if got.Verified {
		t.Fatal("expected Verified=false when the request never reached account-service")
	}
}

func TestEvaluateCheck_WrongJtiInAccessLogDoesNotMatch(t *testing.T) {
	// 同じパスへの2xxリクエストが記録されていても、jtiが一致しなければ別のリクエストの記録に
	// すぎない(決定的なキー一致の要件:jtiの完全一致)。
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	issued := map[string]bool{"jti-1": true}
	logs := []accountServiceAccessLogEntry{
		{Method: "POST", Path: "/accounts/123/unfreeze", ResponseCode: 200, Jti: "someone-elses-jti"},
	}
	got := evaluateCheck("analyst-1", at, "jti-1", issued, logs, "/accounts/123/unfreeze")
	if got.RequestReachedAccountService {
		t.Fatal("expected no match: jti differs even though path and status coincide")
	}
}

func TestEvaluateCheck_WrongPathDoesNotMatch(t *testing.T) {
	// jtiが一致していても、実際に届いたAPIパスが自己申告の操作(例:却下)と異なる(例:承認)場合は
	// 一致とみなさない。トークンが発行された目的と、実際に使われた操作が食い違うケースを検知する。
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	issued := map[string]bool{"jti-1": true}
	logs := []accountServiceAccessLogEntry{
		{Method: "POST", Path: "/accounts/123/unfreeze-proposals/p1/approve", ResponseCode: 200, Jti: "jti-1"},
	}
	got := evaluateCheck("analyst-1", at, "jti-1", issued, logs, "/accounts/123/unfreeze-proposals/p1/reject")
	if got.RequestReachedAccountService {
		t.Fatal("expected no match: access log path does not match the expected (rejected) path")
	}
}

func TestEvaluateCheck_NonSuccessResponseDoesNotMatch(t *testing.T) {
	// 届いたリクエストが失敗(4xx/5xx)だった場合、操作は実際には成功していないため裏付けにならない。
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	issued := map[string]bool{"jti-1": true}
	logs := []accountServiceAccessLogEntry{
		{Method: "POST", Path: "/accounts/123/unfreeze", ResponseCode: 409, Jti: "jti-1"},
	}
	got := evaluateCheck("analyst-1", at, "jti-1", issued, logs, "/accounts/123/unfreeze")
	if got.RequestReachedAccountService {
		t.Fatal("expected no match: response was not 2xx")
	}
}

func TestEvaluateCheck_QueryStringInPathIsIgnored(t *testing.T) {
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	issued := map[string]bool{"jti-1": true}
	logs := []accountServiceAccessLogEntry{
		{Method: "POST", Path: "/accounts/123/unfreeze?foo=bar", ResponseCode: 200, Jti: "jti-1"},
	}
	got := evaluateCheck("analyst-1", at, "jti-1", issued, logs, "/accounts/123/unfreeze")
	if !got.RequestReachedAccountService {
		t.Fatal("expected match: query string should not affect path comparison")
	}
}

func TestParseSince_DefaultsToWindowWhenEmpty(t *testing.T) {
	got, err := parseSince("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	wantApprox := time.Now().UTC().Add(-defaultWindow)
	if diff := got.Sub(wantApprox); diff < -5*time.Second || diff > 5*time.Second {
		t.Fatalf("expected ~%v, got %v", wantApprox, got)
	}
}

func TestParseSince_RejectsInvalidFormat(t *testing.T) {
	if _, err := parseSince("not-a-timestamp"); err == nil {
		t.Fatal("expected error for invalid RFC3339 input")
	}
}

func strPtr(s string) *string { return &s }

func TestBuildReconcileResult_GroupsDecisionAndExecutionUnderTheirProposal(t *testing.T) {
	// リクエスト(提案)単位の突合結果が主役であることを検証する:同じproposalIdを持つ決定・実行が
	// 1つのunfreezeRequestAuditにまとまり、それぞれ正しいAPIパスへの2xxアクセスログと突合される。
	decidedAt := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	executedAt := decidedAt.Add(5 * time.Minute)
	proposals := []unfreezeProposal{
		{ID: "p1", AccountID: "acc-1", Status: "approved", DecidedBySub: strPtr("suzuki-senior"),
			DecidedAt: &decidedAt, DecidedJti: strPtr("decide-jti")},
	}
	executions := []unfreezeExecution{
		{ID: 1, AccountID: "acc-1", ProposalID: strPtr("p1"), ExecutedBySub: "suzuki-senior",
			ExecutedAt: executedAt, ExecutedJti: "execute-jti"},
	}
	issued := map[string]bool{"decide-jti": true, "execute-jti": true}
	logs := []accountServiceAccessLogEntry{
		{Method: "POST", Path: "/accounts/acc-1/unfreeze-proposals/p1/approve", ResponseCode: 200, Jti: "decide-jti"},
		{Method: "POST", Path: "/accounts/acc-1/unfreeze", ResponseCode: 200, Jti: "execute-jti"},
	}

	got := buildReconcileResult(proposals, executions, issued, logs, decidedAt.Add(-time.Hour), executedAt.Add(time.Hour))

	if len(got.Requests) != 1 {
		t.Fatalf("expected 1 request, got %d", len(got.Requests))
	}
	req := got.Requests[0]
	if req.Decision == nil || !req.Decision.Verified {
		t.Fatal("expected decision to be verified")
	}
	if req.Execution == nil || !req.Execution.Verified {
		t.Fatal("expected execution to be verified")
	}
	if len(got.DirectExecutions) != 0 {
		t.Fatalf("expected no direct executions, got %d", len(got.DirectExecutions))
	}
}

func TestBuildReconcileResult_RejectedProposalChecksTheRejectPath(t *testing.T) {
	// status=rejectedの場合、承認(approve)ではなく却下(reject)のパスと突合しなければならない。
	decidedAt := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	proposals := []unfreezeProposal{
		{ID: "p1", AccountID: "acc-1", Status: "rejected", DecidedBySub: strPtr("suzuki-senior"),
			DecidedAt: &decidedAt, DecidedJti: strPtr("decide-jti")},
	}
	issued := map[string]bool{"decide-jti": true}
	logs := []accountServiceAccessLogEntry{
		// approveパスに(誤って)一致するログしか無い場合はverifiedにならないはず。
		{Method: "POST", Path: "/accounts/acc-1/unfreeze-proposals/p1/approve", ResponseCode: 200, Jti: "decide-jti"},
	}

	got := buildReconcileResult(proposals, nil, issued, logs, decidedAt.Add(-time.Hour), decidedAt.Add(time.Hour))
	if got.Requests[0].Decision.Verified {
		t.Fatal("expected not verified: access log shows approve, but the self-report says rejected")
	}

	logs = append(logs, accountServiceAccessLogEntry{
		Method: "POST", Path: "/accounts/acc-1/unfreeze-proposals/p1/reject", ResponseCode: 200, Jti: "decide-jti",
	})
	got = buildReconcileResult(proposals, nil, issued, logs, decidedAt.Add(-time.Hour), decidedAt.Add(time.Hour))
	if !got.Requests[0].Decision.Verified {
		t.Fatal("expected verified once the reject path is present in the access log")
	}
}

func TestBuildReconcileResult_DecidedButNotYetExecutedProposalHasNilExecution(t *testing.T) {
	// 却下された、またはまだ実行されていない提案は、Executionがnilのまま(「未実行」)であるべきで、
	// 「実行されたが不一致」と誤って表示してはならない。
	decidedAt := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	proposals := []unfreezeProposal{
		{ID: "p1", AccountID: "acc-1", Status: "rejected", DecidedBySub: strPtr("suzuki-senior"),
			DecidedAt: &decidedAt, DecidedJti: strPtr("decide-jti")},
	}
	issued := map[string]bool{"decide-jti": true}
	logs := []accountServiceAccessLogEntry{
		{Method: "POST", Path: "/accounts/acc-1/unfreeze-proposals/p1/reject", ResponseCode: 200, Jti: "decide-jti"},
	}

	got := buildReconcileResult(proposals, nil, issued, logs, decidedAt.Add(-time.Hour), decidedAt.Add(time.Hour))

	if len(got.Requests) != 1 {
		t.Fatalf("expected 1 request, got %d", len(got.Requests))
	}
	if got.Requests[0].Execution != nil {
		t.Fatal("expected Execution to be nil for a rejected proposal with no execution record")
	}
}

func TestBuildReconcileResult_ExecutionWithoutProposalIsListedAsDirect(t *testing.T) {
	// proposalIdを伴わない凍結解除実行(AIの提案に基づかない直接実行経路)は、どの提案にも属さないため
	// Requestsではなく別枠のDirectExecutionsに入る。これが「提案件数」と「実行件数」が一致しなくても
	// 異常ではない理由。
	executedAt := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	executions := []unfreezeExecution{
		{ID: 1, AccountID: "acc-1", ProposalID: nil, ExecutedBySub: "suzuki-senior",
			ExecutedAt: executedAt, ExecutedJti: "execute-jti"},
	}
	issued := map[string]bool{"execute-jti": true}
	logs := []accountServiceAccessLogEntry{
		{Method: "POST", Path: "/accounts/acc-1/unfreeze", ResponseCode: 200, Jti: "execute-jti"},
	}

	got := buildReconcileResult(nil, executions, issued, logs, executedAt.Add(-time.Hour), executedAt.Add(time.Hour))

	if len(got.Requests) != 0 {
		t.Fatalf("expected 0 requests, got %d", len(got.Requests))
	}
	if len(got.DirectExecutions) != 1 {
		t.Fatalf("expected 1 direct execution, got %d", len(got.DirectExecutions))
	}
	if !got.DirectExecutions[0].Check.Verified {
		t.Fatal("expected the direct execution's check to be verified")
	}
}
