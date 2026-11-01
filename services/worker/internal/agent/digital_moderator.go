package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// DigitalModerator is Agent A вЂ” В«Р¦РёС„СЂРѕРІРѕР№ РјРѕРґРµСЂР°С‚РѕСЂВ».
//
// Its job: check a submitted request deterministically and either
//
//   - propose a transition (mode `confirm` / `manual`),
//   - execute the single pre-approved transition (mode `auto`),
//   - draft a clarification request,
//   - or hand the request to a human moderator.
//
// It NEVER writes `requests.status` itself. It asks the Gleam API to apply
// the transition; the API owns the state machine and the audit trail.
type DigitalModerator struct {
	API       *APIClient
	Checker   *Checker
	Assistant Assistant
	// Mode is the automation mode currently in effect. It is refreshed from
	// the API for every request вЂ” the mode is data, not configuration.
	Mode Mode
	// RulesVersion is the version of the rule set that produced the
	// decision. It is stored with every automatic action.
	RulesVersion string
	// Timeout bounds the whole pass over one request.
	Timeout time.Duration
}

// NewDigitalModerator builds the agent.
func NewDigitalModerator(api *APIClient, assistant Assistant, rulesVersion string) *DigitalModerator {
	return &DigitalModerator{
		API:          api,
		Checker:      NewChecker(),
		Assistant:    assistant,
		Mode:         ModeConfirm,
		RulesVersion: rulesVersion,
		Timeout:      60 * time.Second,
	}
}

// RequestEvent is the payload of `requests.created`.
type RequestEvent struct {
	RequestID string `json:"request_id"`
	// EventID is the idempotency key of the delivery. The same event id
	// must never produce two actions.
	EventID string `json:"event_id"`
	// Reason is the source of the event ("request.submitted").
	Reason string `json:"reason"`
	// Status is the status at the moment the event was created. It is only
	// a hint: the agent reloads the request and uses the current status.
	Status string `json:"status"`
}

// Process handles one `requests.created` delivery.
//
// It is the entry point of the consumer. The returned error follows the
// agent error convention: ErrTransient -> NAK with backoff, ErrPermanent ->
// ACK and park the job.
func (a *DigitalModerator) Process(ctx context.Context, ev RequestEvent) (Outcome, error) {
	ctx, cancel := context.WithTimeout(ctx, a.Timeout)
	defer cancel()

	if ev.RequestID == "" {
		return Outcome{}, fmt.Errorf("%w: empty request_id", ErrPermanent)
	}

	// 1. Load the CURRENT state of the request through the API. The event
	// payload may be stale вЂ” the API is the source of truth.
	snap, err := a.loadSnapshot(ctx, ev.RequestID)
	if err != nil {
		return Outcome{}, err
	}

	// An explicit re-run (a moderator asked for it) may examine a request
	// that is already back with the applicant.
	snap.Recheck = IsRecheckEvent(ev.Reason)

	// 2. Idempotency: if this event was already processed, do nothing.
	done, err := a.alreadyProcessed(ctx, ev)
	if err != nil {
		return Outcome{}, err
	}
	if done {
		return Outcome{
			Kind:   OutcomeNotApplicable,
			Reason: "РЎРѕР±С‹С‚РёРµ СѓР¶Рµ РѕР±СЂР°Р±РѕС‚Р°РЅРѕ вЂ” РїРѕРІС‚РѕСЂРЅР°СЏ РѕР±СЂР°Р±РѕС‚РєР° РїСЂРѕРїСѓС‰РµРЅР°.",
		}, nil
	}

	// 3. The mode is data: read it from the API.
	mode, err := a.loadMode(ctx)
	if err != nil {
		return Outcome{}, err
	}
	a.Mode = mode

	// 4. The deterministic check. It runs in EVERY mode вЂ” the `manual` mode
	// means "analyse and propose", not "switched off".
	if !MayRunCheck(mode) {
		return Outcome{Kind: OutcomeNotApplicable, Reason: "РџСЂРѕРІРµСЂРєР° РѕС‚РєР»СЋС‡РµРЅР° СЂРµР¶РёРјРѕРј Р°РІС‚РѕРјР°С‚РёР·Р°С†РёРё."}, nil
	}

	decision := a.Checker.Check(*snap)

	// 5. The LLM may only add an explanation of an ALREADY decided result.
	// A failure here never changes the result.
	a.applyAssistant(ctx, snap, &decision)

	// 6. Decide what may be done with the result.
	outcome := Decide(mode, snap.Status, decision)

	// 7. Persist the check. The API stores it in `agent_checks` and links
	// it to the request.
	if err := a.saveCheck(ctx, ev, snap, &decision, outcome); err != nil {
		return outcome, err
	}

	// 8. Act on the result.
	switch outcome.Kind {
	case OutcomeApplied:
		if err := a.applyTransition(ctx, ev, snap, decision, outcome); err != nil {
			return outcome, err
		}
	case OutcomeProposed:
		if err := a.proposeTransition(ctx, ev, snap, decision, outcome); err != nil {
			return outcome, err
		}
	case OutcomeBlocked:
		if err := a.raiseException(ctx, ev, snap, decision, outcome); err != nil {
			return outcome, err
		}
	case OutcomeNotApplicable:
		// Nothing to do вЂ” but the check is already stored.
	}

	// 9. Draft the clarification request, if one is needed. The draft is
	// NOT sent: a moderator approves the wording.
	if decision.Result == ResultNeedsInfo && decision.ClarificationRequest != "" {
		if err := a.saveDraft(ctx, ev, snap, decision); err != nil {
			return outcome, err
		}
	}

	return outcome, nil
}

// applyAssistant runs the LLM assist.
//
// The LLM may only explain the decision and draft the question. If it
// fails, the deterministic result stands unchanged вЂ” the failure is
// recorded in the check, but the status is not affected.
func (a *DigitalModerator) applyAssistant(ctx context.Context, snap *RequestSnapshot, decision *Decision) {
	if a.Assistant == nil {
		return
	}

	// The assistant is only used where it adds value: an ambiguous case
	// needs an explanation, and a missing-data case needs a question.
	needsAssist := decision.Result == ResultAmbiguous || decision.Result == ResultNeedsInfo
	if !needsAssist {
		return
	}

	decision.LLMUsed = true
	if named, ok := a.Assistant.(interface{ Name() string }); ok {
		decision.ModelVersion = named.Name()
	}

	explanation, err := a.Assistant.Explain(ctx, *snap, *decision)
	if err != nil {
		decision.LLMError = err.Error()
		// The deterministic reason stays in place.
		return
	}
	if strings.TrimSpace(explanation) != "" {
		decision.Reason = explanation
	}

	if decision.Result == ResultNeedsInfo {
		draft, err := a.Assistant.DraftClarification(ctx, *snap, *decision)
		if err != nil {
			decision.LLMError = err.Error()
			return
		}
		if strings.TrimSpace(draft) != "" {
			decision.ClarificationRequest = draft
		}
	}
}

// applyTransition asks the API to perform the transition.
//
// The API re-validates the transition against the state machine and
// rejects it with 409 if it is not allowed. A conflict is NOT an error вЂ”
// it means another actor already moved the request, which is exactly the
// duplicate-processing case.
func (a *DigitalModerator) applyTransition(ctx context.Context, ev RequestEvent, snap *RequestSnapshot, decision Decision, outcome Outcome) error {
	payload := map[string]any{
		"request_id":    snap.ID,
		"action":        outcome.Action,
		"target_status": outcome.ToStatus,
		"from_status":   outcome.FromStatus,
		"reason":        decision.Reason,
		"rule_code":     decision.RuleCode,
		"rules_version": a.RulesVersion,
		"initiator":     "system",
		"source_event":  ev.EventID,
		"event_reason":  ev.Reason,
		"check_id":      decisionCheckID(decision),
		"automation":    true,
	}

	err := a.API.Do(ctx, Request{
		Method: "POST",
		Path:   "/api/v1/automation/agent/requests/" + snap.ID + "/transition",
		Body:   payload,
	}, nil)
	if err == nil {
		return nil
	}

	var apiErr *APIError
	if asAPIError(err, &apiErr) {
		switch {
		case apiErr.IsConflict():
			// Someone else already moved the request вЂ” not an error.
			return nil
		case apiErr.IsNotFound():
			// The check row is missing (a race with a cleanup job).
			return nil
		case apiErr.Retryable():
			return fmt.Errorf("%w: %v", ErrTransient, err)
		}
		return fmt.Errorf("%w: %v", ErrPermanent, err)
	}
	return err
}

// proposeTransition records the proposal for a moderator.
//
// In the `confirm` and `manual` modes the agent prepares the transition
// and the moderator approves it through the API.
func (a *DigitalModerator) proposeTransition(ctx context.Context, ev RequestEvent, snap *RequestSnapshot, decision Decision, outcome Outcome) error {
	payload := map[string]any{
		"request_id":    snap.ID,
		"action":        outcome.Action,
		"target_status": outcome.ToStatus,
		"from_status":   outcome.FromStatus,
		"reason":        decision.Reason,
		"rule_code":     decision.RuleCode,
		"rules_version": a.RulesVersion,
		"initiator":     "system",
		"source_event":  ev.EventID,
		"event_reason":  ev.Reason,
		"check_id":      decisionCheckID(decision),
		"mode":          string(a.Mode),
	}
	err := a.API.Do(ctx, Request{
		Method: "POST",
		Path:   "/api/v1/automation/agent/proposals",
		Body:   payload,
	}, nil)
	if err == nil {
		return nil
	}
	var apiErr *APIError
	if asAPIError(err, &apiErr) {
		if apiErr.Retryable() {
			return fmt.Errorf("%w: %v", ErrTransient, err)
		}
		return fmt.Errorf("%w: %v", ErrPermanent, err)
	}
	return err
}

// raiseException puts the request into the queue of the exceptions that
// need a human decision.
func (a *DigitalModerator) raiseException(ctx context.Context, ev RequestEvent, snap *RequestSnapshot, decision Decision, outcome Outcome) error {
	payload := map[string]any{
		"request_id":    snap.ID,
		"kind":          string(decision.Result),
		"priority":      "normal",
		"summary":       decision.Reason,
		"details":       decision,
		"rule_code":     decision.RuleCode,
		"rules_version": a.RulesVersion,
		"source_event":  ev.EventID,
	}
	err := a.API.Do(ctx, Request{
		Method: "POST",
		Path:   "/api/v1/automation/agent/exceptions",
		Body:   payload,
	}, nil)
	if err == nil {
		return nil
	}
	var apiErr *APIError
	if asAPIError(err, &apiErr) {
		if apiErr.Retryable() {
			return fmt.Errorf("%w: %v", ErrTransient, err)
		}
		return fmt.Errorf("%w: %v", ErrPermanent, err)
	}
	return err
}

// saveDraft stores the draft of the clarification request.
func (a *DigitalModerator) saveDraft(ctx context.Context, ev RequestEvent, snap *RequestSnapshot, decision Decision) error {
	payload := map[string]any{
		"request_id":    snap.ID,
		"kind":          "clarification_request",
		"body":          decision.ClarificationRequest,
		"rule_code":     decision.RuleCode,
		"rules_version": a.RulesVersion,
		"source_event":  ev.EventID,
		"initiator":     "system",
	}
	err := a.API.Do(ctx, Request{
		Method: "POST",
		Path:   "/api/v1/automation/agent/drafts",
		Body:   payload,
	}, nil)
	if err == nil {
		return nil
	}
	var apiErr *APIError
	if asAPIError(err, &apiErr) {
		if apiErr.Retryable() {
			return fmt.Errorf("%w: %v", ErrTransient, err)
		}
		return fmt.Errorf("%w: %v", ErrPermanent, err)
	}
	return err
}

// loadSnapshot loads the current state of the request.
func (a *DigitalModerator) loadSnapshot(ctx context.Context, requestID string) (*RequestSnapshot, error) {
	var snap RequestSnapshot
	err := a.API.Do(ctx, Request{
		Method: "GET",
		Path:   "/api/v1/automation/agent/requests/" + requestID + "/snapshot",
	}, &snap)
	if err != nil {
		var apiErr *APIError
		if asAPIError(err, &apiErr) {
			if apiErr.IsNotFound() {
				return nil, fmt.Errorf("%w: request %s not found", ErrPermanent, requestID)
			}
			if apiErr.Retryable() {
				return nil, fmt.Errorf("%w: %v", ErrTransient, err)
			}
			return nil, fmt.Errorf("%w: %v", ErrPermanent, err)
		}
		return nil, err
	}
	return &snap, nil
}

// loadMode reads the current automation mode.
func (a *DigitalModerator) loadMode(ctx context.Context) (Mode, error) {
	var payload struct {
		Mode string `json:"mode"`
	}
	err := a.API.Do(ctx, Request{
		Method: "GET",
		Path:   "/api/v1/automation/agent/mode",
	}, &payload)
	if err != nil {
		var apiErr *APIError
		if asAPIError(err, &apiErr) {
			if apiErr.Retryable() {
				return a.Mode, fmt.Errorf("%w: %v", ErrTransient, err)
			}
			return a.Mode, fmt.Errorf("%w: %v", ErrPermanent, err)
		}
		return a.Mode, err
	}
	return ParseMode(payload.Mode), nil
}

// alreadyProcessed reports whether the event was already handled.
//
// This is the idempotency guard: with at-least-once delivery the same
// event can arrive twice, and it must not produce two actions.
func (a *DigitalModerator) alreadyProcessed(ctx context.Context, ev RequestEvent) (bool, error) {
	if ev.EventID == "" {
		return false, nil
	}
	var payload struct {
		Processed bool `json:"processed"`
	}
	err := a.API.Do(ctx, Request{
		Method: "GET",
		Path:   "/api/v1/automation/agent/events/" + ev.EventID + "/status",
	}, &payload)
	if err != nil {
		var apiErr *APIError
		if asAPIError(err, &apiErr) {
			if apiErr.IsNotFound() {
				// The event was never seen вЂ” process it.
				return false, nil
			}
			if apiErr.Retryable() {
				return false, fmt.Errorf("%w: %v", ErrTransient, err)
			}
			return false, nil
		}
		return false, err
	}
	return payload.Processed, nil
}

// saveCheck persists the check result through the API.
func (a *DigitalModerator) saveCheck(ctx context.Context, ev RequestEvent, snap *RequestSnapshot, decision *Decision, outcome Outcome) error {
	payload := map[string]any{
		"request_id":    snap.ID,
		"event_id":      ev.EventID,
		"event_reason":  ev.Reason,
		"result":        string(decision.Result),
		"rule_code":     decision.RuleCode,
		"rules_version": a.RulesVersion,
		"mode":          string(a.Mode),
		// The API stores the checks, the problems and the proposals
		// VERBATIM: each item is sent as a JSON string and stored as a
		// JSONB array element. One representation, no drift between the
		// agent and the panel.
		"checks":   marshalItems(decision.Checks),
		"problems": marshalItems(decision.Problems),
		"proposed": marshalItems(decision.ProposedActions),
		"reason":   decision.Reason,
		// The clarification request is part of the check result: it is the
		// concrete list of what the applicant still has to provide. It is
		// built deterministically, so it is present even when the LLM is
		// unreachable.
		"clarification_request": decision.ClarificationRequest,
		"llm_used":              decision.LLMUsed,
		"model_version":         decision.ModelVersion,
		"prompt_version":        decision.PromptVersion,
		"llm_error":             decision.LLMError,
		"duration_ms":           decision.DurationMillis,
		"outcome":               string(outcome.Kind),
	}
	var saved struct {
		ID string `json:"id"`
	}
	err := a.API.Do(ctx, Request{
		Method: "POST",
		Path:   "/api/v1/automation/agent/checks",
		Body:   payload,
	}, &saved)
	if err == nil {
		decision.CheckID = saved.ID
		return nil
	}
	var apiErr *APIError
	if asAPIError(err, &apiErr) {
		if apiErr.Retryable() {
			return fmt.Errorf("%w: %v", ErrTransient, err)
		}
		return fmt.Errorf("%w: %v", ErrPermanent, err)
	}
	return err
}

// marshalItems encodes a list of items as a list of JSON strings.
//
// The API stores them verbatim as JSONB array elements, so the panel shows
// exactly what the agent found — no re-encoding, no field loss.
func marshalItems[T any](items []T) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		raw, err := json.Marshal(item)
		if err != nil {
			continue
		}
		out = append(out, string(raw))
	}
	return out
}

// decisionCheckID returns the id of the check that was just stored.
//
// The API answers the POST /checks call with the id of the created row;
// the agent keeps it so the follow-up calls can reference it. When the
// answer carried no id, an empty string is used and the API resolves the
// check by the request id and the event id.
func decisionCheckID(d Decision) string {
	return d.CheckID
}

// asAPIError is a small helper for the type assertion.
func asAPIError(err error, target **APIError) bool {
	if e, ok := err.(*APIError); ok {
		*target = e
		return true
	}
	return false
}
