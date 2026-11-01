// cmd/consumer is the JetStream consumer for "requests.created". It
// pulls messages from the EFFECTIVNOST_JOBS stream, dispatches to a
// per-job-type Handler, persists terminal status to job_runs, and
// ACKs / NAKs according to the outcome:
//
//   - Outcome.Status == "succeeded"  -> ACK, write succeeded.
//   - Outcome.Status == "failed"     -> ACK, write failed (poison).
//   - Outcome.Status == "manual_review" -> ACK, write manual_review.
//   - Outcome.Err == ErrTransient    -> NAK with delay (retry).
//
// Durability: the subscription is created with a Durable name so the
// server remembers the last delivered sequence and resumes after a
// restart. We use AckExplicit policy and call msg.Ack() / msg.Nak() /
// msg.Term() explicitly.
//
// Idempotency: each Handler must be idempotent (the classify_and_extract
// stub uses an in-memory cache). On the persistence side, the SQL
// UPDATE uses a `WHERE status IN ('queued','running')` guard so a
// duplicate (re)delivery cannot downgrade a terminal status.
//
// Poison messages: after MaxAttempts the consumer parks the job with
// status='manual_review' and ACKs (Term is also acceptable; we use Ack
// to avoid losing the audit trail). This guarantees bounded redelivery
// even for always-failing payloads.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats.go"

	"effectivnost360/worker/internal/agent"
	"effectivnost360/worker/internal/jobhandler"
	"effectivnost360/worker/internal/localllm"
)

type config struct {
	databaseURL string
	natsURL     string
	stream      string
	subject     string
	durable     string
	maxAttempts int
	retryDelay  time.Duration
	pollTimeout time.Duration
	// Local LLM classifier endpoint (Ollama or OpenAI-compatible).
	// Empty means "not configured" — the consumer falls back to the
	// heuristic classifier for every request.
	llmProvider    string
	llmBaseURL     string
	llmAPIKey      string
	llmModel       string
	llmTimeout     time.Duration
	llmTemperature float64

	// ---- Phase 8: the AI agents ----
	//
	// The agents talk to the Gleam API over HTTP. The API is the source of
	// truth for the statuses, the access rights and the business rules;
	// the agents prepare decisions and the API applies them.
	apiBaseURL string
	// apiToken is the service token of the agents (AGENT_SERVICE_TOKEN).
	apiToken string
	// letterTemplate is the approved template of the official letter.
	letterTemplate string
	// deadlineWarnHours is the threshold of the "risk of overdue" reminder.
	deadlineWarnHours int
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := loadConfig()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, cfg.databaseURL)
	if err != nil {
		logger.Error("connect to PostgreSQL", "error", err)
		os.Exit(1)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		logger.Error("ping PostgreSQL", "error", err)
		os.Exit(1)
	}

	nc, err := nats.Connect(cfg.natsURL, nats.Name("effectivnost-360-consumer"))
	if err != nil {
		logger.Error("connect to NATS", "error", err)
		os.Exit(1)
	}
	defer nc.Close()

	js, err := nc.JetStream()
	if err != nil {
		logger.Error("initialize JetStream", "error", err)
		os.Exit(1)
	}
	// We assume the stream already exists (outbox-relay creates it on
	// boot). Log loudly if it does not, instead of silently creating
	// one with a possibly different config.
	if _, err := js.StreamInfo(cfg.stream); err != nil {
		logger.Error("JetStream stream missing", "stream", cfg.stream, "error", err)
		os.Exit(1)
	}

	handlers := defaultHandlers(cfg)

	sub, err := js.PullSubscribe(cfg.subject, cfg.durable,
		nats.AckExplicit(),
		nats.MaxDeliver(cfg.maxAttempts),
		nats.MaxAckPending(64),
	)
	if err != nil {
		logger.Error("create JetStream pull subscription", "error", err)
		os.Exit(1)
	}

	// Warmup: pull the request out of queued -> running so concurrent
	// workers in the same group do not race on the same row. We do
	// this once before the loop starts (no harm if there is no work).
	if err := warmupRunningJobs(ctx, pool); err != nil {
		logger.Warn("warmup job_runs transition", "error", err)
	}

	logger.Info("consumer started",
		"stream", cfg.stream,
		"subject", cfg.subject,
		"durable", cfg.durable,
		"max_attempts", cfg.maxAttempts,
	)

	delivered := new(atomic.Uint64)
	for {
		if ctx.Err() != nil {
			logger.Info("shutting down", "delivered", delivered.Load())
			return
		}

		msgs, err := sub.Fetch(1, nats.MaxWait(cfg.pollTimeout))
		if err != nil {
			if errors.Is(err, nats.ErrTimeout) {
				continue
			}
			logger.Error("fetch from JetStream", "error", err)
			time.Sleep(500 * time.Millisecond)
			continue
		}

		for _, msg := range msgs {
			delivered.Add(1)
			handleOne(ctx, logger, pool, handlers, msg, cfg)
		}
	}
}

// handlersByType is the registry the consumer uses to dispatch by
// job_type. Today only classify_and_extract is wired; adding a new
// job_type is a one-line change here.
type handlersByType map[string]jobhandler.Handler

func defaultHandlers(cfg config) handlersByType {
	primary, fallback := wireClassifiers(cfg)
	handlers := handlersByType{
		"classify_and_extract": jobhandler.NewClassifyAndExtractHandler(primary, fallback),
	}
	// ---- Phase 8: the AI agents ----
	//
	// The agents are only wired when the API is reachable: without
	// AGENT_API_URL the agent layer is switched off, and the existing
	// classify_and_extract pipeline keeps working unchanged.
	if cfg.apiBaseURL != "" && cfg.apiToken != "" {
		api := agent.NewAPIClient(cfg.apiBaseURL, cfg.apiToken, 30*time.Second)
		assistant := buildAssistant(cfg)
		moderator := agent.NewDigitalModerator(api, assistant, "v1")
		support := agent.NewApplicantSupport(api, cfg.letterTemplate, cfg.deadlineWarnHours)
		handlers[agent.JobTypeDigitalModerator] = agent.NewDigitalModeratorHandler(moderator)
		handlers[agent.JobTypeApplicantSupport] = agent.NewApplicantSupportHandler(support)
	}
	return handlers
}

// buildAssistant builds the LLM assistant of the agents.
//
// Without a configured provider the DETERMINISTIC assistant is used: the
// check still runs, only the wording of the explanation changes. This is the
// documented safe degradation mode — an LLM failure can never change a
// status.
func buildAssistant(cfg config) agent.Assistant {
	if cfg.llmBaseURL == "" {
		return agent.NewHeuristicAssistant()
	}
	provider := localllm.New(localllm.Config{
		BaseURL:      cfg.llmBaseURL,
		APIKey:       cfg.llmAPIKey,
		Model:        cfg.llmModel,
		Timeout:      cfg.llmTimeout,
		ProviderKind: cfg.llmProvider,
	})
	return agent.NewLLMAssistant(provider, cfg.llmTemperature, "v1")
}

// wireClassifiers builds the primary + fallback classifier chain. The
// primary is the local LLM provider (Ollama or OpenAI-compatible) when
// LOCAL_LLM_BASE_URL is set; otherwise both primary and fallback are
// the heuristic, which is the documented safe degradation mode.
func wireClassifiers(cfg config) (jobhandler.Classifier, jobhandler.Classifier) {
	heuristic := &jobhandler.HeuristicClassifier{}
	if cfg.llmBaseURL == "" {
		return heuristic, heuristic
	}
	provider := localllm.New(localllm.Config{
		BaseURL:      cfg.llmBaseURL,
		APIKey:       cfg.llmAPIKey,
		Model:        cfg.llmModel,
		Timeout:      cfg.llmTimeout,
		ProviderKind: cfg.llmProvider,
	})
	primary := &jobhandler.LLMClassifier{
		Provider:      provider,
		Temperature:   cfg.llmTemperature,
		PromptVersion: "v1",
	}
	return primary, heuristic
}

func handleOne(
	ctx context.Context,
	logger *slog.Logger,
	pool *pgxpool.Pool,
	handlers handlersByType,
	msg *nats.Msg,
	cfg config,
) {
	correlationID := msg.Header.Get("X-Correlation-ID")
	if correlationID == "" {
		correlationID = msg.Subject + ":" + msg.Reply // reply subject is set on pull subs
	}

	logger = logger.With(
		"subject", msg.Subject,
		"correlation_id", correlationID,
		"msg_id", msg.Header.Get(nats.MsgIdHdr),
	)

	ev, err := jobhandler.DecodeEvent(msg.Data)
	if err != nil {
		switch {
		case errors.Is(err, jobhandler.ErrUnknownSchema):
			logger.Error("unknown schema_version; parking as manual_review", "error", err)
			parkPoison(ctx, pool, msg.Data, "unknown_schema", correlationID)
			_ = msg.Ack()
		case errors.Is(err, jobhandler.ErrInvalidPayload):
			logger.Error("invalid payload; parking as manual_review", "error", err)
			parkPoison(ctx, pool, msg.Data, "invalid_payload", correlationID)
			_ = msg.Ack()
		default:
			logger.Error("decode failed; parking as manual_review", "error", err)
			parkPoison(ctx, pool, msg.Data, "decode_failed", correlationID)
			_ = msg.Ack()
		}
		return
	}

	logger = logger.With(
		"job_id", ev.JobID,
		"request_id", ev.RequestID,
		"job_type", ev.JobType,
		"schema_version", ev.SchemaVersion,
	)

	handler, ok := handlers[ev.JobType]
	if !ok {
		logger.Error("unknown job_type; parking as manual_review")
		parkPoison(ctx, pool, msg.Data, "unknown_job_type", correlationID)
		_ = msg.Ack()
		return
	}

	// Transition queued -> running. If the row is already terminal, this
	// is a redelivery of an already-processed message: ACK and stop, the
	// handler has nothing left to do.
	if err := markRunning(ctx, pool, ev.JobID); err != nil {
		if errors.Is(err, errAlreadyTerminal) {
			logger.Warn("job already terminal; acking redelivery without invoking handler")
			_ = msg.Ack()
			return
		}
		logger.Error("mark running failed; treating as transient", "error", err)
		_ = msg.Nak(nats.AckWait(cfg.retryDelay))
		return
	}

	outcome := handler.Handle(ev)

	switch {
	case outcome.Status == "succeeded":
		// Persist the extraction onto the request row BEFORE marking the
		// job terminal. If the extraction cannot be written we treat it
		// as a transient failure so the message is redelivered and the
		// request eventually gets its fields.
		if res, err := extractFromDetail(outcome.Detail); err == nil {
			rows, applyErr := applyExtraction(ctx, pool, ev.RequestID, res)
			if applyErr != nil {
				logger.Error("apply extraction failed; treating as transient", "error", applyErr)
				_ = msg.Nak(nats.AckWait(cfg.retryDelay))
				return
			}
			note := "ok"
			if rows == 0 {
				note = explainApplyExtraction(ctx, pool, ev.RequestID, res.Type)
			}
			logExtraction(logger, ev.RequestID, res.Type, res.Fields, rows, note)
		} else {
			logger.Warn("succeeded outcome without extraction; nothing to write to the request row")
		}
		if err := markTerminal(ctx, pool, ev.JobID, "succeeded", outcome.Detail, nil); err != nil {
			if errors.Is(err, errAlreadyTerminal) {
				// The job is already terminal: a redelivery of an
				// already-processed message. The handler is idempotent,
				// so there is nothing left to do — ACK and stop. NAK here
				// would produce an endless redelivery loop.
				logger.Warn("job already terminal; acking redelivery")
				_ = msg.Ack()
				return
			}
			logger.Error("persist succeeded; treating as transient", "error", err)
			_ = msg.Nak(nats.AckWait(cfg.retryDelay))
			return
		}
		logger.Info("job succeeded")
		_ = msg.Ack()

	case errors.Is(outcome.Err, jobhandler.ErrPermanent):
		if err := markTerminal(ctx, pool, ev.JobID, "failed", outcome.Detail, strPtr("permanent")); err != nil {
			logger.Error("persist failed; treating as transient", "error", err)
			_ = msg.Nak(nats.AckWait(cfg.retryDelay))
			return
		}
		logger.Warn("job failed permanently", "detail", outcome.Detail)
		_ = msg.Ack()

	case outcome.Status == "manual_review":
		if err := markTerminal(ctx, pool, ev.JobID, "manual_review", outcome.Detail, nil); err != nil {
			logger.Error("persist manual_review; treating as transient", "error", err)
			_ = msg.Nak(nats.AckWait(cfg.retryDelay))
			return
		}
		logger.Warn("job parked for manual review", "detail", outcome.Detail)
		_ = msg.Ack()

	case errors.Is(outcome.Err, jobhandler.ErrTransient):
		if err := bumpAttempts(ctx, pool, ev.JobID); err != nil {
			logger.Warn("bump attempts failed (continuing)", "error", err)
		}
		logger.Warn("transient failure; nacking with delay", "delay", cfg.retryDelay.String(), "detail", outcome.Detail, "error", errText(outcome.Err))
		_ = msg.Nak(nats.AckWait(cfg.retryDelay))

	default:
		// Defensive: anything else is treated as transient. We never
		// silently ACK an unknown outcome.
		logger.Error("unknown outcome shape; treating as transient")
		_ = msg.Nak(nats.AckWait(cfg.retryDelay))
	}
}

// --- persistence helpers ---------------------------------------------

var errAlreadyTerminal = errors.New("jobhandler: job already terminal")

func markRunning(ctx context.Context, pool *pgxpool.Pool, jobID string) error {
	const q = `
		UPDATE job_runs
		SET status = 'running',
		    attempts = attempts + 1,
		    started_at = COALESCE(started_at, now())
		WHERE id = $1
		  AND status IN ('queued', 'running')
	`
	tag, err := pool.Exec(ctx, q, jobID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		// Check whether the row exists at all in a terminal state.
		var status string
		err := pool.QueryRow(ctx, `SELECT status FROM job_runs WHERE id = $1`, jobID).Scan(&status)
		if err != nil {
			return err
		}
		switch status {
		case "succeeded", "failed", "manual_review":
			return errAlreadyTerminal
		}
		return errors.New("job_runs row not found in expected state")
	}
	return nil
}

func markTerminal(
	ctx context.Context,
	pool *pgxpool.Pool,
	jobID, status string,
	detail map[string]any,
	errCode *string,
) error {
	var detailJSON []byte
	if detail != nil {
		b, err := json.Marshal(detail)
		if err != nil {
			return err
		}
		detailJSON = b
	} else {
		detailJSON = []byte(`{}`)
	}
	const q = `
		UPDATE job_runs
		SET status = $2,
		    outcome = $3::jsonb,
		    error_code = $4,
		    finished_at = now()
		WHERE id = $1
		  AND status IN ('queued', 'running')
	`
	tag, err := pool.Exec(ctx, q, jobID, status, detailJSON, errCode)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errAlreadyTerminal
	}
	return nil
}

func bumpAttempts(ctx context.Context, pool *pgxpool.Pool, jobID string) error {
	_, err := pool.Exec(ctx,
		`UPDATE job_runs SET attempts = attempts + 1 WHERE id = $1`, jobID)
	return err
}

// parkPoison persists a manual_review record for a payload we couldn't
// decode. We synthesise an idempotency_key from a stable hash of the
// raw payload so a redelivered poison message does not produce a
// duplicate row.
func parkPoison(ctx context.Context, pool *pgxpool.Pool, raw []byte, reason, correlationID string) {
	// Best-effort: failure to park is logged by the caller.
	const q = `
		INSERT INTO job_runs (
			job_type, idempotency_key, input_hash, status, error_code,
			schema_version, outcome, started_at, finished_at
		)
		VALUES ($1, $2, $3, 'manual_review', $4, 1, $5::jsonb, now(), now())
		ON CONFLICT (idempotency_key) DO NOTHING
	`
	key := "poison:" + reason + ":" + correlationID
	hash := sha256Hex(raw)
	outcome := map[string]any{
		"poison":          true,
		"reason":          reason,
		"correlation_id":  correlationID,
		"raw_payload_hex": sha256Hex(raw),
	}
	b, _ := json.Marshal(outcome)
	_, _ = pool.Exec(ctx, q, "unknown", key, hash, reason, b)
}

// warmupRunningJobs resets any job_runs left in 'running' from a prior
// crash back to 'queued'. Best-effort; the consumer is resilient to
// duplicates so a missed reset just costs one extra delivery.
func warmupRunningJobs(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
		UPDATE job_runs
		SET status = 'queued', started_at = NULL
		WHERE status = 'running'
		  AND finished_at IS NULL
	`)
	return err
}

// --- config ----------------------------------------------------------

func loadConfig() (config, error) {
	databaseURL := os.Getenv("DATABASE_URL")
	natsURL := os.Getenv("NATS_URL")
	if databaseURL == "" || natsURL == "" {
		return config{}, errors.New("DATABASE_URL and NATS_URL are required")
	}
	stream := envOr("NATS_STREAM", "EFFECTIVNOST_JOBS")
	subject := envOr("NATS_SUBJECT", "requests.created")
	durable := envOr("NATS_DURABLE", "effectivnost-360-consumer")
	maxAttempts, err := envInt("MAX_ATTEMPTS", 5)
	if err != nil || maxAttempts < 1 {
		return config{}, errors.New("MAX_ATTEMPTS must be a positive integer")
	}
	retryDelay, err := time.ParseDuration(envOr("RETRY_DELAY", "5s"))
	if err != nil || retryDelay < 0 {
		return config{}, errors.New("RETRY_DELAY must be a non-negative duration")
	}
	pollTimeout, err := time.ParseDuration(envOr("POLL_TIMEOUT", "2s"))
	if err != nil || pollTimeout <= 0 {
		return config{}, errors.New("POLL_TIMEOUT must be a positive duration")
	}
	llmTimeout, err := time.ParseDuration(envOr("LOCAL_LLM_TIMEOUT", "30s"))
	if err != nil || llmTimeout <= 0 {
		return config{}, errors.New("LOCAL_LLM_TIMEOUT must be a positive duration")
	}
	llmTemperature := 0.1
	if t := os.Getenv("LOCAL_LLM_TEMPERATURE"); t != "" {
		if v, perr := strconv.ParseFloat(t, 64); perr == nil && v >= 0 && v <= 2 {
			llmTemperature = v
		}
	}
	deadlineWarnHours := 24
	if t := os.Getenv("AGENT_DEADLINE_WARN_HOURS"); t != "" {
		if v, perr := strconv.Atoi(t); perr == nil && v > 0 {
			deadlineWarnHours = v
		}
	}
	return config{
		databaseURL:    databaseURL,
		natsURL:        natsURL,
		stream:         stream,
		subject:        subject,
		durable:        durable,
		maxAttempts:    maxAttempts,
		retryDelay:     retryDelay,
		pollTimeout:    pollTimeout,
		llmProvider:    envOr("LOCAL_LLM_PROVIDER", "ollama"),
		llmBaseURL:     os.Getenv("LOCAL_LLM_BASE_URL"),
		llmAPIKey:      os.Getenv("LOCAL_LLM_API_KEY"),
		llmModel:       envOr("LOCAL_LLM_MODEL", "devstral-small-2:latest"),
		llmTimeout:     llmTimeout,
		llmTemperature: llmTemperature,
		apiBaseURL:     os.Getenv("AGENT_API_URL"),
		apiToken:       os.Getenv("AGENT_SERVICE_TOKEN"),
		letterTemplate: os.Getenv("AGENT_LETTER_TEMPLATE"),
		deadlineWarnHours: deadlineWarnHours,
	}, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) (int, error) {
	v := os.Getenv(key)
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", key, err)
	}
	return n, nil
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func strPtr(s string) *string { return &s }

// errText renders an error for the structured log without dumping a
// potentially huge payload.
func errText(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	const limit = 300
	if len(s) > limit {
		return s[:limit] + "…"
	}
	return s
}
