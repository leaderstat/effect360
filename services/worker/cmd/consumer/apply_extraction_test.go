package main

import (
	"testing"
)

// TestExtractFromDetail_Success: a successful outcome carries the
// classification type and the extracted fields; the consumer must be
// able to read them back out of the Detail map.
func TestExtractFromDetail_Success(t *testing.T) {
	detail := map[string]any{
		"type":       "demo_trip",
		"fields":     map[string]any{"destination_city": "Казань", "purpose": "конференция"},
		"confidence": 0.9,
	}
	res, err := extractFromDetail(detail)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Type != "demo_trip" {
		t.Errorf("expected type demo_trip, got %q", res.Type)
	}
	if res.Fields["destination_city"] != "Казань" {
		t.Errorf("expected destination_city=Казань, got %q", res.Fields["destination_city"])
	}
	if res.Fields["purpose"] != "конференция" {
		t.Errorf("expected purpose=конференция, got %q", res.Fields["purpose"])
	}
}

// TestExtractFromDetail_EmptyFieldsIsValid: a successful classification
// that produced no fields is still a valid outcome — the applicant may
// have written something that is not a trip request at all. The consumer
// must write an empty extraction rather than treat it as a failure.
func TestExtractFromDetail_EmptyFieldsIsValid(t *testing.T) {
	detail := map[string]any{
		"type":   "other",
		"fields": map[string]any{},
	}
	res, err := extractFromDetail(detail)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Type != "other" {
		t.Errorf("expected type other, got %q", res.Type)
	}
	if len(res.Fields) != 0 {
		t.Errorf("expected 0 fields, got %d", len(res.Fields))
	}
}

// TestExtractFromDetail_NonStringValuesDropped: a field whose value is
// not a string (e.g. a JSON number) must be dropped, not coerced — the
// completeness check works on strings only and a coerced value would be
// a lie.
func TestExtractFromDetail_NonStringValuesDropped(t *testing.T) {
	detail := map[string]any{
		"type": "demo_trip",
		"fields": map[string]any{
			"destination_city": "Казань",
			"duration_days":    3,
			"is_granted":       true,
		},
	}
	res, err := extractFromDetail(detail)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(res.Fields) != 1 {
		t.Fatalf("expected 1 string field, got %d: %v", len(res.Fields), res.Fields)
	}
	if _, present := res.Fields["duration_days"]; present {
		t.Error("non-string field must be dropped")
	}
}

// TestExtractFromDetail_NoExtraction: a manual_review outcome carries
// no type/fields. The consumer must recognise that and skip the write
// rather than write an empty extraction over good data.
func TestExtractFromDetail_NoExtraction(t *testing.T) {
	cases := []map[string]any{
		nil,
		{},
		{"reason": "low confidence", "primary": "heuristic"},
		{"type": "", "fields": map[string]any{}},
		{"fields": map[string]any{"a": "b"}}, // no type
	}
	for i, detail := range cases {
		if _, err := extractFromDetail(detail); err == nil {
			t.Errorf("case %d: expected errNoExtraction, got nil", i)
		}
	}
}

// TestExtractFromDetail_FieldsMissingKeyIsNoExtraction: an outcome with
// a type but no "fields" key at all carries no extraction — the
// consumer must not invent an empty field map for it.
func TestExtractFromDetail_FieldsMissingKeyIsNoExtraction(t *testing.T) {
	if _, err := extractFromDetail(map[string]any{"type": "demo_trip"}); err == nil {
		t.Error("expected errNoExtraction when the fields key is absent")
	}
}
