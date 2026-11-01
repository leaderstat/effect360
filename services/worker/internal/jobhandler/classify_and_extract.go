package jobhandler

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"effectivnost360/worker/internal/extractor"
	"effectivnost360/worker/internal/localllm"
	"effectivnost360/worker/internal/pii"
)

// Classifier is the contract between the consumer and any provider
// (Ollama, OpenAI-compatible proxy, heuristic fallback, future
// cloud LLM). It receives a free-form text and returns the canonical
// Extracted shape.
//
// Implementations MUST redact PII before calling any external LLM;
// LLMClassifier does this automatically.
type Classifier interface {
	Classify(ctx context.Context, text string) (extractor.Extracted, error)
	// Name identifies the provider for logging and job_runs.outcome.
	// Examples: "ollama", "openai-compatible", "heuristic", "manual".
	Name() string
}

// LLMClassifier wraps a localllm.Provider with a strict prompt and
// JSON-schema validation. It is the bridge between the provider-
// agnostic Provider interface and the JSON shape the consumer needs.
//
// The classifier calls pii.Redact() on the input before sending it to
// the provider — that is the documented safety boundary. The redacted
// text is what crosses the trust boundary.
type LLMClassifier struct {
	Provider      localllm.Provider
	Temperature   float64
	PromptVersion string
}

// Name returns the provider's name plus the prompt version, e.g.
// "ollama@v3". This is recorded in job_runs.outcome for audit.
func (c *LLMClassifier) Name() string {
	if c.PromptVersion != "" {
		return c.Provider.Name() + "@" + c.PromptVersion
	}
	return c.Provider.Name()
}

// Schema is the JSON Schema that the provider is asked to return.
func (c *LLMClassifier) Schema() *localllm.Schema {
	additional := false
	return &localllm.Schema{
		Type: "object",
		Properties: map[string]*localllm.Schema{
			"type":       {Type: "string"},
			"fields":     {Type: "object"},
			"confidence": {Type: "number"},
			"reason":     {Type: "string"},
		},
		Required:             []string{"type", "fields", "confidence"},
		AdditionalProperties: &additional,
	}
}

// Classify builds the prompt, redacts PII, calls the provider, and
// decodes the response.
func (c *LLMClassifier) Classify(ctx context.Context, text string) (extractor.Extracted, error) {
	safe := pii.Redact(text)
	prompt := c.buildPrompt(safe)

	resp, err := c.Provider.Chat(ctx, localllm.ChatRequest{
		Messages: []localllm.Message{
			{Role: "system", Content: "Ты — ассистент, который извлекает поля из текста заявки. Отвечай только JSON-объектом со схемой {type:string, fields:object, confidence:number, reason:string}."},
			{Role: "user", Content: prompt},
		},
		Schema:      c.Schema(),
		Temperature: c.Temperature,
		MaxTokens:   512,
	})
	if err != nil {
		return extractor.Extracted{}, err
	}

	var out extractor.Extracted
	if err := json.Unmarshal([]byte(resp.Content), &out); err != nil {
		return extractor.Extracted{}, fmt.Errorf("%w: %v", localllm.ErrInvalidSchema, err)
	}
	if out.Type == "" {
		return extractor.Extracted{}, fmt.Errorf("%w: missing type", localllm.ErrInvalidSchema)
	}
	if out.Fields == nil {
		out.Fields = map[string]string{}
	}
	return out, nil
}

func (c *LLMClassifier) buildPrompt(safeText string) string {
	return fmt.Sprintf(
		"Извлеки из текста: destination_city (город), purpose (цель), "+
			"start_date (дата начала), end_date (дата окончания), "+
			"funding_source ('grant' если упомянут грант, 'budget' если бюджет), "+
			"grant_number (номер гранта, если есть). type='demo_trip' или 'other'. "+
			"Текст: %q", safeText)
}

// HeuristicClassifier is the deterministic fallback.
type HeuristicClassifier struct{}

func (h *HeuristicClassifier) Name() string { return "heuristic" }
func (h *HeuristicClassifier) Classify(_ context.Context, text string) (extractor.Extracted, error) {
	return extractor.Heuristic(text), nil
}

// ClassifyAndExtractHandler tries the primary classifier first, and
// on transient failure falls back to the heuristic. The fallback is
// logged and recorded in job_runs.outcome.
//
// Idempotency: redelivering the same event returns the same Outcome
// from the in-memory cache (bounded by MaxCacheAge).
type ClassifyAndExtractHandler struct {
	mu       sync.Mutex
	finished map[string]cachedOutcome
	primary  Classifier
	fallback Classifier
	// MaxCacheAge bounds the in-memory idempotency cache.
	MaxCacheAge time.Duration
	// ConfidenceFloor below which the outcome is parked for
	// manual_review. The 0.7 floor is documented in Backlog
	// §12.2 slot 24-25 and must NOT be silently changed.
	ConfidenceFloor float64
}

type cachedOutcome struct {
	at  time.Time
	out Outcome
}

// NewClassifyAndExtractHandler wires primary + fallback.
func NewClassifyAndExtractHandler(primary, fallback Classifier) *ClassifyAndExtractHandler {
	return &ClassifyAndExtractHandler{
		finished:        map[string]cachedOutcome{},
		primary:         primary,
		fallback:        fallback,
		MaxCacheAge:     24 * time.Hour,
		ConfidenceFloor: 0.7,
	}
}

// NewHeuristicOnlyHandler is a convenience for tests and for
// environments where no local LLM is configured.
func NewHeuristicOnlyHandler() *ClassifyAndExtractHandler {
	return NewClassifyAndExtractHandler(&HeuristicClassifier{}, &HeuristicClassifier{})
}

// Handle implements Handler.
func (h *ClassifyAndExtractHandler) Handle(ev Event) Outcome {
	return h.HandleWithContext(context.Background(), ev)
}

// HandleWithContext lets the caller pass a deadline / cancellation.
func (h *ClassifyAndExtractHandler) HandleWithContext(ctx context.Context, ev Event) Outcome {
	h.mu.Lock()
	if prior, ok := h.finished[ev.JobID]; ok && time.Since(prior.at) < h.MaxCacheAge {
		h.mu.Unlock()
		return prior.out
	}
	h.mu.Unlock()

	text, _ := ev.Extra["raw_text"].(string)

	if text == "" {
		return h.cache(ev.JobID, Outcome{
			Status: "manual_review",
			Err:    ErrPermanent,
			Detail: map[string]any{
				"reason":         "raw_text not provided in event payload",
				"primary":        providerName(h.primary),
				"fallback":       providerName(h.fallback),
				"schema_version": ev.SchemaVersion,
			},
		})
	}

	res, err := h.primary.Classify(ctx, text)
	providerUsed := providerName(h.primary)
	if err != nil {
		// Only transient errors trigger the fallback. Permanent errors
		// (invalid response, invalid schema, model not found,
		// provider failure) MUST NOT be silently masked by heuristic.
		if !isTransientProviderError(err) {
			return h.cache(ev.JobID, Outcome{
				Status: "manual_review",
				Err:    ErrPermanent,
				Detail: map[string]any{
					"reason":        "primary returned permanent error",
					"primary":       providerUsed,
					"primary_error": err.Error(),
				},
			})
		}
		res, err = h.fallback.Classify(ctx, text)
		if err != nil {
			return Outcome{
				Status: "running",
				Err:    ErrTransient,
				Detail: map[string]any{
					"reason":   "both primary and fallback failed",
					"primary":  providerUsed,
					"fallback": providerName(h.fallback),
				},
			}
		}
		providerUsed = providerName(h.fallback)
	}

	detail := map[string]any{
		"primary":        providerUsed,
		"type":           res.Type,
		"fields":         res.Fields,
		"confidence":     res.Confidence,
		"reason":         res.Reason,
		"schema_version": ev.SchemaVersion,
	}

	if res.Confidence < h.ConfidenceFloor {
		return h.cache(ev.JobID, Outcome{
			Status: "manual_review",
			Detail: detail,
		})
	}
	return h.cache(ev.JobID, Outcome{
		Status: "succeeded",
		Detail: detail,
	})
}

// isTransientProviderError returns true only for errors that a retry
// (or a fallback) might resolve. ErrInvalidSchema / ErrInvalidResponse
// / ErrModelNotFound / ErrProviderFailure are PERMANENT.
func isTransientProviderError(err error) bool {
	switch {
	case errors.Is(err, localllm.ErrUnavailable):
		return true
	case errors.Is(err, localllm.ErrTimeout):
		return true
	case errors.Is(err, localllm.ErrContextCanceled):
		return true
	default:
		return false
	}
}

func (h *ClassifyAndExtractHandler) cache(jobID string, out Outcome) Outcome {
	h.mu.Lock()
	h.finished[jobID] = cachedOutcome{at: time.Now(), out: out}
	h.mu.Unlock()
	return out
}

func providerName(c Classifier) string {
	if c == nil {
		return "none"
	}
	return c.Name()
}
