// Package mellumclient is a thin transport-only client for an
// OpenAI-compatible chat completions endpoint. It is deliberately
// minimal:
//
//   - no business logic (no field schema, no routing);
//   - no retry on transport errors — that is the consumer's job;
//   - no streaming (the consumer processes one event at a time);
//   - explicit JSON contract (request schema v1, response schema v1).
//
// The intent is that swapping providers (Mellum 2.1, YandexGPT,
// GigaChat, a local proxy) is a one-line change in the constructor
// because all of them expose the same wire shape.
package mellumclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Config is the minimum needed to talk to an OpenAI-compatible endpoint.
type Config struct {
	// BaseURL is the root of the API (e.g. "http://10.0.0.5:8080").
	BaseURL string
	// APIKey may be empty if the local server is unauthenticated.
	APIKey string
	// Model is the model name sent in the request body.
	Model string
	// Timeout is the per-call timeout. Zero means 30 seconds.
	Timeout time.Duration
	// HTTPClient, when non-nil, replaces the default http.Client.
	// Used in tests to point at an httptest server.
	HTTPClient *http.Client
}

// Message is the canonical OpenAI chat-completions message.
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ChatRequest is the canonical OpenAI-compatible chat-completions
// request body used by this client. We keep it minimal on purpose.
type ChatRequest struct {
	Model       string    `json:"model"`
	Messages    []Message `json:"messages"`
	Temperature float64   `json:"temperature,omitempty"`
	MaxTokens   int       `json:"max_tokens,omitempty"`
	// ResponseFormat forces JSON-object output (where the server
	// supports it). Empty means "no constraint".
	ResponseFormat *ResponseFormat `json:"response_format,omitempty"`
}

// ResponseFormat enables JSON-object output. Used when the caller
// expects a structured payload back.
type ResponseFormat struct {
	Type string `json:"type"` // "json_object"
}

// ChatResponse is the trimmed shape of an OpenAI-compatible response.
// Only fields we actually use are decoded.
type ChatResponse struct {
	ID      string    `json:"id"`
	Model   string    `json:"model"`
	Choices []Choice  `json:"choices"`
	Usage   *Usage    `json:"usage,omitempty"`
	Error   *APIError `json:"error,omitempty"`
}

// Choice is a single completion choice.
type Choice struct {
	Index        int     `json:"index"`
	Message      Message `json:"message"`
	FinishReason string  `json:"finish_reason"`
}

// Usage is optional token accounting.
type Usage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// APIError mirrors OpenAI's structured error.
type APIError struct {
	Message string `json:"message"`
	Type    string `json:"type"`
	Code    string `json:"code"`
}

// Client is the public entry point.
type Client struct {
	cfg Config
}

// ErrUnavailable is returned when the remote is unreachable, returns a
// non-2xx status, or returns malformed JSON. The consumer treats this
// as a transient failure and NAKs.
var ErrUnavailable = errors.New("mellumclient: endpoint unavailable")

// ErrInvalidResponse is returned when the remote returned 2xx but the
// payload is structurally wrong. Treated as a permanent failure by the
// consumer (no point retrying the same request).
var ErrInvalidResponse = errors.New("mellumclient: invalid response")

// New builds a Client.
func New(cfg Config) *Client {
	if cfg.Timeout <= 0 {
		cfg.Timeout = 30 * time.Second
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: cfg.Timeout}
	}
	if cfg.BaseURL != "" && strings.HasSuffix(cfg.BaseURL, "/") {
		cfg.BaseURL = strings.TrimRight(cfg.BaseURL, "/")
	}
	return &Client{cfg: cfg}
}

// Chat sends a single chat-completion request and returns the first
// choice's content. It does NOT interpret the content (that is the
// caller's job, because interpretation is business logic).
func (c *Client) Chat(ctx context.Context, req ChatRequest) (ChatResponse, error) {
	if c.cfg.BaseURL == "" {
		return ChatResponse{}, fmt.Errorf("%w: empty BaseURL", ErrUnavailable)
	}
	if req.Model == "" {
		req.Model = c.cfg.Model
	}
	body, err := json.Marshal(req)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx,
		http.MethodPost,
		c.cfg.BaseURL+"/v1/chat/completions",
		bytes.NewReader(body),
	)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if c.cfg.APIKey != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.cfg.APIKey)
	}

	resp, err := c.cfg.HTTPClient.Do(httpReq)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("%w: read body: %v", ErrUnavailable, err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return ChatResponse{}, fmt.Errorf("%w: status=%d body=%s",
			ErrUnavailable, resp.StatusCode, truncate(string(raw), 200))
	}

	var out ChatResponse
	if err := json.Unmarshal(raw, &out); err != nil {
		return ChatResponse{}, fmt.Errorf("%w: decode: %v body=%s",
			ErrUnavailable, err, truncate(string(raw), 200))
	}
	if out.Error != nil && out.Error.Message != "" {
		return ChatResponse{}, fmt.Errorf("%w: api error: %s",
			ErrUnavailable, out.Error.Message)
	}
	if len(out.Choices) == 0 {
		return ChatResponse{}, fmt.Errorf("%w: no choices", ErrInvalidResponse)
	}
	if out.Choices[0].Message.Content == "" {
		return ChatResponse{}, fmt.Errorf("%w: empty completion", ErrInvalidResponse)
	}
	return out, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
