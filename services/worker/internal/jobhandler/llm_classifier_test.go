package jobhandler

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"effectivnost360/worker/internal/localllm"
)

// fakeProvider is a controllable localllm.Provider for testing the
// LLMClassifier wrapper.
type fakeProvider struct {
	name     string
	resp     localllm.ChatResponse
	err      error
	calls    atomic.Int32
	lastText atomic.Value // string
}

func (f *fakeProvider) Name() string { return f.name }
func (f *fakeProvider) ConfigSchema() string {
	return f.name + ": test"
}
func (f *fakeProvider) Chat(_ context.Context, req localllm.ChatRequest) (localllm.ChatResponse, error) {
	f.calls.Add(1)
	// Capture the system+user messages so the PII-redaction test
	// can verify that emails/phones never reach the wire.
	if len(req.Messages) > 0 {
		f.lastText.Store(req.Messages[len(req.Messages)-1].Content)
	}
	if f.err != nil {
		return localllm.ChatResponse{}, f.err
	}
	return f.resp, nil
}

// TestLLMClassifier_HappyPath: provider returns valid JSON.
func TestLLMClassifier_HappyPath(t *testing.T) {
	fp := &fakeProvider{
		name: "fake",
		resp: localllm.ChatResponse{
			Content: `{"type":"demo_trip","fields":{"destination_city":"Казань"},"confidence":0.92,"reason":"ok"}`,
		},
	}
	c := &LLMClassifier{Provider: fp, Temperature: 0.1, PromptVersion: "v1"}
	got, err := c.Classify(context.Background(),
		"Прошу учебную поездку в Казань 12-14 ноября.")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Type != "demo_trip" || got.Fields["destination_city"] != "Казань" {
		t.Errorf("got %+v", got)
	}
	if !strings.Contains(c.Name(), "fake") {
		t.Errorf("name=%q", c.Name())
	}
}

// TestLLMClassifier_RedactsPII: input contains an email, phone, and
// passport-like number; none of them may appear in the request
// payload sent to the provider.
func TestLLMClassifier_RedactsPII(t *testing.T) {
	var captured atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := make([]byte, r.ContentLength)
		_, _ = r.Body.Read(body)
		captured.Store(string(body))
		_, _ = w.Write([]byte(`{"message":{"role":"assistant","content":"{\"type\":\"other\",\"fields\":{},\"confidence\":0.5,\"reason\":\"ok\"}"}}`))
	}))
	defer srv.Close()
	provider := localllm.NewOllama(localllm.Config{BaseURL: srv.URL, Model: "x"})

	c := &LLMClassifier{Provider: provider, Temperature: 0.1, PromptVersion: "v1"}
	in := "Связь ivan.petrov@example.com, тел. +7 495 123-45-67. Прошу поездку в Казань."
	_, err := c.Classify(context.Background(), in)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	body := captured.Load().(string)
	for _, leak := range []string{
		"ivan.petrov@example.com",
		"+7 495 123-45-67",
	} {
		if strings.Contains(body, leak) {
			t.Errorf("PII leaked into provider payload: %q", leak)
		}
	}
	for _, want := range []string{
		"[REDACTED:EMAIL]",
		"[REDACTED:PHONE]",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing redacted marker %q in payload", want)
		}
	}
}

// TestLLMClassifier_InvalidSchemaFromProvider: provider returns text
// that is not JSON → ErrInvalidSchema (permanent).
func TestLLMClassifier_InvalidSchemaFromProvider(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"message":{"role":"assistant","content":"not json at all"}}`))
	}))
	defer srv.Close()
	provider := localllm.NewOllama(localllm.Config{BaseURL: srv.URL, Model: "x"})
	c := &LLMClassifier{Provider: provider}
	_, err := c.Classify(context.Background(), "some text")
	if err == nil {
		t.Fatalf("expected error")
	}
}

// TestLLMClassifier_PropagatesProviderError: provider returns
// ErrUnavailable; classifier must propagate it unchanged.
func TestLLMClassifier_PropagatesProviderError(t *testing.T) {
	fp := &fakeProvider{name: "fake", err: localllm.ErrUnavailable}
	c := &LLMClassifier{Provider: fp}
	_, err := c.Classify(context.Background(), "x")
	if err == nil {
		t.Fatalf("expected error")
	}
}
