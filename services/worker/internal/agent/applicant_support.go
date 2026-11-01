package agent

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// ApplicantSupport is Agent B вЂ” В«РђРіРµРЅС‚ СЃРѕРїСЂРѕРІРѕР¶РґРµРЅРёСЏ Р·Р°СЏРІРёС‚РµР»СЏВ».
//
// It watches status and deadline changes and:
//   - creates a notification in the applicant's personal cabinet,
//   - explains what happened and what is needed next,
//   - tracks the waiting deadlines,
//   - creates a reminder for the moderator when a deadline is at risk,
//   - prepares a DRAFT of the official letter (never signed, never sent),
//   - prepares the result card В«Р§С‚Рѕ СЂРµС€РµРЅРѕ / РџРѕС‡РµРјСѓ / Р§С‚Рѕ РґР°Р»СЊС€Рµ / РЎСЂРѕРєРёВ»,
//   - asks for feedback and records it in the metrics.
//
// It never changes a status and never sends an official answer: the
// official letter is approved by an authorised person.
type ApplicantSupport struct {
	API *APIClient
	// LetterTemplate is the approved template of the official letter.
	LetterTemplate string
	// DeadlineWarnHours is the threshold at which a reminder is created.
	DeadlineWarnHours int
	// Timeout bounds one pass.
	Timeout time.Duration
}

// NewApplicantSupport builds the agent.
func NewApplicantSupport(api *APIClient, letterTemplate string, deadlineWarnHours int) *ApplicantSupport {
	if deadlineWarnHours <= 0 {
		deadlineWarnHours = 24
	}
	return &ApplicantSupport{
		API:               api,
		LetterTemplate:    letterTemplate,
		DeadlineWarnHours: deadlineWarnHours,
		Timeout:           60 * time.Second,
	}
}

// StatusEvent is the payload of `requests.status_changed`.
type StatusEvent struct {
	RequestID    string `json:"request_id"`
	EventID      string `json:"event_id"`
	Reason       string `json:"reason"`
	FromStatus   string `json:"from_status"`
	ToStatus     string `json:"to_status"`
	DecisionID   string `json:"decision_id"`
	Initiation   string `json:"initiator"`
	Comment      string `json:"comment"`
	NextDeadline string `json:"next_deadline"`
}

// Process handles one status-change delivery.
//
// The notifications are idempotent: the API stores the idempotency key of
// the notification, so a redelivered event cannot notify the applicant
// twice.
func (a *ApplicantSupport) Process(ctx context.Context, ev StatusEvent) (Outcome, error) {
	ctx, cancel := context.WithTimeout(ctx, a.Timeout)
	defer cancel()

	if ev.RequestID == "" {
		return Outcome{}, fmt.Errorf("%w: empty request_id", ErrPermanent)
	}

	// Idempotency guard: the event must not be processed twice.
	done, err := a.alreadyProcessed(ctx, ev)
	if err != nil {
		return Outcome{}, err
	}
	if done {
		return Outcome{
			Kind:   OutcomeNotApplicable,
			Reason: "РЎРѕР±С‹С‚РёРµ СѓР¶Рµ РѕР±СЂР°Р±РѕС‚Р°РЅРѕ вЂ” РїРѕРІС‚РѕСЂРЅРѕРµ СѓРІРµРґРѕРјР»РµРЅРёРµ РЅРµ СЃРѕР·РґР°РЅРѕ.",
		}, nil
	}

	snap, err := a.loadSnapshot(ctx, ev.RequestID)
	if err != nil {
		return Outcome{}, err
	}

	// 1. The notification in the applicant's cabinet.
	notification := a.buildNotification(*snap, ev)
	if err := a.createNotification(ctx, ev, notification); err != nil {
		return Outcome{}, err
	}

	// 2. The result card В«Р§С‚Рѕ СЂРµС€РµРЅРѕ / РџРѕС‡РµРјСѓ / Р§С‚Рѕ РґР°Р»СЊС€Рµ / РЎСЂРѕРєРёВ».
	card := a.buildResultCard(*snap, ev)
	if err := a.createResultCard(ctx, ev, card); err != nil {
		return Outcome{}, err
	}

	// 3. The draft of the official letter вЂ” a DRAFT, not a sent answer.
	if a.LetterTemplate != "" {
		if err := a.prepareLetterDraft(ctx, ev, snap, card); err != nil {
			return Outcome{}, err
		}
	}

	// 4. The deadline watch.
	if err := a.watchDeadline(ctx, ev, snap); err != nil {
		return Outcome{}, err
	}

	// 5. The feedback request вЂ” only for a finished request.
	if isFinalStatus(ev.ToStatus) {
		if err := a.requestFeedback(ctx, ev, snap); err != nil {
			return Outcome{}, err
		}
	}

	return Outcome{
		Kind:   OutcomeApplied,
		Action: "applicant_notified",
		Reason: "Р—Р°СЏРІРёС‚РµР»СЊ СѓРІРµРґРѕРјР»С‘РЅ, РїРѕРґРіРѕС‚РѕРІР»РµРЅС‹ РєР°СЂС‚РѕС‡РєР° СЂРµР·СѓР»СЊС‚Р°С‚Р° Рё РїСЂРѕРµРєС‚ РѕС‚РІРµС‚Р°.",
	}, nil
}

// Notification is one entry of the applicant's bell.
type Notification struct {
	Kind    string `json:"kind"`
	Title   string `json:"title"`
	Body    string `json:"body"`
	Level   string `json:"level"`
	Request string `json:"request_id"`
}

// ResultCard is the В«Р§С‚Рѕ СЂРµС€РµРЅРѕ / РџРѕС‡РµРјСѓ / Р§С‚Рѕ РґР°Р»СЊС€Рµ / РЎСЂРѕРєРёВ» card.
type ResultCard struct {
	WhatDecided  string `json:"what_decided"`
	Why          string `json:"why"`
	WhatNext     string `json:"what_next"`
	Deadlines    string `json:"deadlines"`
	RequestID    string `json:"request_id"`
	EventID      string `json:"event_id"`
	FromStatus   string `json:"from_status"`
	ToStatus     string `json:"to_status"`
	Initiation   string `json:"initiator"`
	NeedFeedback bool   `json:"need_feedback"`
}

// buildNotification builds the notification text.
func (a *ApplicantSupport) buildNotification(snap RequestSnapshot, ev StatusEvent) Notification {
	title, body := DescribeStatusChange(ev.FromStatus, ev.ToStatus, ev.Reason, ev.Comment)
	return Notification{
		Kind:    "status_change",
		Title:   title,
		Body:    body,
		Level:   notificationLevel(ev.ToStatus),
		Request: snap.ID,
	}
}

// buildResultCard builds the result card.
func (a *ApplicantSupport) buildResultCard(snap RequestSnapshot, ev StatusEvent) ResultCard {
	card := ResultCard{
		RequestID:  snap.ID,
		EventID:    ev.EventID,
		FromStatus: ev.FromStatus,
		ToStatus:   ev.ToStatus,
		Initiation: ev.Initiation,
	}
	card.WhatDecided = DescribeStatusTitle(ev.ToStatus)
	card.Why = describeReason(ev.Reason, ev.Comment)
	card.WhatNext = DescribeNextStep(ev.ToStatus)
	if ev.NextDeadline != "" {
		card.Deadlines = "РЎР»РµРґСѓСЋС‰РёР№ СЃСЂРѕРє: " + ev.NextDeadline
	} else {
		card.Deadlines = "РЎР»РµРґСѓСЋС‰РёР№ СЃСЂРѕРє РЅРµ РЅР°Р·РЅР°С‡РµРЅ."
	}
	card.NeedFeedback = isFinalStatus(ev.ToStatus)
	return card
}

// describeReason explains why the status changed.
func describeReason(reason, comment string) string {
	if comment != "" {
		return comment
	}
	if reason != "" {
		return reason
	}
	return "РЎС‚Р°С‚СѓСЃ Р·Р°СЏРІРєРё РёР·РјРµРЅС‘РЅ."
}

// prepareLetterDraft prepares the DRAFT of the official letter.
//
// The letter is built from the approved template. It is stored as a draft
// and is NOT sent: the official answer is approved and signed by an
// authorised person.
func (a *ApplicantSupport) prepareLetterDraft(ctx context.Context, ev StatusEvent, snap *RequestSnapshot, card ResultCard) error {
	body := RenderLetter(a.LetterTemplate, card, snap)
	payload := map[string]any{
		"request_id":   snap.ID,
		"kind":         "official_letter",
		"body":         body,
		"rule_code":    "agent_b_letter",
		"source_event": ev.EventID,
		"initiator":    "system",
		"status":       "draft",
		"decision_id":  ev.DecisionID,
	}
	return a.post(ctx, "/api/v1/automation/agent/drafts", payload)
}

// watchDeadline watches the waiting deadline.
//
// When the deadline is close it creates a task for the moderator. The task
// is idempotent: the API deduplicates by (request_id, kind).
func (a *ApplicantSupport) watchDeadline(ctx context.Context, ev StatusEvent, snap *RequestSnapshot) error {
	if ev.NextDeadline == "" {
		return nil
	}
	remaining, ok := timeUntil(ev.NextDeadline)
	if !ok {
		return nil
	}
	if remaining > time.Duration(a.DeadlineWarnHours)*time.Hour {
		return nil
	}
	payload := map[string]any{
		"request_id":   snap.ID,
		"kind":         "deadline_risk",
		"priority":     "high",
		"title":        fmt.Sprintf("Р РёСЃРє РїСЂРѕСЃСЂРѕС‡РєРё РїРѕ Р·Р°СЏРІРєРµ %s", snap.ID),
		"due_at":       ev.NextDeadline,
		"source_event": ev.EventID,
		"initiator":    "system",
	}
	return a.post(ctx, "/api/v1/automation/agent/tasks", payload)
}

// requestFeedback asks the applicant for feedback and records it in the
// metrics.
func (a *ApplicantSupport) requestFeedback(ctx context.Context, ev StatusEvent, snap *RequestSnapshot) error {
	payload := map[string]any{
		"request_id":  snap.ID,
		"kind":        "feedback_request",
		"event_id":    ev.EventID,
		"initiator":   "system",
		"metrics_key": "feedback_requested",
	}
	return a.post(ctx, "/api/v1/automation/agent/metrics", payload)
}

// createNotification creates the notification in the cabinet.
//
// The idempotency key is built from the event id and the kind, so the same
// event can never create two notifications.
func (a *ApplicantSupport) createNotification(ctx context.Context, ev StatusEvent, n Notification) error {
	payload := map[string]any{
		"request_id":      n.Request,
		"kind":            n.Kind,
		"title":           n.Title,
		"body":            n.Body,
		"level":           n.Level,
		"event_id":        ev.EventID,
		"idempotency_key": "notification:" + ev.EventID + ":" + n.Kind,
	}
	return a.post(ctx, "/api/v1/automation/agent/notifications", payload)
}

// createResultCard stores the result card.
//
// The endpoint is the same as for the bell notification: the API stores the
// title/body/level fields and ignores the extra ones. We send a generic
// title and body so the API decoder is satisfied.
func (a *ApplicantSupport) createResultCard(ctx context.Context, ev StatusEvent, card ResultCard) error {
	payload := map[string]any{
		"request_id":      card.RequestID,
		"kind":            "result_card",
		"title":           card.WhatDecided,
		"body":            a.cardBody(card),
		"level":           "info",
		"event_id":        card.EventID,
		"idempotency_key": "result_card:" + card.EventID,
	}
	return a.post(ctx, "/api/v1/automation/agent/notifications", payload)
}

// cardBody renders the result card as a single text block for the bell.
func (a *ApplicantSupport) cardBody(card ResultCard) string {
	return card.WhatDecided + " — " + card.WhatNext + " (" + card.Deadlines + ")"
}

// alreadyProcessed reports whether the event was already handled.
func (a *ApplicantSupport) alreadyProcessed(ctx context.Context, ev StatusEvent) (bool, error) {
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

// loadSnapshot loads the current state of the request.
func (a *ApplicantSupport) loadSnapshot(ctx context.Context, requestID string) (*RequestSnapshot, error) {
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

// post performs a POST request and maps the error onto the agent
// convention.
func (a *ApplicantSupport) post(ctx context.Context, path string, payload map[string]any) error {
	err := a.API.Do(ctx, Request{Method: "POST", Path: path, Body: payload}, nil)
	if err == nil {
		return nil
	}
	var apiErr *APIError
	if asAPIError(err, &apiErr) {
		if apiErr.Retryable() {
			return fmt.Errorf("%w: %v", ErrTransient, err)
		}
		// A duplicate (409) means the notification already exists вЂ” that is
		// the idempotency working, not a failure.
		if apiErr.IsConflict() {
			return nil
		}
		return fmt.Errorf("%w: %v", ErrPermanent, err)
	}
	return err
}

// RenderLetter fills the approved template of the official letter.
//
// The placeholders are replaced with the values of the result card. An
// unknown placeholder is left as is вЂ” the template is approved by a
// human, so the agent must not silently drop a part of it.
func RenderLetter(template string, card ResultCard, snap *RequestSnapshot) string {
	replacements := map[string]string{
		"{{what_decided}}": card.WhatDecided,
		"{{why}}":          card.Why,
		"{{what_next}}":    card.WhatNext,
		"{{deadlines}}":    card.Deadlines,
		"{{request_id}}":   snap.ID,
		"{{status}}":       card.ToStatus,
	}
	out := template
	for key, value := range replacements {
		out = strings.ReplaceAll(out, key, value)
	}
	return out
}

// timeUntil parses a deadline and returns the remaining time.
func timeUntil(deadline string) (time.Duration, bool) {
	layouts := []string{time.RFC3339, "2006-01-02T15:04:05", "2006-01-02 15:04:05", "2006-01-02"}
	for _, layout := range layouts {
		if t, err := time.Parse(layout, strings.TrimSpace(deadline)); err == nil {
			return time.Until(t), true
		}
	}
	return 0, false
}

// notificationLevel maps a status to the severity of the notification.
func notificationLevel(status string) string {
	switch status {
	case "returned":
		return "action_required"
	case "accepted", "in_review":
		return "info"
	case "completed", "decided":
		return "done"
	case "rejected":
		return "warning"
	default:
		return "info"
	}
}

// isFinalStatus reports whether the status is a final one.
func isFinalStatus(status string) bool {
	switch status {
	case "completed", "decided", "rejected":
		return true
	}
	return false
}

// DescribeStatusChange builds the title and the body of the notification.
//
// The texts are deterministic: they are built from the actual status
// change, not generated.
func DescribeStatusChange(from, to, reason, comment string) (string, string) {
	title := "Р—Р°СЏРІРєР°: " + DescribeStatusTitle(to)
	body := DescribeNextStep(to)
	if comment != "" {
		body += " " + comment
	} else if reason != "" && reason != "status_changed" {
		body += " (" + reason + ")"
	}
	return title, body
}

// DescribeStatusTitle returns the human-readable name of a status.
func DescribeStatusTitle(status string) string {
	switch status {
	case "submitted":
		return "РћС‚РїСЂР°РІР»РµРЅР°"
	case "accepted":
		return "РџСЂРѕРІРµСЂРµРЅР°"
	case "in_review":
		return "РќР° СЂР°СЃСЃРјРѕС‚СЂРµРЅРёРё"
	case "returned":
		return "Р’РѕР·РІСЂР°С‰РµРЅР° РЅР° СѓС‚РѕС‡РЅРµРЅРёРµ"
	case "completed", "decided":
		return "Р Р°СЃСЃРјРѕС‚СЂРµРЅР°"
	case "rejected":
		return "РћС‚РєР°Р·Р°РЅРѕ"
	case "cancelled":
		return "РћС‚РјРµРЅРµРЅР°"
	default:
		return status
	}
}

// DescribeNextStep explains what the applicant has to do next.
func DescribeNextStep(status string) string {
	switch status {
	case "submitted":
		return "Р—Р°СЏРІРєР° РїСЂРёРЅСЏС‚Р° РІ СЂР°Р±РѕС‚Сѓ. РџСЂРѕРІРµСЂРєР° РІС‹РїРѕР»РЅСЏРµС‚СЃСЏ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё."
	case "accepted":
		return "Р—Р°СЏРІРєР° РїСЂРѕРІРµСЂРµРЅР° Рё РѕР¶РёРґР°РµС‚ СЂР°СЃСЃРјРѕС‚СЂРµРЅРёСЏ. Р”РѕРїРѕР»РЅРёС‚РµР»СЊРЅС‹Рµ РґРµР№СЃС‚РІРёСЏ РѕС‚ РІР°СЃ РЅРµ С‚СЂРµР±СѓСЋС‚СЃСЏ."
	case "in_review":
		return "Р—Р°СЏРІРєР° СЂР°СЃСЃРјР°С‚СЂРёРІР°РµС‚СЃСЏ. РњС‹ СЃРѕРѕР±С‰РёРј Рѕ СЂРµР·СѓР»СЊС‚Р°С‚Рµ."
	case "returned":
		return "Р—Р°СЏРІРєР° РІРѕР·РІСЂР°С‰РµРЅР° РЅР° СѓС‚РѕС‡РЅРµРЅРёРµ. РџРѕР¶Р°Р»СѓР№СЃС‚Р°, СѓРєР°Р¶РёС‚Рµ РЅРµРґРѕСЃС‚Р°СЋС‰РёРµ СЃРІРµРґРµРЅРёСЏ."
	case "completed", "decided":
		return "Р—Р°СЏРІРєР° СЂР°СЃСЃРјРѕС‚СЂРµРЅР°. РћР·РЅР°РєРѕРјСЊС‚РµСЃСЊ СЃ СЂРµР·СѓР»СЊС‚Р°С‚РѕРј Рё РѕС†РµРЅРёС‚Рµ СЂР°Р±РѕС‚Сѓ."
	case "rejected":
		return "РџРѕ Р·Р°СЏРІРєРµ РїСЂРёРЅСЏС‚Рѕ СЂРµС€РµРЅРёРµ РѕР± РѕС‚РєР°Р·Рµ. РџСЂРёС‡РёРЅР° СѓРєР°Р·Р°РЅР° РІ СЂРµР·СѓР»СЊС‚Р°С‚Рµ."
	case "cancelled":
		return "Р—Р°СЏРІРєР° РѕС‚РјРµРЅРµРЅР°."
	default:
		return "РЎР»РµРґРёС‚Рµ Р·Р° СЃС‚Р°С‚СѓСЃРѕРј Р·Р°СЏРІРєРё РІ Р»РёС‡РЅРѕРј РєР°Р±РёРЅРµС‚Рµ."
	}
}
