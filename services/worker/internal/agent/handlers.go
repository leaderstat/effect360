package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"effectivnost360/worker/internal/jobhandler"
)

// JobTypeDigitalModerator is the job type of Agent A.
const JobTypeDigitalModerator = "agent_digital_moderator"

// JobTypeApplicantSupport is the job type of Agent B.
const JobTypeApplicantSupport = "agent_applicant_support"

// DigitalModeratorHandler adapts the digital moderator to the consumer's
// Handler contract.
//
// The handler is a thin adapter: the business logic lives in the agent, and
// the consumer owns the ACK/NAK policy and the persistence of job_runs.
type DigitalModeratorHandler struct {
	Agent *DigitalModerator
	// Timeout bounds one invocation.
	Timeout time.Duration
}

// NewDigitalModeratorHandler builds the handler.
func NewDigitalModeratorHandler(a *DigitalModerator) *DigitalModeratorHandler {
	return &DigitalModeratorHandler{Agent: a, Timeout: 2 * time.Minute}
}

// Handle implements jobhandler.Handler.
func (h *DigitalModeratorHandler) Handle(ev jobhandler.Event) jobhandler.Outcome {
	return h.HandleWithContext(context.Background(), ev)
}

// HandleWithContext lets the caller pass a deadline.
func (h *DigitalModeratorHandler) HandleWithContext(ctx context.Context, ev jobhandler.Event) jobhandler.Outcome {
	ctx, cancel := context.WithTimeout(ctx, h.Timeout)
	defer cancel()

	event, err := decodeRequestEvent(ev)
	if err != nil {
		return jobhandler.Outcome{
			Status: "manual_review",
			Err:    ErrPermanent,
			Detail: map[string]any{"reason": err.Error()},
		}
	}

	outcome, err := h.Agent.Process(ctx, event)
	detail := map[string]any{
		"agent":   "digital_moderator",
		"outcome": string(outcome.Kind),
		"action":  outcome.Action,
		"reason":  outcome.Reason,
	}
	if outcome.FromStatus != "" {
		detail["from_status"] = outcome.FromStatus
	}
	if outcome.ToStatus != "" {
		detail["to_status"] = outcome.ToStatus
	}
	if err != nil {
		// The error text goes into the job_runs detail (no personal data:
		// the agent errors carry status codes and field names only).
		detail["error"] = err.Error()
	}

	if err != nil {
		switch {
		case errors.Is(err, ErrTransient):
			// NAK with delay — the consumer retries with a bounded backoff.
			return jobhandler.Outcome{
				Status: "running",
				Err:    jobhandler.ErrTransient,
				Detail: detail,
			}
		case errors.Is(err, ErrPermanent):
			// ACK + park: retrying will not help.
			return jobhandler.Outcome{
				Status: "failed",
				Err:    jobhandler.ErrPermanent,
				Detail: detail,
			}
		default:
			return jobhandler.Outcome{
				Status: "running",
				Err:    jobhandler.ErrTransient,
				Detail: detail,
			}
		}
	}

	switch outcome.Kind {
	case OutcomeBlocked:
		// The request needs a human. The job itself succeeded: the agent
		// did its work and escalated.
		detail["escalated"] = true
		return jobhandler.Outcome{Status: "succeeded", Detail: detail}
	case OutcomeNotApplicable:
		detail["skipped"] = true
		return jobhandler.Outcome{Status: "succeeded", Detail: detail}
	default:
		return jobhandler.Outcome{Status: "succeeded", Detail: detail}
	}
}

// ApplicantSupportHandler adapts the applicant-support agent to the
// consumer's Handler contract.
type ApplicantSupportHandler struct {
	Agent *ApplicantSupport
	// Timeout bounds one invocation.
	Timeout time.Duration
}

// NewApplicantSupportHandler builds the handler.
func NewApplicantSupportHandler(a *ApplicantSupport) *ApplicantSupportHandler {
	return &ApplicantSupportHandler{Agent: a, Timeout: 2 * time.Minute}
}

// Handle implements jobhandler.Handler.
func (h *ApplicantSupportHandler) Handle(ev jobhandler.Event) jobhandler.Outcome {
	return h.HandleWithContext(context.Background(), ev)
}

// HandleWithContext lets the caller pass a deadline.
func (h *ApplicantSupportHandler) HandleWithContext(ctx context.Context, ev jobhandler.Event) jobhandler.Outcome {
	ctx, cancel := context.WithTimeout(ctx, h.Timeout)
	defer cancel()

	event, err := decodeStatusEvent(ev)
	if err != nil {
		return jobhandler.Outcome{
			Status: "manual_review",
			Err:    ErrPermanent,
			Detail: map[string]any{"reason": err.Error()},
		}
	}

	outcome, err := h.Agent.Process(ctx, event)
	detail := map[string]any{
		"agent":   "applicant_support",
		"outcome": string(outcome.Kind),
		"reason":  outcome.Reason,
	}
	if err != nil {
		detail["error"] = err.Error()
	}
	if err != nil {
		switch {
		case errors.Is(err, ErrTransient):
			return jobhandler.Outcome{
				Status: "running",
				Err:    jobhandler.ErrTransient,
				Detail: detail,
			}
		case errors.Is(err, ErrPermanent):
			return jobhandler.Outcome{
				Status: "failed",
				Err:    jobhandler.ErrPermanent,
				Detail: detail,
			}
		default:
			return jobhandler.Outcome{
				Status: "running",
				Err:    jobhandler.ErrTransient,
				Detail: detail,
			}
		}
	}
	return jobhandler.Outcome{Status: "succeeded", Detail: detail}
}

// decodeRequestEvent converts the transport event into the agent's event.
//
// The event id is the NATS message id (the id of the outbox row). It is the
// idempotency key of the whole chain: the same event cannot produce two
// actions.
func decodeRequestEvent(ev jobhandler.Event) (RequestEvent, error) {
	out := RequestEvent{
		RequestID: ev.RequestID,
		EventID:   ev.JobID,
		Reason:    "request.submitted",
	}
	if ev.Extra != nil {
		if id, ok := ev.Extra["event_id"].(string); ok && id != "" {
			out.EventID = id
		}
		if reason, ok := ev.Extra["event_reason"].(string); ok && reason != "" {
			out.Reason = reason
		}
		if status, ok := ev.Extra["status"].(string); ok {
			out.Status = status
		}
	}
	return out, nil
}

// decodeStatusEvent converts the transport event into the agent's event.
func decodeStatusEvent(ev jobhandler.Event) (StatusEvent, error) {
	out := StatusEvent{
		RequestID: ev.RequestID,
		EventID:   ev.JobID,
	}
	if ev.Extra != nil {
		if id, ok := ev.Extra["event_id"].(string); ok && id != "" {
			out.EventID = id
		}
		if v, ok := ev.Extra["event_reason"].(string); ok {
			out.Reason = v
		}
		if v, ok := ev.Extra["from_status"].(string); ok {
			out.FromStatus = v
		}
		if v, ok := ev.Extra["to_status"].(string); ok {
			out.ToStatus = v
		}
		if v, ok := ev.Extra["decision_id"].(string); ok {
			out.DecisionID = v
		}
		if v, ok := ev.Extra["initiator"].(string); ok {
			out.Initiation = v
		}
		if v, ok := ev.Extra["comment"].(string); ok {
			out.Comment = v
		}
		if v, ok := ev.Extra["next_deadline"].(string); ok {
			out.NextDeadline = v
		}
	}
	if out.ToStatus == "" {
		return out, fmt.Errorf("%w: status_changed event without to_status", ErrPermanent)
	}
	return out, nil
}

// EncodeEventDetails renders the details of an agent outcome for the
// job_runs.outcome column.
func EncodeEventDetails(details map[string]any) []byte {
	raw, err := json.Marshal(details)
	if err != nil {
		return []byte(`{}`)
	}
	return raw
}
