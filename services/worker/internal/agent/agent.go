// Package agent implements the Phase-8 AI agents of «Эффективность 360».
//
// The package contains TWO agents:
//
//   - Agent A "Цифровой модератор" (digital_moderator.go): checks a
//     submitted request deterministically and, when allowed, proposes or
//     performs a status transition.
//
//   - Agent B "Агент сопровождения заявителя" (applicant_support.go):
//     watches status and deadline changes, notifies the applicant, prepares
//     a draft of the official letter and a result card.
//
// THE GOLDEN RULE OF THE MODERATION DOMAIN:
//
//	Gleam is the source of truth for statuses, access rights and business
//	rules. The agents NEVER write `requests.status` directly and NEVER
//	invent a legal basis. They prepare a DECISION; the Gleam domain
//	service applies it.
//
// The agents talk to the Gleam API over HTTP (the "repository/API" the
// task description mentions) instead of writing to PostgreSQL directly.
// That keeps a single writer for the business tables and lets the Gleam
// layer enforce the state machine, the RBAC and the audit trail.
//
// WHAT THE LLM IS ALLOWED TO DO:
//
//	classification, explanation of errors, drafting clarifying questions.
//
// WHAT THE LLM IS NEVER ALLOWED TO DO:
//
//	decide a legally significant matter, change a status, invent a legal
//	basis. The deterministic check decides the outcome; the LLM only adds
//	an explanation on top of a DECIDED outcome. An LLM failure therefore
//	can never change the status of a request — it only degrades the
//	explanation (see Agent A).
package agent

import (
	"errors"
	"time"
)

// The sentinel errors of the agent layer.
//
// The consumer maps them onto the ACK/NAK policy:
//
//	ErrTransient  -> NAK with delay (retry, bounded by MaxAttempts)
//	ErrPermanent  -> ACK + park in job_runs as failed
//	manual_review -> ACK + park in job_runs as manual_review
var (
	// ErrTransient marks a failure that may succeed on retry.
	ErrTransient = errors.New("agent: transient failure")
	// ErrPermanent marks a failure that must not be retried.
	ErrPermanent = errors.New("agent: permanent failure")
	// ErrManualReview marks a payload that a human must look at.
	ErrManualReview = errors.New("agent: manual review required")
)

// Mode is the automation mode. It mirrors the `automation_settings.mode`
// CHECK constraint in PostgreSQL and the `AutomationMode` type in
// `automation.gleam`.
type Mode string

const (
	// ModeManual: agents analyse and propose, they never change statuses.
	ModeManual Mode = "manual"
	// ModeConfirm: the agent prepares a transition, a moderator approves.
	// This is the default.
	ModeConfirm Mode = "confirm"
	// ModeAuto: the system executes only the pre-approved, reversible and
	// legally inconsequential transitions on its own.
	ModeAuto Mode = "auto"
)

// ParseMode maps a database string to a Mode. An unknown value falls back
// to the safe default (ModeConfirm) — the service must never run in an
// undefined mode.
func ParseMode(s string) Mode {
	switch Mode(s) {
	case ModeManual:
		return ModeManual
	case ModeAuto:
		return ModeAuto
	default:
		return ModeConfirm
	}
}

// Valid reports whether the mode is one of the three known modes.
func (m Mode) Valid() bool {
	switch m {
	case ModeManual, ModeConfirm, ModeAuto:
		return true
	default:
		return false
	}
}

// CheckResult is the outcome of the deterministic check.
type CheckResult string

const (
	// ResultPassed: the request satisfies every requirement.
	ResultPassed CheckResult = "passed"
	// ResultNeedsInfo: required data is missing; a clarification request
	// is prepared for the applicant.
	ResultNeedsInfo CheckResult = "needs_info"
	// ResultAmbiguous: a contradiction or an uncertainty was found; a human
	// must decide.
	ResultAmbiguous CheckResult = "ambiguous"
	// ResultError: the check could not be completed (e.g. the LLM was
	// unavailable). The status is NOT changed.
	ResultError CheckResult = "error"
	// ResultSkipped: automation did not apply (mode or status).
	ResultSkipped CheckResult = "skipped"
)

// Rule codes are stored in `agent_checks.rule_code` and
// `automation_actions.rule_code`, so they are part of the audit contract.
const (
	RuleComplete      = "complete"
	RuleMissingFields = "missing_fields"
	RuleAmbiguous     = "ambiguous"
	RuleLlmFailure    = "llm_failure"
	RuleModeBlocked   = "mode_blocked"
)

// RuleForResult maps a check result to its rule code.
func RuleForResult(r CheckResult) string {
	switch r {
	case ResultPassed:
		return RuleComplete
	case ResultNeedsInfo:
		return RuleMissingFields
	case ResultAmbiguous:
		return RuleAmbiguous
	case ResultError:
		return RuleLlmFailure
	default:
		return RuleModeBlocked
	}
}

// Problem is one issue found by the check.
type Problem struct {
	FieldName string `json:"field_name"`
	Reason    string `json:"reason"`
	Message   string `json:"message"`
	ClauseID  string `json:"clause_id"`
	Quote     string `json:"quote"`
}

// CheckItem is one named check the agent performed.
type CheckItem struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

// ProposedAction is an action the agent proposes for a moderator.
type ProposedAction struct {
	Action       string `json:"action"`
	TargetStatus string `json:"target_status"`
	Reason       string `json:"reason"`
	RuleCode     string `json:"rule_code"`
}

// Decision is the full result of the agent's pass over a request.
type Decision struct {
	Result               CheckResult      `json:"result"`
	Checks               []CheckItem      `json:"checks"`
	Problems             []Problem        `json:"problems"`
	ProposedActions      []ProposedAction `json:"proposed_actions"`
	ClarificationRequest string           `json:"clarification_request"`
	Reason               string           `json:"reason"`
	RuleCode             string           `json:"rule_code"`

	// The LLM only ever ADDS an explanation. When the LLM fails, the
	// deterministic result stands and only the explanation degrades.
	LLMUsed        bool   `json:"llm_used"`
	ModelVersion   string `json:"model_version"`
	PromptVersion  string `json:"prompt_version"`
	LLMError       string `json:"llm_error,omitempty"`
	DurationMillis int64  `json:"duration_ms"`

	// CheckID is the id of the stored check. It is filled in by the API
	// when the check is saved, so the follow-up calls (transition, propose)
	// can reference it.
	CheckID string `json:"check_id,omitempty"`
}

// AutomaticallyAllowedAction is the single transition the agent may execute
// on its own in the `auto` mode.
//
// `accept` (submitted -> accepted) is reversible (a moderator can return
// the request to `returned`), has no legal consequences (the request has
// not been considered yet) and needs no signature.
//
// `request_clarification` is deliberately NOT here: the wording of a
// question to the applicant is a human decision — the agent only DRAFTS
// the question.
const AutomaticallyAllowedAction = "accept"

// MayExecuteAutomatically reports whether the action may be executed
// automatically in the given mode.
//
// Only the `auto` mode allows anything at all. In `manual` and `confirm`
// the agent prepares a proposal and a human applies it.
func MayExecuteAutomatically(mode Mode, action string) bool {
	if mode != ModeAuto {
		return false
	}
	return action == AutomaticallyAllowedAction
}

// MayRunCheck reports whether the agent may run its check in this mode.
//
// The check runs in EVERY mode: the `manual` mode means "the agents analyse
// and propose", not "the agents are switched off".
func MayRunCheck(mode Mode) bool { return true }

// MayPrepareDrafts reports whether the agent may prepare drafts and send
// notifications in this mode. Preparing a draft never changes the legal
// status of a request, so it is allowed in every mode.
func MayPrepareDrafts(mode Mode) bool { return true }

// ProcessableStatuses lists the statuses the digital moderator processes.
//
// Only `submitted` is processed. Any other status means the request was
// already handled — this is what stops duplicate processing on redelivery
// and rules out infinite event loops.
var ProcessableStatuses = []string{"submitted"}

// RecheckStatuses lists the statuses an EXPLICIT re-run may examine.
//
// A moderator can ask for a re-check of a request that is already back
// with the applicant (`returned`): the applicant answered, the fields were
// filled in, and the check has to be repeated on the current data. This is
// a deliberate, human-initiated action — it never happens on the ordinary
// submit flow, so the anti-loop guarantee still holds.
var RecheckStatuses = []string{"submitted", "returned"}

// IsProcessableStatus reports whether the status may be processed.
func IsProcessableStatus(status string) bool {
	for _, s := range ProcessableStatuses {
		if s == status {
			return true
		}
	}
	return false
}

// IsRecheckStatus reports whether an explicit re-run may examine the status.
func IsRecheckStatus(status string) bool {
	for _, s := range RecheckStatuses {
		if s == status {
			return true
		}
	}
	return false
}

// IsRecheckEvent reports whether the event asks for an explicit re-run.
//
// The marker is set by the API when a moderator asks for a re-check.
func IsRecheckEvent(reason string) bool {
	return reason == RecheckReason
}

// RecheckReason is the event reason of an explicit re-run.
const RecheckReason = "requests.recheck"

// Decide decides what the agent may do with a request that passed the
// check.
//
// This is the Go mirror of `automation.gleam::decide`. The Gleam API
// remains the authority — the agent's decision is only a proposal, and the
// API re-checks everything. The duplication is deliberate: the worker must
// be able to decide without a round trip to the API on the hot path, and
// the API's own check is the final word.
//
// `recheck` widens only the set of STATUSES that may be examined (an
// explicit moderator re-run may look at a request that is back with the
// applicant). It never widens the set of ACTIONS: the transition itself is
// still validated by the API against the state machine.
func Decide(mode Mode, currentStatus string, d Decision) Outcome {
	// 1. A failed or skipped check never changes the status.
	switch d.Result {
	case ResultError, ResultSkipped:
		return Outcome{
			Kind:   OutcomeBlocked,
			Reason: "Проверка не дала положительного результата — статус не изменён.",
		}
	}

	// 2. Only `submitted` is processed by the digital moderator.
	if !IsProcessableStatus(currentStatus) {
		return Outcome{
			Kind:   OutcomeNotApplicable,
			Reason: "Заявка не в статусе «Отправлена» — повторная обработка не выполняется.",
		}
	}

	switch d.Result {
	case ResultPassed:
		if MayExecuteAutomatically(mode, AutomaticallyAllowedAction) {
			return Outcome{
				Kind:       OutcomeApplied,
				Action:     AutomaticallyAllowedAction,
				FromStatus: currentStatus,
				ToStatus:   "accepted",
			}
		}
		return Outcome{
			Kind:       OutcomeProposed,
			Action:     AutomaticallyAllowedAction,
			FromStatus: currentStatus,
			ToStatus:   "accepted",
		}
	case ResultNeedsInfo:
		// The agent DRAFTS the clarification; a moderator applies the
		// transition, because the applicant must receive a wording a
		// person has seen.
		return Outcome{
			Kind:       OutcomeProposed,
			Action:     "request_clarification",
			FromStatus: currentStatus,
			ToStatus:   "returned",
		}
	case ResultAmbiguous:
		return Outcome{
			Kind:   OutcomeBlocked,
			Reason: "Обнаружена неопределённость — заявка передана человеку-модераторu.",
		}
	}
	return Outcome{
		Kind:   OutcomeBlocked,
		Reason: "Результат проверки не распознан.",
	}
}

// OutcomeKind classifies the result of Decide.
type OutcomeKind string

const (
	// OutcomeApplied: the transition was executed automatically.
	OutcomeApplied OutcomeKind = "applied"
	// OutcomeProposed: the transition is prepared, a human must approve it.
	OutcomeProposed OutcomeKind = "proposed"
	// OutcomeBlocked: the agent must not act; a human may be needed.
	OutcomeBlocked OutcomeKind = "blocked"
	// OutcomeNotApplicable: the request is not in a processable state.
	OutcomeNotApplicable OutcomeKind = "not_applicable"
)

// Outcome is the decision of the agent about a request.
type Outcome struct {
	Kind       OutcomeKind
	Action     string
	FromStatus string
	ToStatus   string
	Reason     string
}

// Backoff returns the delay before the Nth retry of a transient failure.
//
// The delay grows exponentially and is capped, so a failing provider does
// not get hammered and the queue is not blocked for long.
func Backoff(attempt int, base time.Duration, max time.Duration) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	delay := base
	for i := 1; i < attempt; i++ {
		delay *= 2
		if delay >= max {
			return max
		}
	}
	if delay > max {
		return max
	}
	return delay
}
