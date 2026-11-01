package localllm

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// newTestClient is reserved for tests that need to dial a closed
// port. Today every test uses httptest.NewServer, so this is a stub.
func newTestClient(t *testing.T, _ string) *http.Client {
	t.Helper()
	return &http.Client{Timeout: 1 * time.Second}
}

// TestOllama_HappyPath: well-formed request → ChatResponse with content.
func TestOllama_HappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/chat" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"model": "devstral-small-2:latest",
			"message": {"role":"assistant","content":"{\"type\":\"demo_trip\",\"fields\":{\"destination_city\":\"Kazan\"},\"confidence\":0.92,\"reason\":\"ok\"}"},
			"done_reason": "stop",
			"prompt_eval_count": 80,
			"eval_count": 32
		}`))
	}))
	defer srv.Close()

	c := NewOllama(Config{BaseURL: srv.URL, Model: "devstral-small-2:latest"})
	resp, err := c.Chat(context.Background(), ChatRequest{
		Messages: []Message{{Role: "user", Content: "hi"}},
		Schema:   &Schema{Type: "object"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(resp.Content, "demo_trip") {
		t.Errorf("content missing: %s", resp.Content)
	}
	if resp.PromptTokens != 80 || resp.CompletionTokens != 32 {
		t.Errorf("tokens: got %d/%d want 80/32", resp.PromptTokens, resp.CompletionTokens)
	}
}

// TestOllama_StructuredFields: when Schema is provided, the request
// payload must include `format` with the JSON schema.
func TestOllama_StructuredFields(t *testing.T) {
	var captured atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := make([]byte, r.ContentLength)
		_, _ = r.Body.Read(body)
		captured.Store(string(body))
		_, _ = w.Write([]byte(`{"model":"x","message":{"role":"assistant","content":"{}"}}`))
	}))
	defer srv.Close()

	c := NewOllama(Config{BaseURL: srv.URL, Model: "x"})
	_, err := c.Chat(context.Background(), ChatRequest{
		Messages: []Message{{Role: "user", Content: "x"}},
		Schema:   &Schema{Type: "object", Properties: map[string]*Schema{"type": {Type: "string"}}},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	body := captured.Load().(string)
	if !strings.Contains(body, `"format"`) {
		t.Errorf("request missing format: %s", body)
	}
	if !strings.Contains(body, `"object"`) {
		t.Errorf("request missing schema type: %s", body)
	}
}

// TestOllama_HTTP500: 5xx → ErrUnavailable.
func TestOllama_HTTP500(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"server"}`))
	}))
	defer srv.Close()
	c := NewOllama(Config{BaseURL: srv.URL, Model: "x"})
	_, err := c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrUnavailable) {
		t.Fatalf("expected ErrUnavailable, got %v", err)
	}
}

// TestOllama_Timeout: server hangs past the timeout → ErrTimeout.
func TestOllama_Timeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(500 * time.Millisecond)
		_, _ = w.Write([]byte(`{"message":{"content":"x"}}`))
	}))
	defer srv.Close()
	c := NewOllama(Config{BaseURL: srv.URL, Model: "x", Timeout: 100 * time.Millisecond})
	_, err := c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrTimeout) {
		t.Fatalf("expected ErrTimeout, got %v", err)
	}
}

// TestOllama_ConnectionRefused: dial failure → ErrUnavailable.
func TestOllama_ConnectionRefused(t *testing.T) {
	c := NewOllama(Config{BaseURL: "http://127.0.0.1:1", Model: "x", Timeout: 200 * time.Millisecond})
	_, err := c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrUnavailable) {
		t.Fatalf("expected ErrUnavailable, got %v", err)
	}
}

// TestOllama_ModelNotFound: 404 → ErrModelNotFound.
func TestOllama_ModelNotFound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":"model not found"}`))
	}))
	defer srv.Close()
	c := NewOllama(Config{BaseURL: srv.URL, Model: "ghost"})
	_, err := c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrModelNotFound) {
		t.Fatalf("expected ErrModelNotFound, got %v", err)
	}
}

// TestOllama_InvalidJSON: 200 with malformed body → ErrUnavailable.
func TestOllama_InvalidJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{not json`))
	}))
	defer srv.Close()
	c := NewOllama(Config{BaseURL: srv.URL, Model: "x"})
	_, err := c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrUnavailable) {
		t.Fatalf("expected ErrUnavailable, got %v", err)
	}
}

// TestOllama_EmptyContent: 200 with empty content → ErrInvalidResponse.
func TestOllama_EmptyContent(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"model":"x","message":{"role":"assistant","content":""}}`))
	}))
	defer srv.Close()
	c := NewOllama(Config{BaseURL: srv.URL, Model: "x"})
	_, err := c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrInvalidResponse) {
		t.Fatalf("expected ErrInvalidResponse, got %v", err)
	}
}

// TestOllama_ProviderError: 200 with "error" field → ErrProviderFailure.
func TestOllama_ProviderError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"error":"out of memory"}`))
	}))
	defer srv.Close()
	c := NewOllama(Config{BaseURL: srv.URL, Model: "x"})
	_, err := c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrProviderFailure) {
		t.Fatalf("expected ErrProviderFailure, got %v", err)
	}
}

// TestOllama_ContextCanceled: cancelling the context → ErrContextCanceled.
func TestOllama_ContextCanceled(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer srv.Close()
	c := NewOllama(Config{BaseURL: srv.URL, Model: "x"})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := c.Chat(ctx, ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrContextCanceled) {
		t.Fatalf("expected ErrContextCanceled, got %v", err)
	}
}

// TestOllama_EmptyBaseURL: configuration error.
func TestOllama_EmptyBaseURL(t *testing.T) {
	c := NewOllama(Config{Model: "x"})
	_, err := c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrUnavailable) {
		t.Fatalf("expected ErrUnavailable, got %v", err)
	}
}

// TestOllama_BadRequest: 400 (bad schema) → ErrInvalidSchema.
func TestOllama_BadRequest(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid schema"}`))
	}))
	defer srv.Close()
	c := NewOllama(Config{BaseURL: srv.URL, Model: "x"})
	_, err := c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if !errors.Is(err, ErrInvalidSchema) {
		t.Fatalf("expected ErrInvalidSchema, got %v", err)
	}
}

// TestOllama_Authorization: when APIKey is set, request must carry the
// Authorization header.
func TestOllama_Authorization(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{"message":{"content":"ok"}}`))
	}))
	defer srv.Close()
	c := NewOllama(Config{BaseURL: srv.URL, Model: "x", APIKey: "secret"})
	_, _ = c.Chat(context.Background(), ChatRequest{Messages: []Message{{Role: "user", Content: "x"}}})
	if got != "Bearer secret" {
		t.Errorf("expected Authorization header, got %q", got)
	}
}

// TestNew_SelectsOllamaByDefault: New() with empty ProviderKind picks
// Ollama (Name() == "ollama").
func TestNew_SelectsOllamaByDefault(t *testing.T) {
	p := New(Config{BaseURL: "http://x", Model: "y"})
	if p.Name() != "ollama" {
		t.Errorf("expected ollama, got %s", p.Name())
	}
}

// TestNew_SelectsOpenAICompat: explicit ProviderKind picks the other adapter.
func TestNew_SelectsOpenAICompat(t *testing.T) {
	p := New(Config{BaseURL: "http://x", Model: "y", ProviderKind: "openai-compatible"})
	if p.Name() != "openai-compatible" {
		t.Errorf("expected openai-compatible, got %s", p.Name())
	}
}
