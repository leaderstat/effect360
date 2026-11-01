package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"effectivnost360/worker/internal/localllm"
	"effectivnost360/worker/internal/pii"
)

// nowMillis is the clock of the agent layer. It is a variable so the
// tests can make the duration deterministic.
var nowMillis = func() int64 { return time.Now().UnixMilli() }

// Assistant produces the auxiliary text of the agent: an explanation of
// the problem and a draft of the clarifying question.
//
// THE ASSISTANT NEVER DECIDES.
//
// The deterministic checker has already produced the result. The assistant
// may only add wording. If the LLM fails, the decision stands and only
// the explanation degrades — an LLM error can therefore never change the
// status of a request.
type Assistant interface {
	// Explain drafts a human-readable explanation of the check result.
	Explain(ctx context.Context, snap RequestSnapshot, d Decision) (string, error)
	// DraftClarification drafts the question to the applicant.
	DraftClarification(ctx context.Context, snap RequestSnapshot, d Decision) (string, error)
	// Name identifies the provider for the audit trail.
	Name() string
}

// LLMAssistant is the Assistant backed by the pluggable LLM provider.
type LLMAssistant struct {
	Provider      localllm.Provider
	Temperature   float64
	PromptVersion string
}

// NewLLMAssistant builds an assistant over the given provider.
func NewLLMAssistant(provider localllm.Provider, temperature float64, promptVersion string) *LLMAssistant {
	if promptVersion == "" {
		promptVersion = "v1"
	}
	return &LLMAssistant{
		Provider:      provider,
		Temperature:   temperature,
		PromptVersion: promptVersion,
	}
}

// Name identifies the provider and the prompt version, e.g. "ollama@v1".
func (a *LLMAssistant) Name() string {
	if a.Provider == nil {
		return "none"
	}
	return a.Provider.Name() + "@" + a.PromptVersion
}

// schema constrains the provider's output.
func (a *LLMAssistant) schema() *localllm.Schema {
	additional := false
	return &localllm.Schema{
		Type: "object",
		Properties: map[string]*localllm.Schema{
			"text": {Type: "string"},
		},
		Required:             []string{"text"},
		AdditionalProperties: &additional,
	}
}

// assistantReply is the canonical shape of the provider's answer.
type assistantReply struct {
	Text string `json:"text"`
}

// Explain drafts an explanation of the check result.
func (a *LLMAssistant) Explain(ctx context.Context, snap RequestSnapshot, d Decision) (string, error) {
	if a.Provider == nil {
		return "", fmt.Errorf("%w: no provider configured", localllm.ErrUnavailable)
	}
	// The PII boundary: the text of the request never crosses the trust
	// boundary unredacted.
	safeText := pii.Redact(snap.RawText)
	prompt := a.buildExplainPrompt(safeText, d)

	resp, err := a.Provider.Chat(ctx, localllm.ChatRequest{
		Messages: []localllm.Message{
			{
				Role:    "system",
				Content: "Ты — помощник модератора. Объясни причину замечания по заявке простыми словами. Не придумывай правовых оснований и не меняй статус. Отвечай только JSON-объектом {\"text\":string}.",
			},
			{Role: "user", Content: prompt},
		},
		Schema:      a.schema(),
		Temperature: a.Temperature,
		MaxTokens:   256,
	})
	if err != nil {
		return "", err
	}
	return a.decode(resp.Content)
}

// DraftClarification drafts the question to the applicant.
func (a *LLMAssistant) DraftClarification(ctx context.Context, snap RequestSnapshot, d Decision) (string, error) {
	if a.Provider == nil {
		return "", fmt.Errorf("%w: no provider configured", localllm.ErrUnavailable)
	}
	safeText := pii.Redact(snap.RawText)
	prompt := a.buildClarificationPrompt(safeText, d)

	resp, err := a.Provider.Chat(ctx, localllm.ChatRequest{
		Messages: []localllm.Message{
			{
				Role:    "system",
				Content: "Ты — помощник модератора. Сформулируй вежливый вопрос заявителю с перечнем недостающих сведений. Не выдумывай требований и правовых оснований. Отвечай только JSON-объектом {\"text\":string}.",
			},
			{Role: "user", Content: prompt},
		},
		Schema:      a.schema(),
		Temperature: a.Temperature,
		MaxTokens:   256,
	})
	if err != nil {
		return "", err
	}
	return a.decode(resp.Content)
}

// decode parses the provider's answer.
func (a *LLMAssistant) decode(content string) (string, error) {
	var reply assistantReply
	if err := json.Unmarshal([]byte(content), &reply); err != nil {
		return "", fmt.Errorf("%w: %v", localllm.ErrInvalidResponse, err)
	}
	if strings.TrimSpace(reply.Text) == "" {
		return "", localllm.ErrInvalidResponse
	}
	return reply.Text, nil
}

// buildExplainPrompt builds the prompt of the explanation.
func (a *LLMAssistant) buildExplainPrompt(safeText string, d Decision) string {
	var problems []string
	for _, p := range d.Problems {
		problems = append(problems, fmt.Sprintf("%s (%s)", p.FieldName, p.Reason))
	}
	return fmt.Sprintf(
		"Результат проверки заявки: %s.\nЗамечания: %s.\nТекст заявки: %q\n"+
			"Объясни заявителю, что нужно сделать. Не упоминай внутренние коды.",
		d.Result, strings.Join(problems, "; "), safeText)
}

// buildClarificationPrompt builds the prompt of the clarifying question.
func (a *LLMAssistant) buildClarificationPrompt(safeText string, d Decision) string {
	var problems []string
	for _, p := range d.Problems {
		problems = append(problems, p.FieldName)
	}
	return fmt.Sprintf(
		"Не заполнены поля: %s.\nТекст заявки: %q\n"+
			"Сформулируй один вежливый вопрос с перечнем этих полей.",
		strings.Join(problems, ", "), safeText)
}

// HeuristicAssistant is the deterministic fallback used when no LLM is
// configured.
//
// It produces a template-based explanation. It never invents anything: the
// text is built from the actual check result and the actual problems.
type HeuristicAssistant struct{}

// NewHeuristicAssistant builds the fallback assistant.
func NewHeuristicAssistant() *HeuristicAssistant { return &HeuristicAssistant{} }

// Name identifies the fallback.
func (a *HeuristicAssistant) Name() string { return "heuristic" }

// Explain builds a template explanation.
func (a *HeuristicAssistant) Explain(_ context.Context, _ RequestSnapshot, d Decision) (string, error) {
	if len(d.Problems) == 0 {
		return d.Reason, nil
	}
	var parts []string
	for _, p := range d.Problems {
		if p.Message != "" {
			parts = append(parts, p.Message)
		}
	}
	if len(parts) == 0 {
		return d.Reason, nil
	}
	return d.Reason + " " + strings.Join(parts, " "), nil
}

// DraftClarification builds a template clarifying question.
func (a *HeuristicAssistant) DraftClarification(_ context.Context, _ RequestSnapshot, d Decision) (string, error) {
	return BuildClarificationRequest(d.Problems), nil
}
