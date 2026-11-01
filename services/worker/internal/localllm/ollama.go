package localllm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Ollama is the adapter for an Ollama-compatible local server.
// Wire format: POST /api/chat with `stream: false` and an optional
// `format` field for structured outputs (raw JSON Schema). Verified
// against Ollama docs (https://github.com/ollama/ollama/blob/main/docs/api.md).
//
// Ollama-specific notes:
//   - the server defaults to keep_alive=5m; we forward ChatRequest.KeepAlive
//     so operators can tune it via config;
//   - 404 on /api/chat means "model not loaded" — we map that to
//     ErrModelNotFound so operators get a clear actionable error;
//   - Ollama returns a structured "error" field on the response body
//     even with 200 OK; we surface that as ErrProviderFailure.
type Ollama struct {
	cfg Config
}

// NewOllama builds an Ollama adapter. The caller may pass a custom
// HTTPClient (typically an *http.Client) for testing.
func NewOllama(cfg Config) *Ollama {
	if cfg.Timeout <= 0 {
		cfg.Timeout = 30 * time.Second
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: cfg.Timeout}
	}
	cfg.BaseURL = strings.TrimRight(cfg.BaseURL, "/")
	return &Ollama{cfg: cfg}
}

func (o *Ollama) Name() string { return "ollama" }

// ConfigSchema returns a one-line description of the required
// configuration. Used by /health and the operator docs.
func (o *Ollama) ConfigSchema() string {
	return "ollama: LOCAL_LLM_BASE_URL=http://host:11434, LOCAL_LLM_MODEL=<name:tag>"
}

// Chat sends the request to /api/chat and decodes the reply. The
// returned error is one of the sentinel errors in this package so
// the classifier can switch on errors.Is without inspecting the
// underlying transport.
func (o *Ollama) Chat(ctx context.Context, req ChatRequest) (ChatResponse, error) {
	if o.cfg.BaseURL == "" {
		return ChatResponse{}, fmt.Errorf("%w: empty BaseURL", ErrUnavailable)
	}
	model := req.Model
	if model == "" {
		model = o.cfg.Model
	}
	if model == "" {
		return ChatResponse{}, fmt.Errorf("%w: empty model", ErrUnavailable)
	}

	body := ollamaRequest{
		Model:    model,
		Messages: toOllamaMessages(req.Messages),
		Stream:   false,
		Format:   toOllamaFormat(req.Schema),
		Options:  ollamaOptions{Temperature: req.Temperature, NumPredict: req.MaxTokens},
	}
	if req.KeepAlive != "" {
		body.KeepAlive = req.KeepAlive
	}

	raw, err := json.Marshal(body)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("marshal request: %w", err)
	}

	u, err := url.Parse(o.cfg.BaseURL + "/api/chat")
	if err != nil {
		return ChatResponse{}, fmt.Errorf("parse base url: %w", err)
	}
	httpReq, err := http.NewRequestWithContext(ctx,
		http.MethodPost, u.String(), bytes.NewReader(raw))
	if err != nil {
		return ChatResponse{}, fmt.Errorf("build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if o.cfg.APIKey != "" {
		// Some proxies in front of Ollama require a token. Ollama
		// itself does not.
		httpReq.Header.Set("Authorization", "Bearer "+o.cfg.APIKey)
	}

	resp, err := o.cfg.HTTPClient.Do(httpReq)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return ChatResponse{}, ErrContextCanceled
		}
		if isTimeout(err) {
			return ChatResponse{}, fmt.Errorf("%w: %v", ErrTimeout, err)
		}
		return ChatResponse{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	defer resp.Body.Close()

	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("%w: read body: %v", ErrUnavailable, err)
	}

	switch resp.StatusCode {
	case http.StatusOK:
		// fall through to JSON decoding
	case http.StatusNotFound:
		return ChatResponse{}, fmt.Errorf("%w: model %q", ErrModelNotFound, model)
	case http.StatusRequestTimeout, http.StatusGatewayTimeout:
		return ChatResponse{}, ErrTimeout
	case http.StatusBadRequest:
		// Ollama returns 400 for malformed JSON Schema / bad model
		// metadata. Treat as permanent.
		return ChatResponse{}, fmt.Errorf("%w: 400 %s", ErrInvalidSchema, truncate(string(bodyBytes), 200))
	default:
		if resp.StatusCode >= 500 {
			return ChatResponse{}, fmt.Errorf("%w: status=%d body=%s",
				ErrUnavailable, resp.StatusCode, truncate(string(bodyBytes), 200))
		}
		return ChatResponse{}, fmt.Errorf("%w: status=%d body=%s",
			ErrProviderFailure, resp.StatusCode, truncate(string(bodyBytes), 200))
	}

	var parsed ollamaResponse
	if err := json.Unmarshal(bodyBytes, &parsed); err != nil {
		return ChatResponse{}, fmt.Errorf("%w: decode: %v body=%s",
			ErrUnavailable, err, truncate(string(bodyBytes), 200))
	}
	if parsed.Error != "" {
		return ChatResponse{}, fmt.Errorf("%w: %s", ErrProviderFailure, parsed.Error)
	}
	if parsed.Message == nil || parsed.Message.Content == "" {
		return ChatResponse{}, ErrInvalidResponse
	}

	out := ChatResponse{
		Content:          parsed.Message.Content,
		Model:            parsed.Model,
		DoneReason:       parsed.DoneReason,
		PromptTokens:     parsed.PromptEvalCount,
		CompletionTokens: parsed.EvalCount,
		TotalTokens:      parsed.PromptEvalCount + parsed.EvalCount,
	}
	return out, nil
}

// --- wire format --------------------------------------------------------

type ollamaRequest struct {
	Model     string          `json:"model"`
	Messages  []ollamaMessage `json:"messages"`
	Stream    bool            `json:"stream"`
	Format    any             `json:"format,omitempty"` // nil | "json" | raw JSON schema
	Options   ollamaOptions   `json:"options,omitempty"`
	KeepAlive string          `json:"keep_alive,omitempty"`
}

type ollamaMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type ollamaOptions struct {
	Temperature float64 `json:"temperature,omitempty"`
	NumPredict  int     `json:"num_predict,omitempty"`
}

type ollamaResponse struct {
	Model           string         `json:"model"`
	Message         *ollamaMessage `json:"message"`
	DoneReason      string         `json:"done_reason,omitempty"`
	PromptEvalCount int            `json:"prompt_eval_count,omitempty"`
	EvalCount       int            `json:"eval_count,omitempty"`
	Error           string         `json:"error,omitempty"`
}

func toOllamaMessages(in []Message) []ollamaMessage {
	out := make([]ollamaMessage, len(in))
	for i, m := range in {
		out[i] = ollamaMessage{Role: m.Role, Content: m.Content}
	}
	return out
}

// toOllamaFormat converts a Schema into the value Ollama expects for
// the `format` field. Ollama accepts:
//
//   - "json"   -> force JSON output, no schema constraint
//   - <object> -> raw JSON Schema
//   - nil      -> free-form text
func toOllamaFormat(s *Schema) any {
	if s == nil {
		return nil
	}
	// Return the schema as-is: Ollama accepts the raw JSON Schema
	// for the `format` field.
	return s
}

func isTimeout(err error) bool {
	var te interface{ Timeout() bool }
	return errors.As(err, &te) && te.Timeout()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
