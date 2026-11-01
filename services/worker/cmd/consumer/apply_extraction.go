// cmd/consumer/apply_extraction.go — persistence of the classification +
// extraction result onto the `requests` row.
//
// Why this file exists
// --------------------
// The classify_and_extract handler (internal/jobhandler) produces the
// classification and the extracted field values, but it deliberately has
// NO database access: the handler package must stay transport- and
// storage-agnostic (see internal/jobhandler/handler.go).
//
// The consumer is the only component that owns a database handle, so it
// is the consumer's job to write the extraction back onto the request
// row. Without this step the request row keeps `fields = '{}'` and
// `request_type_id = NULL` forever, which means:
//
//   - the deterministic completeness gate in the Gleam API can never
//     find the requirements of the request's type, so `submit` always
//     answers "complete" (no requirements => nothing missing) and the
//     request can be submitted with zero fields; and
//   - the UI has nothing to pre-fill and nothing to ask about.
//
// Request-type resolution
// -----------------------
// The classifier returns a *classifier type* (e.g. "demo_trip"), while
// the database stores *request types* (e.g. "Учебная поездка (DEMO)").
// The mapping between the two lives in `request_types.fields_schema`:
//
//	{"classifier_type": "demo_trip"}
//
// A request type without that key is never matched — we refuse to guess
// a mapping, because silently attaching the wrong regulation to a
// request would attach the wrong requirements to it.
//
// Only request types that are explicitly enabled may be attached. The
// DEMO fixture ships with enabled=false on purpose (see
// database/seeds/002_seed_demo_business_trip.sql), so this code will not
// attach it until an administrator enables it. That is the intended
// behaviour, not a bug.
//
// Idempotency
// -----------
// A redelivered event must not corrupt the request row. The UPDATE is
// guarded by `status = 'draft'`: once the request has been submitted it
// is immutable, and a late-arriving extraction is ignored (and logged).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5/pgxpool"
)

// extractionResult is the subset of jobhandler.Outcome.Detail that the
// consumer needs in order to write the request row.
type extractionResult struct {
	// Type is the classifier type, e.g. "demo_trip".
	Type string
	// Fields are the extracted values, keyed by field name.
	Fields map[string]string
}

// errNoExtraction is returned when the outcome carries no usable
// extraction (for example a manual_review outcome).
var errNoExtraction = errors.New("consumer: outcome carries no extraction")

// extractFromDetail pulls the classification + fields out of the
// handler's Detail map. It returns errNoExtraction when the outcome is
// not a successful extraction.
func extractFromDetail(detail map[string]any) (extractionResult, error) {
	if detail == nil {
		return extractionResult{}, errNoExtraction
	}
	typ, _ := detail["type"].(string)
	if typ == "" {
		return extractionResult{}, errNoExtraction
	}
	rawFields, ok := detail["fields"].(map[string]any)
	if !ok {
		// A successful classification with no fields at all is still a
		// valid outcome (e.g. the applicant wrote something that is not
		// a trip request). Treat it as an empty extraction.
		if _, present := detail["fields"]; !present {
			return extractionResult{}, errNoExtraction
		}
		return extractionResult{Type: typ, Fields: map[string]string{}}, nil
	}
	fields := make(map[string]string, len(rawFields))
	for k, v := range rawFields {
		if s, ok := v.(string); ok {
			fields[k] = s
		}
	}
	return extractionResult{Type: typ, Fields: fields}, nil
}

// applyExtraction writes the extraction onto the request row:
//   - `fields`        <- the extracted values
//   - `request_type_id` <- the request type whose classifier_type matches
//
// It returns the number of rows actually updated. A count of 0 with a
// nil error means the request was not in `draft` state any more (it was
// submitted while the job was in flight) — the extraction is then
// deliberately dropped, because a submitted request must be immutable.
func applyExtraction(ctx context.Context, pool *pgxpool.Pool, requestID string, res extractionResult) (int64, error) {
	fieldsJSON, err := json.Marshal(res.Fields)
	if err != nil {
		return 0, fmt.Errorf("marshal extracted fields: %w", err)
	}

	const q = `
		UPDATE requests r
		SET fields = $2::jsonb,
		    request_type_id = rt.id
		FROM request_types rt
		WHERE r.id = $1
		  AND r.status = 'draft'
		  AND rt.enabled = true
		  AND rt.fields_schema->>'classifier_type' = $3
		RETURNING r.id
	`
	tag, err := pool.Exec(ctx, q, requestID, string(fieldsJSON), res.Type)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// explainApplyExtraction turns the "0 rows affected" case into an
// actionable log message instead of a silent no-op, so an operator can
// tell "the request was already submitted" from "no request type
// matched the classifier type".
func explainApplyExtraction(ctx context.Context, pool *pgxpool.Pool, requestID, classifierType string) string {
	var status string
	err := pool.QueryRow(ctx, `SELECT status FROM requests WHERE id = $1`, requestID).Scan(&status)
	if err != nil {
		return fmt.Sprintf("request row unreadable: %v", err)
	}
	if status != "draft" {
		return fmt.Sprintf("request is %q (not draft) — extraction dropped, request is immutable", status)
	}
	var count int
	err = pool.QueryRow(ctx,
		`SELECT count(*) FROM request_types
		 WHERE enabled = true AND fields_schema->>'classifier_type' = $1`,
		classifierType).Scan(&count)
	if err != nil {
		return fmt.Sprintf("request_types lookup failed: %v", err)
	}
	if count == 0 {
		return fmt.Sprintf("no enabled request_type has classifier_type=%q — fields written, request_type_id left NULL", classifierType)
	}
	return "request_type_id set"
}

// logExtraction writes a structured, PII-free log line about the
// extraction. Only field NAMES are logged — never the values, which may
// contain personal data.
func logExtraction(logger *slog.Logger, requestID, classifierType string, fields map[string]string, rows int64, note string) {
	names := make([]string, 0, len(fields))
	for k := range fields {
		names = append(names, k)
	}
	logger.Info("extraction applied",
		"request_id", requestID,
		"classifier_type", classifierType,
		"field_names", names,
		"field_count", len(fields),
		"rows_updated", rows,
		"note", note,
	)
}
