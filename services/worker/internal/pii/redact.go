// Package pii provides a deterministic PII redactor used as a
// safety boundary between free-form request text and any external
// LLM call. The classifier MUST call Redact() before sending text
// to a Provider; the redacted form is what crosses the trust
// boundary.
//
// This is intentionally a thin, deterministic, regex-based scrubber.
// It is NOT a substitute for proper de-identification at the source
// (e.g. not storing ПДн in the first place) — but it raises the
// bar for accidental leaks: emails, phones, passport-like numbers,
// and ИНН-like 10-12 digit sequences are replaced with placeholders
// before the model ever sees them.
//
// For real production-grade PII handling (named entities, MRZ,
// addresses) the redactor must be replaced or augmented with a
// dedicated service. This package is the documented minimal
// boundary; it is not the long-term answer.
package pii

import "regexp"

// Label identifies the placeholder inserted into redacted text.
type Label string

const (
	LabelEmail    Label = "EMAIL"
	LabelPhone    Label = "PHONE"
	LabelPassport Label = "PASSPORT"
	LabelINN      Label = "INN"
)

// patterns is the registry of regexes applied to the input.
// Order matters: longer / more specific patterns first so a Russian
// passport (4+6 digits with optional space) is matched before the
// generic 10-12 digit INN regex strips it.
var patterns = []struct {
	Label Label
	Re    *regexp.Regexp
}{
	{LabelEmail, regexp.MustCompile(`[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}`)},
	{LabelPhone, regexp.MustCompile(`(?:\+7|8)[\s\-(]*\d{3}[\s\-)]*\d{3}[\s\-]*\d{2}[\s\-]*\d{2}`)},
	{LabelPassport, regexp.MustCompile(`\b\d{4}[\s\-]\d{6}\b`)},
	{LabelINN, regexp.MustCompile(`\b\d{10,12}\b`)},
}

// Find scans the text and returns the labels of every PII category
// detected. Useful for the pii_redaction_recall metric: the consumer
// can verify that every expected label was found.
func Find(text string) []Label {
	var found []Label
	for _, p := range patterns {
		if p.Re.FindString(text) != "" {
			found = append(found, p.Label)
		}
	}
	return found
}

// Redact replaces every match with `[REDACTED:<label>]`. The
// returned string is safe to send to a local LLM under the
// documented minimal boundary.
func Redact(text string) string {
	out := text
	for _, p := range patterns {
		out = p.Re.ReplaceAllString(out, "[REDACTED:"+string(p.Label)+"]")
	}
	return out
}
