// Package jobhandler implements the transport-agnostic handler for
// "requests.created" events. It contains:
//
// The consumer is responsible for dispatching to the right handler based
//
//	on the schema's job_type;
//	- the Outcome type and the three terminal states (Succeeded, Failed,
//	  ManualReview) used by the consumer to drive ACK vs NAK with delay
//	  vs park.
//
// This package is intentionally thin: it must not contain business
// logic that belongs to the request lifecycle, nor any transport
// code. The consumer layer owns JetStream subscriptions, ACK/NAK,
// retry policy, and persistence of job_runs transitions; the handler
// only decides the outcome of a single event.
//
// The handler ALSO must not write to the `requests` table. Writing the
// extracted fields back to the request row is the consumer's job
// (see cmd/consumer/main.go :: applyExtraction), because only the
// consumer owns the database handle and the transaction boundary. The
// handler exposes the extraction result through Outcome.Detail.
package jobhandler

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Event is the canonical shape of a "requests.created" JetStream message.
// Schema version is part of the contract so consumers can refuse unknown
// versions cleanly (the parent infrastructure requires this).
//
// Extra is an open-ended bag for optional payload extensions (raw_text,
// correlation_id from upstream, retry count, etc). Unknown fields are
// preserved verbatim by the decoder so future schema bumps can add
// fields without forcing a version bump.
type Event struct {
	SchemaVersion int                    `json:"schema_version"`
	JobType       string                 `json:"job_type"`
	JobID         string                 `json:"job_id"`
	RequestID     string                 `json:"request_id"`
	Extra         map[string]interface{} `json:"-"`
}

// SupportedSchemaVersion is the only schema version this consumer
// understands today. Bumping it requires a deliberate code change.
const SupportedSchemaVersion = 1

// ErrUnknownSchema is returned when the event declares a schema version
// this build does not understand. It is treated as a permanent failure
// (poison message) by the consumer.
var ErrUnknownSchema = errors.New("jobhandler: unknown schema_version")

// ErrInvalidPayload is returned when the event payload is malformed.
// Permanent failure.
var ErrInvalidPayload = errors.New("jobhandler: invalid payload")

// ErrPermanent marks an outcome that must NOT be retried. The consumer
// parks the message in job_runs with status 'failed' or 'manual_review'
// and ACKs it so it never gets redelivered.
var ErrPermanent = errors.New("jobhandler: permanent failure")

// ErrTransient marks an outcome that may succeed on retry. The consumer
// NAKs the message with a delay so JetStream redelivers it.
var ErrTransient = errors.New("jobhandler: transient failure")

// ErrInvalidResponse is returned when a downstream provider returned
// 2xx but the payload is structurally wrong (malformed JSON, missing
// fields). Treated as permanent by the consumer — retrying the same
// prompt won't help.
var ErrInvalidResponse = errors.New("jobhandler: invalid response from provider")

// Outcome describes the result of a handler invocation. Exactly one of
// Status or Err is meaningful; both are returned so the consumer can log
// and persist a stable terminal status without re-decoding.
type Outcome struct {
	// Status is one of: "succeeded", "failed", "manual_review". Always set.
	Status string
	// Err is the underlying error (ErrPermanent/ErrTransient/...).
	// nil when Status == "succeeded".
	Err error
	// Detail is an opaque payload persisted to job_runs.outcome (jsonb).
	Detail map[string]any
}

// DecodeEvent parses a raw NATS message body into a canonical Event.
// Returns ErrInvalidPayload for malformed JSON or missing required
// fields, and ErrUnknownSchema for unsupported schema_version.
func DecodeEvent(raw []byte) (Event, error) {
	// First pass: decode known fields.
	var e Event
	if err := json.Unmarshal(raw, &e); err != nil {
		return Event{}, fmt.Errorf("%w: %v", ErrInvalidPayload, err)
	}
	// Second pass: capture unknown fields into Extra so consumers can
	// still use them without forcing a schema bump.
	var rawMap map[string]interface{}
	if err := json.Unmarshal(raw, &rawMap); err == nil {
		for _, k := range []string{"schema_version", "job_type", "job_id", "request_id"} {
			delete(rawMap, k)
		}
		if len(rawMap) > 0 {
			e.Extra = rawMap
		}
	}
	if e.SchemaVersion == 0 {
		return Event{}, fmt.Errorf("%w: schema_version is required", ErrInvalidPayload)
	}
	if e.SchemaVersion != SupportedSchemaVersion {
		return Event{}, fmt.Errorf("%w: %d", ErrUnknownSchema, e.SchemaVersion)
	}
	if e.JobID == "" || e.RequestID == "" || e.JobType == "" {
		return Event{}, fmt.Errorf("%w: job_id, request_id and job_type are required", ErrInvalidPayload)
	}
	return e, nil
}

// Handler processes a single decoded Event and returns an Outcome. It
// MUST be idempotent: the consumer may call it multiple times for the
// same message. It MUST NOT change request status (that is the API's
// job). It MUST NOT log personal data.
//
// When the handler produced a successful extraction, it MUST expose the
// extraction through Outcome.Detail using the canonical keys so the
// consumer can persist them:
//
//	Detail["type"]   — the classified request type (e.g. "demo_trip")
//	Detail["fields"] — map[string]string of extracted field values
//
// The consumer is the only component that writes these values to the
// `requests` row; the handler has no database access.
type Handler interface {
	// Handle is called once per (re)delivery. It returns:
	//   - Outcome{Status: "succeeded", ...}                 -> ACK
	//   - Outcome{Status: "failed", Err: ErrPermanent, ...} -> ACK + park
	//   - Outcome{Status: "manual_review", ...}             -> ACK + park
	//   - Outcome{Err: ErrTransient, ...}                   -> NAK + retry
	Handle(ev Event) Outcome
}

// JobTypeOf is a small helper used by the consumer for dispatching.
func JobTypeOf(ev Event) string { return ev.JobType }
