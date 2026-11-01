package localllm

import (
	"context"
	"net/http"
	"time"
)

// Message is a single chat message in the OpenAI-compatible shape.
type Message struct {
	Role    string `json:"role"` // "system" | "user" | "assistant"
	Content string `json:"content"`
}

// Schema is a minimal subset of JSON Schema used to constrain the
// provider's output. Ollama accepts this verbatim under "format".
type Schema struct {
	Type                 string             `json:"type"` // "object"
	Properties           map[string]*Schema `json:"properties,omitempty"`
	Required             []string           `json:"required,omitempty"`
	AdditionalProperties *bool              `json:"additionalProperties,omitempty"`
}

// ChatRequest is the provider-agnostic request shape. Adapters
// translate it to the provider's native format.
type ChatRequest struct {
	// Model overrides the default configured model. Empty means
	// "use the provider's configured model".
	Model string
	// Messages is the conversation. Must include at least one user
	// message. System messages are prepended unchanged.
	Messages []Message
	// Schema constrains the output. Nil means "free-form text".
	Schema *Schema
	// Temperature is the sampling temperature. Zero means "use the
	// provider's default". Recommended: 0.1 for extraction.
	Temperature float64
	// MaxTokens caps the response length. Zero means "no cap".
	MaxTokens int
	// KeepAlive controls how long the model stays loaded after the
	// call (Ollama-specific). Empty means "provider default".
	KeepAlive string
}

// ChatResponse is the provider-agnostic response shape. Adapters
// populate it from the provider's native format.
type ChatResponse struct {
	// Content is the assistant message text. For structured outputs
	// this is a JSON string that the caller must parse.
	Content string
	// Model is the actual model name that produced the response
	// (some providers override the requested model).
	Model string
	// PromptTokens, CompletionTokens, TotalTokens are best-effort
	// accounting. Zero if the provider doesn't report them.
	PromptTokens     int
	CompletionTokens int
	TotalTokens      int
	// DoneReason is the provider's finish reason (e.g. "stop",
	// "length"). Empty if unknown.
	DoneReason string
}

// Provider is the abstract contract every LLM backend satisfies.
type Provider interface {
	// Name identifies the backend ("ollama", "openai-compatible",
	// etc). Used for logging and job_runs.outcome audit.
	Name() string
	// Chat sends a single chat-completion request and returns the
	// response, or one of the sentinel errors above.
	Chat(ctx context.Context, req ChatRequest) (ChatResponse, error)
	// ConfigSchema returns a human-readable description of the
	// provider's required configuration (used by docs and the
	// /health endpoint so operators can see what's missing).
	ConfigSchema() string
}

// Config holds the base settings shared by every adapter. Adapters
// may extend it.
type Config struct {
	// BaseURL is the provider's HTTP root.
	BaseURL string
	// APIKey is optional (Ollama doesn't require one).
	APIKey string
	// Model is the default model name when ChatRequest.Model is empty.
	Model string
	// Timeout is the per-call timeout. Zero means 30 seconds.
	Timeout time.Duration
	// HTTPClient, when non-nil, replaces the default http.Client.
	// Used in tests to point at an httptest server.
	HTTPClient *http.Client
	// ProviderKind selects the adapter: "ollama" (default) or
	// "openai-compatible".
	ProviderKind string
}
