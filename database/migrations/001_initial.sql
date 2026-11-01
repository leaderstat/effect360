CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS departments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL UNIQUE,
    executor_email_ciphertext bytea,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email_ciphertext bytea NOT NULL,
    email_lookup_hash bytea NOT NULL UNIQUE,
    full_name_ciphertext bytea NOT NULL,
    role text NOT NULL CHECK (role IN ('applicant', 'executor', 'manager', 'admin')),
    department_id uuid REFERENCES departments(id),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS regulations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title text NOT NULL,
    version text NOT NULL,
    status text NOT NULL CHECK (status IN ('draft', 'approved', 'archived')),
    source_file_key text,
    approved_by uuid REFERENCES users(id),
    approved_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (title, version)
);

CREATE TABLE IF NOT EXISTS clauses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    regulation_id uuid NOT NULL REFERENCES regulations(id),
    number text NOT NULL,
    text text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (regulation_id, number)
);

CREATE TABLE IF NOT EXISTS request_types (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL UNIQUE,
    description text NOT NULL DEFAULT '',
    department_id uuid REFERENCES departments(id),
    regulation_id uuid REFERENCES regulations(id),
    fields_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
    enabled boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS requirements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_type_id uuid NOT NULL REFERENCES request_types(id),
    field_name text NOT NULL,
    required boolean NOT NULL,
    condition jsonb,
    clause_id uuid NOT NULL REFERENCES clauses(id),
    quote text NOT NULL CHECK (length(trim(quote)) > 0),
    approved_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (request_type_id, field_name, clause_id)
);

CREATE TABLE IF NOT EXISTS requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    requester_id uuid REFERENCES users(id),
    idempotency_key text NOT NULL UNIQUE CHECK (length(trim(idempotency_key)) BETWEEN 1 AND 128),
    raw_text text NOT NULL CHECK (length(trim(raw_text)) BETWEEN 1 AND 10000),
    request_type_id uuid REFERENCES request_types(id),
    fields jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'submitted', 'in_progress', 'returned', 'completed')),
    return_count integer NOT NULL DEFAULT 0 CHECK (return_count >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    submitted_at timestamptz,
    closed_at timestamptz
);

CREATE TABLE IF NOT EXISTS request_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id uuid NOT NULL REFERENCES requests(id),
    from_status text,
    to_status text NOT NULL,
    actor_id uuid REFERENCES users(id),
    actor_role text NOT NULL,
    reason_code text,
    clause_id uuid REFERENCES clauses(id),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS gaps (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    regulation_id uuid NOT NULL REFERENCES regulations(id),
    kind text NOT NULL,
    clause_id uuid REFERENCES clauses(id),
    description text NOT NULL,
    source text NOT NULL,
    status text NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('proposed', 'confirmed', 'resolved', 'rejected')),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS job_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id uuid REFERENCES requests(id),
    job_type text NOT NULL,
    idempotency_key text NOT NULL UNIQUE,
    schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version > 0),
    prompt_version text,
    model_version text,
    input_hash text NOT NULL,
    status text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'manual_review')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    outcome jsonb,
    error_code text,
    started_at timestamptz,
    finished_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS outbox (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    subject text NOT NULL,
    payload jsonb NOT NULL,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    available_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id uuid REFERENCES users(id),
    actor_role text,
    action text NOT NULL,
    object_type text NOT NULL,
    object_id uuid,
    model_version text,
    prompt_version text,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS requests_status_created_idx ON requests(status, created_at);
CREATE INDEX IF NOT EXISTS outbox_pending_idx ON outbox(available_at, created_at) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS job_runs_request_created_idx ON job_runs(request_id, created_at);
CREATE INDEX IF NOT EXISTS request_events_request_created_idx ON request_events(request_id, created_at);
