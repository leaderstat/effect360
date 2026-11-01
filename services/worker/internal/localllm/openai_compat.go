package localllm

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

// OpenAICompat is an adapter for any provider that speaks the
// OpenAI-compatible /v1/chat/completions API (llama.cpp server,
// vLLM, LocalAI, etc). It deliberately implements a strict subset
// of OpenAI: messages, model, temperature, max_tokens,
// response_format with type=json_object. Anything beyond that must
// be added with care because each provider interprets the extras
// differently.
type OpenAICompat struct {
	cfg Config
}

// NewOpenAICompat builds an OpenAI-compatible adapter.
func NewOpenAICompat(cfg Config) *OpenAICompat {
	if cfg.Timeout <= 0 {
		cfg.Timeout = 30 * time.Second
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: cfg.Timeout}
	}
	cfg.BaseURL = strings.TrimRight(cfg.BaseURL, "/")
	return &OpenAICompat{cfg: cfg}
}

func (o *OpenAICompat) Name() string { return "openai-compatible" }

// ConfigSchema describes required configuration.
func (o *OpenAICompat) ConfigSchema() string {
	return "openai-compatible: LOCAL_LLM_BASE_URL=http://host:port, LOCAL_LLM_MODEL=<name>"
}

// Chat sends the request to /v1/chat/completions.
func (o *OpenAICompat) Chat(ctx context.Context, req ChatRequest) (ChatResponse, error) {
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

	body := openAIRequest{
		Model:       model,
		Messages:    toOpenAIMessages(req.Messages),
		Temperature: req.Temperature,
		MaxTokens:   req.MaxTokens,
	}
	if req.Schema != nil {
		body.ResponseFormat = &openAIResponseFormat{Type: "json_object"}
	}

	raw, err := json.Marshal(body)
	if err != nil {
		return ChatResponse{}, fmt.Errorf("marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx,
		http.MethodPost, o.cfg.BaseURL+"/v1/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return ChatResponse{}, fmt.Errorf("build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if o.cfg.APIKey != "" {
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
		// fall through
	case http.StatusNotFound:
		return ChatResponse{}, fmt.Errorf("%w: model %q", ErrModelNotFound, model)
	case http.StatusRequestTimeout, http.StatusGatewayTimeout:
		return ChatResponse{}, ErrTimeout
	case http.StatusBadRequest, http.StatusUnprocessableEntity:
		return ChatResponse{}, fmt.Errorf("%w: %d %s",
			ErrInvalidSchema, resp.StatusCode, truncate(string(bodyBytes), 200))
	default:
		if resp.StatusCode >= 500 {
			return ChatResponse{}, fmt.Errorf("%w: status=%d body=%s",
				ErrUnavailable, resp.StatusCode, truncate(string(bodyBytes), 200))
		}
		return ChatResponse{}, fmt.Errorf("%w: status=%d body=%s",
			ErrProviderFailure, resp.StatusCode, truncate(string(bodyBytes), 200))
	}

	var parsed openAIResponse
	if err := json.Unmarshal(bodyBytes, &parsed); err != nil {
		return ChatResponse{}, fmt.Errorf("%w: decode: %v body=%s",
			ErrUnavailable, err, truncate(string(bodyBytes), 200))
	}
	if parsed.Error != nil && parsed.Error.Message != "" {
		return ChatResponse{}, fmt.Errorf("%w: %s",
			ErrProviderFailure, parsed.Error.Message)
	}
	if len(parsed.Choices) == 0 || parsed.Choices[0].Message.Content == "" {
		return ChatResponse{}, ErrInvalidResponse
	}

	choice := parsed.Choices[0]
	out := ChatResponse{
		Content:    choice.Message.Content,
		Model:      parsed.Model,
		DoneReason: choice.FinishReason,
	}
	if parsed.Usage != nil {
		out.PromptTokens = parsed.Usage.PromptTokens
		out.CompletionTokens = parsed.Usage.CompletionTokens
		out.TotalTokens = parsed.Usage.TotalTokens
	}
	return out, nil
}

// --- wire format --------------------------------------------------------

type openAIRequest struct {
	Model          string                `json:"model"`
	Messages       []openAIMessage       `json:"messages"`
	Temperature    float64               `json:"temperature,omitempty"`
	MaxTokens      int                   `json:"max_tokens,omitempty"`
	ResponseFormat *openAIResponseFormat `json:"response_format,omitempty"`
}

type openAIMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type openAIResponseFormat struct {
	Type string `json:"type"` // "json_object"
}

type openAIResponse struct {
	Model   string         `json:"model"`
	Choices []openAIChoice `json:"choices"`
	Usage   *openAIUsage   `json:"usage,omitempty"`
	Error   *openAIError   `json:"error,omitempty"`
}

type openAIChoice struct {
	Index        int           `json:"index"`
	Message      openAIMessage `json:"message"`
	FinishReason string        `json:"finish_reason"`
}

type openAIUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

type openAIError struct {
	Message string `json:"message"`
	Type    string `json:"type"`
	Code    string `json:"code"`
}

func toOpenAIMessages(in []Message) []openAIMessage {
	out := make([]openAIMessage, len(in))
	for i, m := range in {
		out[i] = openAIMessage{Role: m.Role, Content: m.Content}
	}
	return out
}

// New constructs the right adapter based on cfg.ProviderKind. Unknown
// kinds default to Ollama, which is the most common local setup.
func New(cfg Config) Provider {
	if cfg.ProviderKind == "openai-compatible" {
		return NewOpenAICompat(cfg)
	}
	return NewOllama(cfg)
}
