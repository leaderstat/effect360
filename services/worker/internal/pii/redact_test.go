package pii

import (
	"reflect"
	"testing"
)

// TestRedact_AllCategories exercises every PII category in one input.
func TestRedact_AllCategories(t *testing.T) {
	in := "Контакт ivan.petrov@example.com, тел. +7 495 123-45-67. " +
		"Паспорт 4515 123456, ИНН 7707083893."
	got := Redact(in)
	for _, want := range []string{
		"[REDACTED:EMAIL]",
		"[REDACTED:PHONE]",
		"[REDACTED:PASSPORT]",
		"[REDACTED:INN]",
	} {
		if !contains(got, want) {
			t.Errorf("redacted missing %q in: %s", want, got)
		}
	}
}

// TestRedact_NoPII: text without PII is returned unchanged.
func TestRedact_NoPII(t *testing.T) {
	in := "Прошу учебную поездку в Казань 12-14 ноября."
	if got := Redact(in); got != in {
		t.Errorf("unexpectedly redacted: %s", got)
	}
}

// TestFind: every expected label is reported.
func TestFind(t *testing.T) {
	in := "email a@b.ru, phone +7 495 123-45-67, inn 7707083893"
	want := []Label{LabelEmail, LabelPhone, LabelINN}
	got := Find(in)
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Find got %v want %v", got, want)
	}
}

func contains(haystack, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}
