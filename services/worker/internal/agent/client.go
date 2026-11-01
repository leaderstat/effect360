package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// APIClient talks to the Gleam API.
//
// The agents use the API instead of writing to PostgreSQL directly. That
// is deliberate: the Gleam layer owns the state machine, the access rights
// and the audit trail, and it is the only writer of the business tables.
//
// The client is intentionally thin: it does not retry, does not interpret
// business rules and does not log request bodies (they may contain
// personal data).
type APIClient struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

// NewAPIClient builds a client. A nil http.Client gets a default one with
// a sensible timeout.
func NewAPIClient(baseURL, token string, timeout time.Duration) *APIClient {
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	return &APIClient{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Token:   token,
		HTTP:    &http.Client{Timeout: timeout},
	}
}

// Request describes one API call.
type Request struct {
	Method string
	Path   string
	Body   any
}

// Do performs a request and decodes the JSON response into out.
//
// A non-2xx status is returned as an error that carries the status code,
// so the caller can distinguish "the request was refused" from "the API is
// down" (which is retryable).
func (c *APIClient) Do(ctx context.Context, req Request, out any) error {
	var body io.Reader
	if req.Body != nil {
		raw, err := json.Marshal(req.Body)
		if err != nil {
			return fmt.Errorf("%w: marshal body: %v", ErrPermanent, err)
		}
		body = bytes.NewReader(raw)
	}

	httpReq, err := http.NewRequestWithContext(ctx, req.Method, c.BaseURL+req.Path, body)
	if err != nil {
		return fmt.Errorf("%w: build request: %v", ErrPermanent, err)
	}
	httpReq.Header.Set("Accept", "application/json")
	if req.Body != nil {
		httpReq.Header.Set("Content-Type", "application/json")
	}
	if c.Token != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.HTTP.Do(httpReq)
	if err != nil {
		// The API is unreachable — this is transient.
		return fmt.Errorf("%w: api unreachable: %v", ErrTransient, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("%w: read response: %v", ErrTransient, err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &APIError{Status: resp.StatusCode, Body: truncate(string(raw), 400)}
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("%w: decode response: %v", ErrPermanent, err)
	}
	return nil
}

// APIError is returned for a non-2xx response.
type APIError struct {
	Status int
	Body   string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("api returned status %d: %s", e.Status, e.Body)
}

// Retryable reports whether the error may succeed on a retry.
//
// 5xx and 429 are transient; 4xx are permanent (the request itself is
// wrong and repeating it changes nothing).
func (e *APIError) Retryable() bool {
	return e.Status >= 500 || e.Status == 429 || e.Status == 408
}

// IsNotFound reports whether the API answered 404.
func (e *APIError) IsNotFound() bool { return e.Status == 404 }

// IsConflict reports whether the API answered 409 (illegal transition).
func (e *APIError) IsConflict() bool { return e.Status == 409 }

// truncate shortens a string for an error message.
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
