// Package extractor implements the deterministic (heuristic) fallback
// classifier + field extractor used when the local LLM provider is
// unavailable.
//
// It is deliberately small and fully deterministic so that:
//
//   - the eval harness can compare heuristic vs. LLM on the same
//     dataset and report a stable baseline;
//   - the consumer can fall back to it transparently when the model
//     endpoint returns ErrUnavailable (per Backlog §12.2 slot 24-25
//     "живая LLM, деградация безопасна").
//
// The extractor returns Extracted{Type, Fields, Confidence}. Confidence
// is a number in [0,1] used by the consumer to decide between
// "succeeded" and "manual_review" (Backlog: confidence < 0.7 ->
// manual fallback).
package extractor

import (
	"regexp"
	"strings"
)

// Extracted is the result of classifying + extracting a free-form
// request text. Field names match the demo fixture's `requirements[]`
// (camelCase, lowercase).
type Extracted struct {
	// Type is the request type, e.g. "demo_trip" or "other".
	Type string
	// Fields holds the extracted values. Values are kept verbatim
	// (no normalisation) so eval can compare them to the dataset's
	// expected values.
	Fields map[string]string
	// Confidence is in [0,1]. < 0.7 means the caller should park the
	// job for manual_review.
	Confidence float64
	// Reason is a short human-readable explanation of why confidence
	// is what it is (used in logs and in job_runs.outcome).
	Reason string
}

// Heuristic extracts from free-form Russian text using deterministic
// regexes. It is intentionally simple and tuned for the demo fixture:
// real Russian business-trip phrases will need a real LLM.
func Heuristic(text string) Extracted {
	text = strings.TrimSpace(text)
	out := Extracted{Fields: map[string]string{}}
	if text == "" {
		out.Type = "other"
		out.Confidence = 0.0
		out.Reason = "empty text"
		return out
	}

	// 1. Classification: "demo_trip" if the text mentions a trip-like
	//    keyword AND a destination city; otherwise "other".
	lower := strings.ToLower(text)
	tripKeyword := regexp.MustCompile(`(?i)(командировк|поездк|учебн|поехат|поезд)`).MatchString(text)
	if !tripKeyword {
		out.Type = "other"
		out.Confidence = 0.9
		out.Reason = "no trip keyword"
		return out
	}

	// 2. Destination city: city names are tricky in Russian (CamelCase
	//    not used). We use a small whitelist of Russian cities for the
	//    demo + a generic "в X" pattern. The whitelist is intentionally
	//    conservative: false negatives here are acceptable; the LLM is
	//    expected to do better.
	cities := []string{
		"Казань", "Москва", "Санкт-Петербург", "Новосибирск", "Сочи",
		"Екатеринбург", "Нижний Новгород", "Самара", "Калининград",
		"Владивосток", "Краснодар", "Уфа", "Челябинск", "Ростов-на-Дону",
	}
	for _, city := range cities {
		if strings.Contains(text, city) {
			out.Fields["destination_city"] = city
			break
		}
	}

	// 3. Date range: "12-14 ноября", "с 12 по 14 ноября", "12 по 14".
	//    We accept Russian month names in genitive or nominative.
	months := map[string]string{
		"января": "января", "январь": "января",
		"февраля": "февраля", "февраль": "февраля",
		"марта": "марта", "март": "марта",
		"апреля": "апреля", "апрель": "апреля",
		"мая": "мая", "май": "мая",
		"июня": "июня", "июнь": "июня",
		"июля": "июля", "июль": "июля",
		"августа": "августа", "август": "августа",
		"сентября": "сентября", "сентябрь": "сентября",
		"октября": "октября", "октябрь": "октября",
		"ноября": "ноября", "ноябрь": "ноября",
		"декабря": "декабря", "декабрь": "декабря",
	}
	dateRange := regexp.MustCompile(`(?i)(\d{1,2})\s*[-—–]\s*(\d{1,2})\s+([а-яё]+)`)
	if m := dateRange.FindStringSubmatch(text); m != nil {
		out.Fields["start_date"] = m[1] + " " + months[strings.ToLower(m[3])]
		out.Fields["end_date"] = m[2] + " " + months[strings.ToLower(m[3])]
	} else {
		// Pattern: "с 12 по 14 ноября" or "12 по 14 ноября".
		dateRangePo := regexp.MustCompile(`(?i)(?:с\s+)?(\d{1,2})\s+по\s+(\d{1,2})\s+([а-яё]+)`)
		if m := dateRangePo.FindStringSubmatch(text); m != nil {
			out.Fields["start_date"] = m[1] + " " + months[strings.ToLower(m[3])]
			out.Fields["end_date"] = m[2] + " " + months[strings.ToLower(m[3])]
		}
	}

	// 4. Purpose: text after "цель —", "цель:", "целью" up to a
	//    sentence boundary or 60 chars.
	purpose := regexp.MustCompile(`(?i)цель\s*[—\-:]\s*([^.,;]{3,80})`)
	if m := purpose.FindStringSubmatch(text); m != nil {
		out.Fields["purpose"] = strings.TrimSpace(m[1])
	}

	// 5. Funding: "грант ... 24-11-001" or "из бюджета".
	if strings.Contains(lower, "грант") {
		out.Fields["funding_source"] = "grant"
		// Try to extract a grant number like "РФФИ 24-11-001".
		grant := regexp.MustCompile(`(?i)([А-ЯЁA-Z]{2,6}\s*\d{2}-\d{2}-\d{3})`)
		if m := grant.FindStringSubmatch(text); m != nil {
			out.Fields["grant_number"] = strings.TrimSpace(m[1])
		}
	} else if strings.Contains(lower, "бюджет") || strings.Contains(lower, "оплата из") {
		out.Fields["funding_source"] = "budget"
	}

	// 6. Confidence: we have a trip keyword + at least one structured
	//    field -> high confidence; trip keyword + nothing else ->
	//    medium; only trip keyword -> manual_review.
	hits := 0
	if _, ok := out.Fields["destination_city"]; ok {
		hits++
	}
	if _, ok := out.Fields["start_date"]; ok {
		hits++
	}
	if _, ok := out.Fields["purpose"]; ok {
		hits++
	}
	if _, ok := out.Fields["funding_source"]; ok {
		hits++
	}
	switch {
	case hits >= 2:
		out.Confidence = 0.9
		out.Reason = "trip with structured fields"
	case hits == 1:
		out.Confidence = 0.6
		out.Reason = "trip with one structured field"
	default:
		out.Confidence = 0.3
		out.Reason = "trip without structured fields"
	}
	out.Type = "demo_trip"
	return out
}
