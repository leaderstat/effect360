-- database/migrations/004_automation_metrics.sql
--
-- Фаза 8 — счётчики «Эффективности 360» и защита от дублей уведомлений.
--
-- ЧТО ДОБАВЛЯЕТСЯ
-- ---------------
--  1. `automation_metrics` — счётчики реальных событий агентов.
--     Каждая строка — это СЧИТАНОЕ событие: «заявка проверена автоматически»,
--     «запрошено уточнение», «заявитель уведомлён», «запрошена обратная
--     связь». Счётчики — основа метрик, но НИКОГДА оценка сэкономленного
--     времени или денег: для сравнения с ручным процессом сначала
--     собирается измеримый baseline.
--
--  2. `automation_event_log` — журнал доставки событий агентам.
--     Нужен для метрики «время от смены статуса до появления уведомления»
--     и для защиты от повторной обработки одного и того же события.
--
--  3. `automation_metrics.idempotency_key` — защита от двойного учёта.

BEGIN;

-- ---------------------------------------------------------------------
-- 1. automation_metrics — счётчики реальных событий.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS automation_metrics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Заявка, к которой относится событие. NULL — для глобальных счётчиков.
    request_id uuid REFERENCES requests(id) ON DELETE CASCADE,
    -- Ключ счётчика: auto_check_passed, auto_check_needs_info,
    -- auto_check_ambiguous, applicant_notified, feedback_requested,
    -- draft_prepared, deadline_risk, manual_intervention, duplicate_prevented.
    key text NOT NULL,
    -- Величина счётчика (обычно 1).
    value integer NOT NULL DEFAULT 1 CHECK (value >= 0),
    -- Ключ идемпотентности: одно и то же событие не учитывается дважды.
    idempotency_key text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_metrics_key_idx
    ON automation_metrics(key);

CREATE INDEX IF NOT EXISTS automation_metrics_request_idx
    ON automation_metrics(request_id, created_at DESC);

COMMENT ON TABLE automation_metrics IS
    'Счётчики реальных событий агентов. Только измеренные значения — без оценок экономии.';

-- ---------------------------------------------------------------------
-- 2. automation_event_log — журнал доставки событий агентам.
--
--    `delivered_at` и `processed_at` дают метрику «время от смены статуса
--    до появления уведомления». `state` — состояние обработки:
--    pending / processed / failed.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS automation_event_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Идентификатор события (id строки outbox). Ключ идемпотентности.
    event_id text NOT NULL UNIQUE,
    -- Тема NATS.
    subject text NOT NULL,
    -- Тип работы агента.
    job_type text NOT NULL,
    -- Заявка.
    request_id uuid REFERENCES requests(id) ON DELETE CASCADE,
    -- Счётчик попыток доставки.
    delivery_attempts integer NOT NULL DEFAULT 0,
    -- Состояние: pending (доставлено, обрабатывается) / processed / failed.
    state text NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'processed', 'failed')),
    -- Момент доставки и момент обработки — источник метрики задержки.
    delivered_at timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,
    -- Ошибка обработки (без персональных данных).
    error text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_event_log_state_idx
    ON automation_event_log(state, delivered_at DESC);

CREATE INDEX IF NOT EXISTS automation_event_log_request_idx
    ON automation_event_log(request_id, created_at DESC);

COMMENT ON TABLE automation_event_log IS
    'Журнал доставки событий агентам. Источник метрики задержки уведомления и защита от дублей.';

-- ---------------------------------------------------------------------
-- 3. Счётчик «предотвращённых повторных обработок».
--
--    Событие, которое агент распознал как уже обработанное, увеличивает
--    этот счётчик. Это ИЗМЕРЕННАЯ величина: сколько раз система реально
--    остановила повторную обработку.
-- ---------------------------------------------------------------------
INSERT INTO automation_metrics (request_id, key, value, idempotency_key)
VALUES (NULL, 'duplicate_prevented', 0, 'counter:duplicate_prevented')
ON CONFLICT (idempotency_key) DO NOTHING;

COMMIT;
