// Package localllm is the transport-only abstraction over a local LLM
// provider. It deliberately stays generic: today it ships an Ollama
// adapter, but any provider that exposes a chat-completions style API
// (Ollama native, OpenAI-compatible, llama.cpp server, vLLM, etc.) can
// be plugged in by adding another adapter that satisfies Provider.
//
// The package must NOT contain business logic. It must NOT log
// personally identifiable data. It must NOT decide what to do on
// failure — the consumer's classifier decides which errors are
// transient (retry) vs permanent (manual_review).
package localllm

import "errors"

// Sentinel errors used across providers. Adapters wrap these so the
// classifier can switch on errors.Is without caring which provider
// returned them.
//
// Semantics:
//
//   - ErrUnavailable: the remote is unreachable, timed out, or
//     returned 5xx. The classifier treats this as TRANSIENT and may
//     fall back to the heuristic. Retrying may succeed.
//
//   - ErrTimeout: the call exceeded its per-request timeout. Treated
//     as TRANSIENT, often retriable; distinct from ErrUnavailable so
//     the classifier can apply stricter fallback rules (e.g. don't
//     fall back after N consecutive timeouts to avoid a slow primary
//     blocking the queue).
//
//   - ErrInvalidResponse: the provider returned 2xx but the payload
//     is structurally wrong (malformed JSON, missing required field,
//     empty content). Treated as PERMANENT: retrying the same prompt
//     will not help. The classifier MUST NOT fall back on this
//     error — the prompt is broken.
//
//   - ErrInvalidSchema: the provider returned content that parsed as
//     JSON but did not match the expected JSON schema. Treated as
//     PERMANENT (same rationale as ErrInvalidResponse).
//
//   - ErrProviderFailure: the provider returned a structured error
//     (API-level error). Treated as PERMANENT.
//
//   - ErrModelNotFound: the requested model is not present locally.
//     Treated as PERMANENT.
//
//   - ErrContextCanceled: the caller cancelled the context. Treated
//     as TRANSIENT only if the caller is the consumer (rare); usually
//     this is a process shutdown and should not retry.
var (
	ErrUnavailable     = errors.New("localllm: endpoint unavailable")
	ErrTimeout         = errors.New("localllm: request timed out")
	ErrInvalidResponse = errors.New("localllm: invalid response")
	ErrInvalidSchema   = errors.New("localllm: response does not match schema")
	ErrProviderFailure = errors.New("localllm: provider returned an error")
	ErrModelNotFound   = errors.New("localllm: model not found")
	ErrContextCanceled = errors.New("localllm: context canceled")
)
