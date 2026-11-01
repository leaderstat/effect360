package jobhandler

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"

	"effectivnost360/worker/internal/extractor"
	"effectivnost360/worker/internal/localllm"
)

// stubClassifier is a controllable Classifier used in tests.
type stubClassifier struct {
	name      string
	resp      extractor.Extracted
	err       error
	calls     atomic.Int32
	lastText  atomic.Value // string
	available bool         // toggled between calls to simulate flapping
}

func (s *stubClassifier) Name() string { return s.name }
func (s *stubClassifier) Classify(_ context.Context, text string) (extractor.Extracted, error) {
	s.calls.Add(1)
	s.lastText.Store(text)
	if !s.available {
		return extractor.Extracted{}, fmt.Errorf("%w: simulated outage", localllm.ErrUnavailable)
	}
	if s.err != nil {
		return extractor.Extracted{}, s.err
	}
	return s.resp, nil
}

func sampleEvent(jobID string) Event {
	return Event{
		SchemaVersion: 1, JobType: "classify_and_extract",
		JobID: jobID, RequestID: "r-" + jobID,
		Extra: map[string]interface{}{"raw_text": "Прошу учебную поездку в Казань 12-14 ноября 2026."},
	}
}

// TestHandler_HeuristicOnly: with a heuristic-only handler the Outcome
// is succeeded (or manual_review if confidence is low), and no LLM is
// contacted.
func TestHandler_HeuristicOnly(t *testing.T) {
	h := NewHeuristicOnlyHandler()
	out := h.Handle(sampleEvent("j1"))
	if out.Status != "succeeded" && out.Status != "manual_review" {
		t.Fatalf("unexpected status %q (err=%v)", out.Status, out.Err)
	}
	if out.Detail["primary"] != "heuristic" {
		t.Errorf("expected primary=heuristic, got %v", out.Detail["primary"])
	}
}

// TestHandler_PrimarySucceeds: when the primary classifier returns a
// valid result, the handler uses it without falling back.
func TestHandler_PrimarySucceeds(t *testing.T) {
	primary := &stubClassifier{
		name:      "fake-llm",
		available: true,
		resp: extractor.Extracted{
			Type:       "demo_trip",
			Fields:     map[string]string{"destination_city": "Казань"},
			Confidence: 0.95,
			Reason:     "ok",
		},
	}
	fallback := &stubClassifier{name: "heuristic", available: true}
	h := NewClassifyAndExtractHandler(primary, fallback)
	out := h.Handle(sampleEvent("j-pri"))
	if out.Status != "succeeded" {
		t.Fatalf("expected succeeded, got %q (err=%v)", out.Status, out.Err)
	}
	if primary.calls.Load() != 1 {
		t.Errorf("primary should be called once, got %d", primary.calls.Load())
	}
	if fallback.calls.Load() != 0 {
		t.Errorf("fallback should not be called, got %d", fallback.calls.Load())
	}
	if out.Detail["primary"] != "fake-llm" {
		t.Errorf("expected primary=fake-llm, got %v", out.Detail["primary"])
	}
}

// TestHandler_PrimaryUnavailableFallsBack: when the primary returns
// ErrUnavailable, the handler MUST call the fallback and record that
// it did.
func TestHandler_PrimaryUnavailableFallsBack(t *testing.T) {
	primary := &stubClassifier{name: "fake-llm", available: false}
	fallback := &stubClassifier{
		name:      "heuristic",
		available: true,
		resp: extractor.Extracted{
			Type: "demo_trip", Fields: map[string]string{"destination_city": "Казань"},
			Confidence: 0.9, Reason: "ok",
		},
	}
	h := NewClassifyAndExtractHandler(primary, fallback)
	out := h.Handle(sampleEvent("j-fb"))
	if out.Status != "succeeded" {
		t.Fatalf("expected succeeded via fallback, got %q (err=%v)", out.Status, out.Err)
	}
	if primary.calls.Load() == 0 {
		t.Errorf("primary should be tried at least once")
	}
	if fallback.calls.Load() == 0 {
		t.Errorf("fallback should be called when primary is unavailable")
	}
	if out.Detail["primary"] != "heuristic" {
		t.Errorf("expected primary=heuristic in fallback path, got %v", out.Detail["primary"])
	}
}

// TestHandler_PrimaryPermanentErrorNoFallback: when the primary returns
// a non-availability error, the handler MUST NOT fall back — the
// prompt is broken.
func TestHandler_PrimaryPermanentErrorNoFallback(t *testing.T) {
	primary := &stubClassifier{name: "fake-llm", available: true, err: ErrInvalidResponse}
	fallback := &stubClassifier{name: "heuristic", available: true}
	h := NewClassifyAndExtractHandler(primary, fallback)
	out := h.Handle(sampleEvent("j-perm"))
	if fallback.calls.Load() != 0 {
		t.Errorf("fallback must not be called on permanent primary error")
	}
	if out.Status != "manual_review" {
		t.Errorf("expected manual_review, got %q", out.Status)
	}
	if !errors.Is(out.Err, ErrPermanent) {
		t.Errorf("expected ErrPermanent, got %v", out.Err)
	}
}

// TestHandler_LowConfidenceManualReview: confidence below the floor
// turns succeeded -> manual_review.
func TestHandler_LowConfidenceManualReview(t *testing.T) {
	primary := &stubClassifier{
		name: "fake-llm", available: true,
		resp: extractor.Extracted{
			Type: "demo_trip", Fields: map[string]string{}, Confidence: 0.4, Reason: "low",
		},
	}
	h := NewClassifyAndExtractHandler(primary, &stubClassifier{name: "heuristic"})
	out := h.Handle(sampleEvent("j-low"))
	if out.Status != "manual_review" {
		t.Errorf("expected manual_review for low confidence, got %q", out.Status)
	}
}

// TestHandler_NoRawTextManualReview: if raw_text is missing in the
// event payload, the handler parks the job for manual_review rather
// than fabricating fields.
func TestHandler_NoRawTextManualReview(t *testing.T) {
	primary := &stubClassifier{name: "fake-llm", available: true}
	h := NewClassifyAndExtractHandler(primary, &stubClassifier{name: "heuristic"})
	ev := Event{
		SchemaVersion: 1, JobType: "classify_and_extract",
		JobID: "j-notext", RequestID: "r-notext",
	}
	out := h.Handle(ev)
	if out.Status != "manual_review" {
		t.Errorf("expected manual_review when raw_text is absent, got %q", out.Status)
	}
	if primary.calls.Load() != 0 {
		t.Errorf("provider must not be called when raw_text is absent")
	}
}

// TestHandler_Idempotent: redelivering the same event returns the
// same outcome without re-calling the provider.
func TestHandler_Idempotent(t *testing.T) {
	primary := &stubClassifier{name: "fake-llm", available: true,
		resp: extractor.Extracted{
			Type: "demo_trip", Fields: map[string]string{"city": "Казань"},
			Confidence: 0.9, Reason: "ok",
		}}
	h := NewClassifyAndExtractHandler(primary, &stubClassifier{name: "heuristic"})
	ev := sampleEvent("j-idem")
	first := h.Handle(ev)
	second := h.Handle(ev)
	if first.Status != second.Status {
		t.Errorf("status diverged: %q vs %q", first.Status, second.Status)
	}
	if primary.calls.Load() != 1 {
		t.Errorf("provider should be called once on idempotent redelivery, got %d", primary.calls.Load())
	}
}

// TestHandler_ConcurrentSameJob: concurrent redeliveries for the same
// job must not cause duplicate provider calls.
func TestHandler_ConcurrentSameJob(t *testing.T) {
	primary := &stubClassifier{name: "fake-llm", available: true,
		resp: extractor.Extracted{
			Type: "demo_trip", Fields: map[string]string{"city": "Казань"},
			Confidence: 0.9, Reason: "ok",
		}}
	h := NewClassifyAndExtractHandler(primary, &stubClassifier{name: "heuristic"})
	ev := sampleEvent("j-conc")

	const n = 64
	var wg sync.WaitGroup
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() {
			defer wg.Done()
			_ = h.Handle(ev)
		}()
	}
	wg.Wait()
	if primary.calls.Load() > 1 {
		t.Errorf("provider called %d times for the same job (expected <=1)", primary.calls.Load())
	}
}

// TestHandler_BothFailIsTransient: if both primary (unavailable) and
// fallback fail, the outcome is transient so the consumer NAKs.
func TestHandler_BothFailIsTransient(t *testing.T) {
	primary := &stubClassifier{name: "fake-llm", available: false}
	fallback := &stubClassifier{name: "heuristic", available: false}
	h := NewClassifyAndExtractHandler(primary, fallback)
	out := h.Handle(sampleEvent("j-both"))
	if !errors.Is(out.Err, ErrTransient) {
		t.Errorf("expected ErrTransient when both providers fail, got %v", out.Err)
	}
}
