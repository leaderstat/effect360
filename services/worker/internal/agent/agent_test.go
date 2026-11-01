package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// req builds a snapshot with the given fields and no requirements.
func req(status string, fields map[string]string) RequestSnapshot {
	return RequestSnapshot{
		ID:      "11111111-1111-1111-1111-111111111111",
		Status:  status,
		RawText: "Текст заявки",
		Fields:  fields,
	}
}

func TestCheckerPassedWhenAllRequiredFieldsFilled(t *testing.T) {
	c := NewChecker()
	snap := req("submitted", map[string]string{
		"destination_city": "Казань",
		"start_date":       "1 июня",
		"end_date":         "10 июня",
	})
	snap.Requirements = []Requirement{
		{FieldName: "destination_city", Required: true, ClauseID: "c1", Quote: "город"},
		{FieldName: "start_date", Required: true, ClauseID: "c2", Quote: "дата"},
	}

	d := c.Check(snap)

	if d.Result != ResultPassed {
		t.Fatalf("expected passed, got %s (problems: %+v)", d.Result, d.Problems)
	}
	if len(d.Problems) != 0 {
		t.Fatalf("expected no problems, got %+v", d.Problems)
	}
	if d.RuleCode != RuleComplete {
		t.Fatalf("expected rule %s, got %s", RuleComplete, d.RuleCode)
	}
}

func TestCheckerNeedsInfoWhenRequiredFieldMissing(t *testing.T) {
	c := NewChecker()
	snap := req("submitted", map[string]string{"destination_city": "Казань"})
	snap.Requirements = []Requirement{
		{FieldName: "destination_city", Required: true},
		{FieldName: "start_date", Required: true},
	}

	d := c.Check(snap)

	if d.Result != ResultNeedsInfo {
		t.Fatalf("expected needs_info, got %s", d.Result)
	}
	if d.RuleCode != RuleMissingFields {
		t.Fatalf("expected rule %s, got %s", RuleMissingFields, d.RuleCode)
	}
	if d.ClarificationRequest == "" {
		t.Fatal("expected a clarification request to be prepared")
	}
	if !strings.Contains(d.ClarificationRequest, "start_date") {
		t.Fatalf("the clarification must name the missing field, got %q", d.ClarificationRequest)
	}
}

func TestCheckerNeedsInfoWhenRequestTypeUnknown(t *testing.T) {
	// Without a request type the server cannot say which requirements
	// apply, so a vacuous "passed" would let an unchecked request through.
	c := NewChecker()
	snap := req("submitted", map[string]string{
		"destination_city": "Казань",
	})

	d := c.Check(snap)

	if d.Result != ResultNeedsInfo {
		t.Fatalf("expected needs_info, got %s (problems: %+v)", d.Result, d.Problems)
	}
	if len(d.Problems) == 0 || d.Problems[0].Reason != "request_type_unknown" {
		t.Fatalf("expected a request_type_unknown problem, got %+v", d.Problems)
	}
}

func TestCheckerAmbiguousOnInvertedDateRange(t *testing.T) {
	c := NewChecker()
	snap := req("submitted", map[string]string{
		"start_date": "10 июня",
		"end_date":   "1 июня",
	})

	d := c.Check(snap)

	if d.Result != ResultAmbiguous {
		t.Fatalf("expected ambiguous, got %s", d.Result)
	}
	if d.RuleCode != RuleAmbiguous {
		t.Fatalf("expected rule %s, got %s", RuleAmbiguous, d.RuleCode)
	}
}

func TestCheckerAmbiguousOnGrantWithoutNumber(t *testing.T) {
	c := NewChecker()
	snap := req("submitted", map[string]string{"funding_source": "grant"})

	d := c.Check(snap)

	if d.Result != ResultAmbiguous {
		t.Fatalf("expected ambiguous, got %s", d.Result)
	}
}

func TestCheckerConditionalRequirement(t *testing.T) {
	c := NewChecker()
	snap := req("submitted", map[string]string{
		"funding_source": "budget",
	})
	snap.Requirements = []Requirement{
		{
			FieldName: "grant_number",
			Required:  false,
			Condition: "required if funding_source == 'grant'",
		},
	}

	// The condition does not apply: the requirement is satisfied.
	d := c.Check(snap)
	if d.Result != ResultPassed {
		t.Fatalf("expected passed, got %s (%+v)", d.Result, d.Problems)
	}

	// The condition applies: the field is required and missing.
	// The grant without a number is ALSO a contradiction, and a
	// contradiction outranks a missing field — a human must look at it.
	snap.Fields["funding_source"] = "grant"
	d = c.Check(snap)
	if d.Result != ResultAmbiguous {
		t.Fatalf("expected ambiguous, got %s", d.Result)
	}
	// The missing field is still reported as a problem.
	missingReported := false
	for _, p := range d.Problems {
		if p.FieldName == "grant_number" {
			missingReported = true
		}
	}
	if !missingReported {
		t.Fatalf("expected a problem for grant_number, got %+v", d.Problems)
	}
}

func TestCheckerMissingDocument(t *testing.T) {
	c := NewChecker()
	snap := req("submitted", map[string]string{"document_passport": ""})

	d := c.Check(snap)

	if d.Result != ResultNeedsInfo {
		t.Fatalf("expected needs_info, got %s", d.Result)
	}
	found := false
	for _, p := range d.Problems {
		if p.FieldName == "document_passport" && p.Reason == "document_absent" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected a missing-document problem, got %+v", d.Problems)
	}
}

func TestCheckerSkipsNonProcessableStatus(t *testing.T) {
	c := NewChecker()
	snap := req("accepted", map[string]string{})

	d := c.Check(snap)

	if d.Result != ResultSkipped {
		t.Fatalf("expected skipped, got %s", d.Result)
	}
}

func TestDecideRespectsMode(t *testing.T) {
	d := Decision{Result: ResultPassed}

	// manual: the agent proposes, nothing is applied.
	out := Decide(ModeManual, "submitted", d)
	if out.Kind != OutcomeProposed {
		t.Fatalf("manual: expected proposed, got %s", out.Kind)
	}

	// confirm: the same.
	out = Decide(ModeConfirm, "submitted", d)
	if out.Kind != OutcomeProposed {
		t.Fatalf("confirm: expected proposed, got %s", out.Kind)
	}

	// auto: the allowed transition is applied.
	out = Decide(ModeAuto, "submitted", d)
	if out.Kind != OutcomeApplied {
		t.Fatalf("auto: expected applied, got %s", out.Kind)
	}
	if out.Action != AutomaticallyAllowedAction {
		t.Fatalf("auto: expected action %s, got %s", AutomaticallyAllowedAction, out.Action)
	}
}

func TestDecideNeverAppliesOnError(t *testing.T) {
	out := Decide(ModeAuto, "submitted", Decision{Result: ResultError})
	if out.Kind != OutcomeBlocked {
		t.Fatalf("expected blocked on error, got %s", out.Kind)
	}
}

func TestDecideEscalatesAmbiguous(t *testing.T) {
	out := Decide(ModeAuto, "submitted", Decision{Result: ResultAmbiguous})
	if out.Kind != OutcomeBlocked {
		t.Fatalf("expected blocked on ambiguous, got %s", out.Kind)
	}
}

func TestDecideSkipsNonSubmitted(t *testing.T) {
	out := Decide(ModeAuto, "accepted", Decision{Result: ResultPassed})
	if out.Kind != OutcomeNotApplicable {
		t.Fatalf("expected not_applicable, got %s", out.Kind)
	}
}

func TestParseModeFallsBackToConfirm(t *testing.T) {
	if got := ParseMode("nonsense"); got != ModeConfirm {
		t.Fatalf("expected confirm, got %s", got)
	}
	if got := ParseMode("auto"); got != ModeAuto {
		t.Fatalf("expected auto, got %s", got)
	}
}

func TestBackoffIsCapped(t *testing.T) {
	base := time.Second
	max := 30 * time.Second
	if d := Backoff(1, base, max); d != base {
		t.Fatalf("attempt 1: expected %v, got %v", base, d)
	}
	if d := Backoff(2, base, max); d != 2*base {
		t.Fatalf("attempt 2: expected %v, got %v", 2*base, d)
	}
	if d := Backoff(20, base, max); d != max {
		t.Fatalf("attempt 20: expected the cap %v, got %v", max, d)
	}
}

// --- the idempotency guard -----------------------------------------

// stubServer answers with the given status and body.
func stubServer(t *testing.T, status int, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestEventStatusDetectsAlreadyProcessed(t *testing.T) {
	srv := stubServer(t, http.StatusOK, `{"processed":true}`)
	api := NewAPIClient(srv.URL, "token", 0)

	var payload struct {
		Processed bool `json:"processed"`
	}
	err := api.Do(context.Background(), Request{
		Method: "GET",
		Path:   "/api/v1/automation/agent/events/e1/status",
	}, &payload)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !payload.Processed {
		t.Fatal("expected processed=true")
	}
}

func TestAPIClientReportsNotFound(t *testing.T) {
	srv := stubServer(t, http.StatusNotFound, `{"error":"not_found"}`)
	api := NewAPIClient(srv.URL, "token", 0)

	err := api.Do(context.Background(), Request{Method: "GET", Path: "/x"}, nil)
	if err == nil {
		t.Fatal("expected an error")
	}
	var apiErr *APIError
	if !asAPIError(err, &apiErr) {
		t.Fatalf("expected an APIError, got %T", err)
	}
	if !apiErr.IsNotFound() {
		t.Fatal("expected a not-found error")
	}
	if apiErr.Retryable() {
		t.Fatal("a 404 must not be retryable")
	}
}

func TestAPIClientRetriesServerErrors(t *testing.T) {
	srv := stubServer(t, http.StatusServiceUnavailable, `{"error":"down"}`)
	api := NewAPIClient(srv.URL, "token", 0)

	err := api.Do(context.Background(), Request{Method: "GET", Path: "/x"}, nil)
	var apiErr *APIError
	if !asAPIError(err, &apiErr) {
		t.Fatalf("expected an APIError, got %T", err)
	}
	if !apiErr.Retryable() {
		t.Fatal("a 503 must be retryable")
	}
}

// --- the LLM failure path -------------------------------------------

func TestHeuristicAssistantProducesExplanation(t *testing.T) {
	a := NewHeuristicAssistant()
	d := Decision{
		Result: ResultNeedsInfo,
		Reason: "Не заполнены обязательные поля.",
		Problems: []Problem{
			{FieldName: "start_date", Message: "Не заполнено обязательное поле «start_date»."},
		},
	}
	text, err := a.Explain(context.Background(), RequestSnapshot{}, d)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(text, "start_date") {
		t.Fatalf("the explanation must mention the field, got %q", text)
	}
}

func TestHeuristicAssistantDraftsClarification(t *testing.T) {
	a := NewHeuristicAssistant()
	d := Decision{
		Result: ResultNeedsInfo,
		Problems: []Problem{
			{FieldName: "end_date"},
		},
	}
	text, err := a.DraftClarification(context.Background(), RequestSnapshot{}, d)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(text, "end_date") {
		t.Fatalf("the question must name the field, got %q", text)
	}
}

func TestRenderLetterFillsPlaceholders(t *testing.T) {
	template := "Уважаемый заявитель! {{what_decided}}. {{what_next}} Срок: {{deadlines}}."
	card := ResultCard{
		WhatDecided: "Заявка рассмотрена",
		WhatNext:    "Дополнительные действия не требуются.",
		Deadlines:   "01.06.2026",
	}
	out := RenderLetter(template, card, &RequestSnapshot{ID: "r1"})

	for _, want := range []string{"Заявка рассмотрена", "Дополнительные действия не требуются.", "01.06.2026"} {
		if !strings.Contains(out, want) {
			t.Fatalf("the letter must contain %q, got %q", want, out)
		}
	}
	if strings.Contains(out, "{{") {
		t.Fatalf("no placeholder must remain, got %q", out)
	}
}
