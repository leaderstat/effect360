-- database/migrations/002_moderation_360.sql
--
-- Фаза 7 — закрытый CJM 360°: модерация, уведомления, официальный ответ.
--
-- ЧТО ДОБАВЛЯЕТСЯ
-- --------------
--  1. `sessions`        — рабочая замена аутентификации для v0.1: серверный
--                         токен сессии с ролью. RBAC проверяется на backend.
--  2. `moderation_queue`— назначение ответственного и срок по заявке.
--  3. `notifications`   — уведомления заявителю внутри приложения (v0.1).
--  4. `official_responses` — черновик/утверждённый официальный ответ.
--  5. `response_feedback` — обратная связь заявителя (отдельно от статуса).
--  6. `moderation_actions` — audit trail действий модератора.
--  7. Расширение `requests` — новые статусы + поля SLA.
--
-- КРИТИЧНО — НОВЫЕ СТАТУСЫ
-- -------------------------
-- Доменная модель раньше знала: draft → submitted → in_progress → returned | completed.
-- Целевой путь CJM из ТЗ:
--   Создана → Отправлена → Принята → В работе → Уточнение → Ответ готов → Завершена
--
-- Расширяем CHECK-констрейнт статусов, НЕ переименовывая существующие:
--   draft       (черновик)                — было
--   submitted   (отправлена)              — было
--   in_progress (в работе)                — было
--   returned    (требует уточнения)        — было
--   completed   (завершена)               — было
--   accepted    (принята в работу)        — НОВЫЙ: модератор взял заявку в работу
--   answer_ready(ответ подготовлен)       — НОВЫЙ: официальный ответ подготовлен
--
-- Миграция идемпотентна и безопасна для повторного применения: ALTER TABLE
-- с CHECK-констрейнтом пересоздаётся через DROP/CREATE в одной транзакции.

BEGIN;

-- ---------------------------------------------------------------------
-- 1. users: добавляем синтетическое отображаемое имя и роль-сквозные поля.
--    Email хранится шифротекстом; для демо-ролей нужен читаемый псевдоним,
--    чтобы интерфейс мог показать «кто заявитель», не раскрывая ПДн.
-- ---------------------------------------------------------------------
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS display_name text NOT NULL DEFAULT '';

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN users.display_name IS
  'Отображаемое имя для интерфейса. Для реальных пользователей — заполняется при onboarding; для DEMO — псевдоним.';
COMMENT ON COLUMN users.is_demo IS
  'TRUE для синтетических DEMO-пользователей. DEMO-данные не являются реальными ПДн.';

-- ---------------------------------------------------------------------
-- 2. sessions — серверные сессии (RBAC-база для v0.1).
--
--    Это НЕ полноценная аутентификация: токен выдаётся dev-эндпоинтом и
--    хранится в БД. Но права проверяются СЕРВЕРНО на каждом запросе по
--    (token → user → role), а не в браузере. Это закрывает требование
--    «доступ проверяется по роли и конкретному объекту на сервере»
--    в объёме, который позволяет v0.1.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sessions (
  token text PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '12 hours')
);

CREATE INDEX IF NOT EXISTS sessions_user_idx ON sessions(user_id);

COMMENT ON TABLE sessions IS
  'Серверные сессии v0.1. Токен → пользователь → роль. RBAC проверяется на backend.';

-- ---------------------------------------------------------------------
-- 3. requests: новые статусы + SLA-поля + ответственный.
-- ---------------------------------------------------------------------
ALTER TABLE requests
  ADD COLUMN IF NOT EXISTS assigned_to uuid REFERENCES users(id),
  ADD COLUMN IF NOT EXISTS due_at timestamptz,
  ADD COLUMN IF NOT EXISTS accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS in_progress_at timestamptz,
  ADD COLUMN IF NOT EXISTS answer_ready_at timestamptz,
  ADD COLUMN IF NOT EXISTS completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS clarification_requested_at timestamptz,
  ADD COLUMN IF NOT EXISTS clarification_note text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS applicant_note text NOT NULL DEFAULT '';

ALTER TABLE requests DROP CONSTRAINT IF EXISTS requests_status_check;
ALTER TABLE requests ADD CONSTRAINT requests_status_check
  CHECK (status IN (
    'draft',        -- черновик
    'submitted',    -- отправлена
    'accepted',     -- принята в работу (модератор)
    'in_progress',  -- в работе
    'returned',     -- требует уточнения
    'answer_ready', -- официальный ответ подготовлен
    'completed'     -- рассмотрение завершено
  ));

CREATE INDEX IF NOT EXISTS requests_requester_created_idx
  ON requests(requester_id, created_at DESC);
CREATE INDEX IF NOT EXISTS requests_due_idx
  ON requests(due_at) WHERE due_at IS NOT NULL;

COMMENT ON COLUMN requests.clarification_requested_at IS
  'Когда модератор запросил уточнение (переход в returned).';
COMMENT ON COLUMN requests.clarification_note IS
  'Текст запроса уточнения от модератора. Основание — отдельная ссылка на clause.';
COMMENT ON COLUMN requests.applicant_note IS
  'Ответ заявителя на запрос уточнения.';

-- ---------------------------------------------------------------------
-- 4. moderation_queue — назначение, срок, ответственный.
--    Отдельная таблица (а не колонки в requests), чтобы очередь
--    модератора фильтровалась по ответственному и сроку без JOIN.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS moderation_queue (
  request_id uuid PRIMARY KEY REFERENCES requests(id) ON DELETE CASCADE,
  assignee_id uuid REFERENCES users(id),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  due_at timestamptz,
  priority integer NOT NULL DEFAULT 0 CHECK (priority >= 0),
  note text NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS moderation_queue_assignee_idx
  ON moderation_queue(assignee_id, assigned_at DESC);
CREATE INDEX IF NOT EXISTS moderation_queue_due_idx
  ON moderation_queue(due_at);

COMMENT ON TABLE moderation_queue IS
  'Очередь модерации. Назначение, срок, приоритет. Основание для фильтров кабинета.';

-- ---------------------------------------------------------------------
-- 5. notifications — уведомления заявителю внутри приложения (v0.1).
--    Периодическое обновление (polling), без WebSocket/push/email.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  request_id uuid REFERENCES requests(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN (
    'request_accepted',
    'request_in_progress',
    'clarification_requested',
    'applicant_answered',
    'answer_ready',
    'request_completed',
    'feedback_requested'
  )),
  title text NOT NULL,
  body text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz
);

CREATE INDEX IF NOT EXISTS notifications_user_created_idx
  ON notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_unread_idx
  ON notifications(user_id) WHERE read_at IS NULL;

COMMENT ON TABLE notifications IS
  'Уведомления внутри приложения. read_at IS NULL → непрочитанное.';

-- ---------------------------------------------------------------------
-- 6. official_responses — официальный ответ заявителю.
--    Статус: draft → approved. Только approved-с ответ считается
--    официальным документом; draft показывается как «проект, не подписан».
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS official_responses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'approved')),
  organization text NOT NULL DEFAULT '',
  requisites text NOT NULL DEFAULT '',
  registration_number text NOT NULL DEFAULT '',
  recipient text NOT NULL DEFAULT '',
  subject text NOT NULL DEFAULT '',
  legal_basis text NOT NULL DEFAULT '',
  decision_summary text NOT NULL DEFAULT '',
  next_steps text NOT NULL DEFAULT '',
  responsible_executor text NOT NULL DEFAULT '',
  contact_for_questions text NOT NULL DEFAULT '',
  signature_block text NOT NULL DEFAULT '',
  body text NOT NULL DEFAULT '',
  created_by uuid REFERENCES users(id),
  approved_by uuid REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz
);

CREATE UNIQUE INDEX IF NOT EXISTS official_responses_request_idx
  ON official_responses(request_id);

COMMENT ON TABLE official_responses IS
  'Официальный ответ заявителю. draft — неподписанный проект, approved — утверждённый документ.';

-- ---------------------------------------------------------------------
-- 7. response_feedback — обратная связь заявителя.
--    Отдельная сущность: удовлетворённость ответом НЕ влияет на
--    юридический статус заявки.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS response_feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  is_clear boolean NOT NULL,
  comment text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, user_id)
);

COMMENT ON TABLE response_feedback IS
  'Обратная связь заявителя по официальному ответу. Не влияет на статус заявки.';

-- ---------------------------------------------------------------------
-- 8. moderation_actions — audit trail действий модератора.
--    Append-only журнал решений: кто, что, из какого статуса в какой, почему.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS moderation_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
  actor_id uuid REFERENCES users(id),
  actor_role text NOT NULL,
  action text NOT NULL,
  from_status text,
  to_status text,
  reason text NOT NULL DEFAULT '',
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS moderation_actions_request_created_idx
  ON moderation_actions(request_id, created_at DESC);

COMMENT ON TABLE moderation_actions IS
  'Append-only audit trail действий модератора по заявке.';

COMMIT;
