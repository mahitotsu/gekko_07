// hasMatchが本ADRの核心の主張(自己申告に対応する第三者記録が無ければ不整合として検知する)を
// 実際に満たすことを検証する。実機(kubectl port-forward svc/audit-service経由)での確認は
// 正常系(自己申告と第三者記録が揃っている場合に全件verifiedになる)のみ行った。account-serviceの
// DBを直接改ざんして不整合系を実機再現するには本番相当の認証情報操作が要るため、ここでは
// 決定的なロジックそのものをユニットテストで検証する(ADR 0040/0041)。
package main

import (
	"testing"
	"time"
)

func TestHasMatch_ExactSubAndTimeWithinTolerance(t *testing.T) {
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	events := []tokenExchangeEvent{
		{sub: "analyst-1", at: at.Add(2 * time.Second)},
	}
	if !hasMatch(events, "analyst-1", at, 60*time.Second) {
		t.Fatal("expected match: same sub, within tolerance")
	}
}

func TestHasMatch_NoCorrespondingThirdPartyEvent(t *testing.T) {
	// 自己申告(account-serviceのDB)は存在するが、対応するKeycloak TOKEN_EXCHANGEイベントが
	// 第三者記録に一切無いケース。account-serviceが改ざん・侵害された場合に生じる不整合そのもの。
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	var events []tokenExchangeEvent
	if hasMatch(events, "analyst-1", at, 60*time.Second) {
		t.Fatal("expected no match: no third-party evidence exists at all")
	}
}

func TestHasMatch_WrongSubDoesNotMatch(t *testing.T) {
	// 同時刻に別人(sub違い)のToken Exchangeイベントがあっても、それを他人の自己申告の裏付けとして
	// 誤って認めてはならない(決定的キー一致の要件:sub + 時刻の両方)。
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	events := []tokenExchangeEvent{
		{sub: "someone-else", at: at},
	}
	if hasMatch(events, "analyst-1", at, 60*time.Second) {
		t.Fatal("expected no match: sub differs even though timestamp coincides")
	}
}

func TestHasMatch_OutsideToleranceDoesNotMatch(t *testing.T) {
	// subは一致するが、許容時間を超えて離れたToken Exchangeイベントは無関係の操作とみなし、
	// 誤って裏付けとして採用してはならない。
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	events := []tokenExchangeEvent{
		{sub: "analyst-1", at: at.Add(10 * time.Minute)},
	}
	if hasMatch(events, "analyst-1", at, 60*time.Second) {
		t.Fatal("expected no match: event is outside the tolerance window")
	}
}

func TestHasMatch_ToleranceIsSymmetric(t *testing.T) {
	// Token Exchangeがaccount-serviceの自己申告書き込みより先行する(通常の順序)場合だけでなく、
	// 逆順(時計のずれ等でイベント側のタイムスタンプが後になる)でも同様に許容範囲内なら一致とみなす。
	at := time.Date(2026, 9, 24, 10, 0, 0, 0, time.UTC)
	before := []tokenExchangeEvent{{sub: "analyst-1", at: at.Add(-30 * time.Second)}}
	after := []tokenExchangeEvent{{sub: "analyst-1", at: at.Add(30 * time.Second)}}
	if !hasMatch(before, "analyst-1", at, 60*time.Second) {
		t.Fatal("expected match: event 30s before self-report, within 60s tolerance")
	}
	if !hasMatch(after, "analyst-1", at, 60*time.Second) {
		t.Fatal("expected match: event 30s after self-report, within 60s tolerance")
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
