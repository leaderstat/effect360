package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats.go"
)

type config struct {
	databaseURL  string
	natsURL      string
	stream       string
	subject      string
	pollInterval time.Duration
}

type event struct {
	id      string
	subject string
	payload []byte
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

	nc, err := nats.Connect(cfg.natsURL, nats.Name("effectivnost-360-outbox-relay"))
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
	if err := ensureStream(js, cfg.stream, cfg.subject); err != nil {
		logger.Error("ensure JetStream stream", "error", err)
		os.Exit(1)
	}

	logger.Info("outbox relay started", "stream", cfg.stream, "subject", cfg.subject)
	ticker := time.NewTicker(cfg.pollInterval)
	defer ticker.Stop()

	for {
		if ctx.Err() != nil {
			return
		}
		count, err := relayBatch(ctx, pool, js)
		if err != nil {
			logger.Error("relay batch failed", "error", err)
		} else if count > 0 {
			logger.Info("outbox events published", "count", count)
		}

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func loadConfig() (config, error) {
	databaseURL := os.Getenv("DATABASE_URL")
	natsURL := os.Getenv("NATS_URL")
	if databaseURL == "" || natsURL == "" {
		return config{}, errors.New("DATABASE_URL and NATS_URL are required")
	}
	stream := envOr("NATS_STREAM", "EFFECTIVNOST_JOBS")
	subject := envOr("NATS_SUBJECT", "requests.*")
	poll := envOr("POLL_INTERVAL", "1s")
	pollInterval, err := time.ParseDuration(poll)
	if err != nil || pollInterval < 100*time.Millisecond {
		return config{}, errors.New("POLL_INTERVAL must be a duration of at least 100ms")
	}
	return config{
		databaseURL:  databaseURL,
		natsURL:      natsURL,
		stream:       stream,
		subject:      subject,
		pollInterval: pollInterval,
	}, nil
}

func envOr(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}

func ensureStream(js nats.JetStreamContext, name, subject string) error {
	_, err := js.StreamInfo(name)
	if err == nil {
		return nil
	}
	if !errors.Is(err, nats.ErrStreamNotFound) {
		return err
	}
	_, err = js.AddStream(&nats.StreamConfig{
		Name:      name,
		Subjects:  []string{subject},
		Storage:   nats.FileStorage,
		Retention: nats.LimitsPolicy,
	})
	return err
}

func relayBatch(ctx context.Context, pool *pgxpool.Pool, js nats.JetStreamContext) (int, error) {
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)

	rows, err := tx.Query(ctx, `
		SELECT id::text, subject, payload
		FROM outbox
		WHERE published_at IS NULL AND available_at <= now()
		ORDER BY created_at
		FOR UPDATE SKIP LOCKED
		LIMIT 100
	`)
	if err != nil {
		return 0, err
	}
	events := make([]event, 0, 100)
	for rows.Next() {
		var item event
		if err := rows.Scan(&item.id, &item.subject, &item.payload); err != nil {
			rows.Close()
			return 0, err
		}
		events = append(events, item)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()

	for _, item := range events {
		if !json.Valid(item.payload) {
			return 0, errors.New("outbox contains invalid JSON payload")
		}
		if _, err := js.Publish(item.subject, item.payload, nats.MsgId(item.id)); err != nil {
			return 0, err
		}
		if _, err := tx.Exec(ctx, `
			UPDATE outbox
			SET published_at = now(), attempts = attempts + 1
			WHERE id = $1
		`, item.id); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return len(events), nil
}
