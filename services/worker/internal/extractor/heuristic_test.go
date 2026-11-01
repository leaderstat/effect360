package extractor

import (
	"testing"
)

// TestHeuristic_KazanTrip verifies the canonical demo phrase: every
// expected field must be present.
func TestHeuristic_KazanTrip(t *testing.T) {
	res := Heuristic(
		"Прошу учебную поездку в Казань с 12 по 14 ноября 2026 года. " +
			"Цель — конференция AI-Summit. Финансирование — грант РФФИ 24-11-001.",
	)
	if res.Type != "demo_trip" {
		t.Errorf("type=%q want demo_trip", res.Type)
	}
	want := map[string]string{
		"destination_city": "Казань",
		"start_date":       "12 ноября",
		"end_date":         "14 ноября",
		"purpose":          "конференция AI-Summit",
		"funding_source":   "grant",
		"grant_number":     "РФФИ 24-11-001",
	}
	for k, v := range want {
		if got := res.Fields[k]; got != v {
			t.Errorf("field %q: got %q want %q", k, got, v)
		}
	}
	if res.Confidence < 0.7 {
		t.Errorf("confidence too low: %v", res.Confidence)
	}
}

// TestHeuristic_Other verifies that text without trip keywords is
// classified as "other".
func TestHeuristic_Other(t *testing.T) {
	res := Heuristic("Это просто тест.")
	if res.Type != "other" {
		t.Errorf("type=%q want other", res.Type)
	}
}

// TestHeuristic_BudgetTrip: a budget-funded trip should be classified
// correctly even without a grant number.
func TestHeuristic_BudgetTrip(t *testing.T) {
	res := Heuristic(
		"Нужно поехать в Санкт-Петербург 3-5 декабря, встречи с подрядчиками. " +
			"Оплата из бюджета отдела.",
	)
	if res.Type != "demo_trip" {
		t.Errorf("type=%q want demo_trip", res.Type)
	}
	if res.Fields["destination_city"] != "Санкт-Петербург" {
		t.Errorf("city=%q", res.Fields["destination_city"])
	}
	if res.Fields["funding_source"] != "budget" {
		t.Errorf("funding=%q want budget", res.Fields["funding_source"])
	}
	if _, has := res.Fields["grant_number"]; has {
		t.Errorf("grant_number should not be present for budget trip")
	}
}

// TestHeuristic_Empty verifies the empty input contract.
func TestHeuristic_Empty(t *testing.T) {
	res := Heuristic("")
	if res.Type != "other" || res.Confidence != 0 {
		t.Errorf("empty: %+v", res)
	}
}

// TestHeuristic_NoDestinationLowConfidence: a trip keyword without any
// structured fields should land below the 0.7 floor so the consumer
// parks it for manual_review.
func TestHeuristic_NoDestinationLowConfidence(t *testing.T) {
	res := Heuristic("Прошу командировку.")
	if res.Type != "demo_trip" {
		t.Errorf("type=%q want demo_trip", res.Type)
	}
	if res.Confidence >= 0.7 {
		t.Errorf("confidence should be <0.7 with no fields, got %v", res.Confidence)
	}
}
