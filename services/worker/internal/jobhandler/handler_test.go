package jobhandler

import (
	"errors"
	"testing"
)

// TestDecodeEvent_CanonicalShape covers the happy path: a well-formed v1
// payload decodes into the canonical Event.
func TestDecodeEvent_CanonicalShape(t *testing.T) {
	raw := []byte(`{
		"schema_version": 1,
		"job_type": "classify_and_extract",
		"job_id": "11111111-1111-1111-1111-111111111111",
		"request_id": "22222222-2222-2222-2222-222222222222"
	}`)
	ev, err := DecodeEvent(raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ev.SchemaVersion != 1 || ev.JobType != "classify_and_extract" {
		t.Errorf("unexpected event: %+v", ev)
	}
	if ev.JobID == "" || ev.RequestID == "" {
		t.Errorf("missing identifiers: %+v", ev)
	}
}

// TestDecodeEvent_UnknownSchema ensures that a payload declaring a
// schema version this build does not understand returns ErrUnknownSchema
// (treated as a permanent / poison failure by the consumer).
func TestDecodeEvent_UnknownSchema(t *testing.T) {
	raw := []byte(`{"schema_version": 999}`)
	_, err := DecodeEvent(raw)
	if !errors.Is(err, ErrUnknownSchema) {
		t.Fatalf("expected ErrUnknownSchema, got %v", err)
	}
}

// TestDecodeEvent_InvalidJSON ensures that a malformed payload is
// reported as ErrInvalidPayload, not as some opaque parse error.
func TestDecodeEvent_InvalidJSON(t *testing.T) {
	raw := []byte(`{not json`)
	_, err := DecodeEvent(raw)
	if !errors.Is(err, ErrInvalidPayload) {
		t.Fatalf("expected ErrInvalidPayload, got %v", err)
	}
}

// TestDecodeEvent_MissingFields covers the case where schema_version
// is present but the required identifiers are absent.
func TestDecodeEvent_MissingFields(t *testing.T) {
	raw := []byte(`{"schema_version": 1, "job_type": "x"}`)
	_, err := DecodeEvent(raw)
	if !errors.Is(err, ErrInvalidPayload) {
		t.Fatalf("expected ErrInvalidPayload, got %v", err)
	}
}

// TestDecodeEvent_MissingSchemaVersion treats a missing schema_version
// as invalid (no implicit default).
func TestDecodeEvent_MissingSchemaVersion(t *testing.T) {
	raw := []byte(`{"job_type": "x", "job_id": "a", "request_id": "b"}`)
	_, err := DecodeEvent(raw)
	if !errors.Is(err, ErrInvalidPayload) {
		t.Fatalf("expected ErrInvalidPayload, got %v", err)
	}
}
