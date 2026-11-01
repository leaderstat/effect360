-- database/migrations/003_automation_agents.sql
--
-- Фаза 8 — режим автоматизации и ИИ-агенты «Эффективность 360».
--
-- ЧТО ДОБАВЛЯЕТСЯ
-- ---------------
--  1. `automation_settings`      — режим автоматизации (manual / confirm / auto),
--                                 хранится в PostgreSQL и проверяется на backend.
--                                 По умолчанию — `confirm`.
--  2. `agent_checks`             — результат проверки заявки цифровым модератором
--                                 (детерминированная проверка + помощь LLM).
--  3. `automation_actions`       — журнал автоматических действий: причина,
--                                 правило, версия правила, источник события,
--                                 инициатор (system / moderator).
--  4. `agent_exceptions`         — очередь «Требуется решение человека».
--  5. `agent_tasks`              — задачи/напоминания модератору (риск просрочки).
--  6. `agent_drafts`             — проекты официальных ответов и карточки результата
--                                 («Что решено / Почему / Что дальше / Сроки»).
--
-- КРИТИЧНО — ГРАНИЦЫ АВТОМАТИЗАЦИИ
-- ----------------------------------
-- Автоматический режим НЕ даёт агенту права менять статус напрямую.
-- Агент готовит РЕШЕНИЕ (решение + переход + причину + правило), а переход
-- применяет Gleam-доменный сервис `moderation.apply_transition` — тот же
-- путь, что и для человека. Юридически значимые переходы (`answer_ready`,
-- `completed`) в автоматическом режиме запрещены: они требуют человека.
--
-- ЗАПРЕТ НА ДУБЛИ И БЕСКОНЕЧНЫЕ ЦИКЛЫ
-- -------------------------------------
--  * `agent_checks.request_id` UNIQUE — один результат проверки на заявку;
--    повторная доставка события обновляет существующую строку, а не создаёт новую.
--  * `automation_actions.idempotency_key` UNIQUE — повторное действие с тем же
--    ключом отбрасывается на уровне БД (ON CONFLICT DO NOTHING).
--  * `agent_exceptions.request_id, kind` UNIQUE — одна и та же проблема не
--    попадает в очередь дважды.

BEGIN;

-- ---------------------------------------------------------------------
-- 1. automation_settings — режим автоматизации.
--
--    Настройка глобальная для сервиса (один кабинет модератора), поэтому
--    таблица содержит одну строку-синглтон с фиксированным id = 1.
--    `scope` оставлен как текстовое поле для будущего расширения
--    (например, разные режимы для разных типов заявок), но сейчас всегда
--    'global' — так режим читается и проверяется сервером одинаково.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS automation_settings (
    id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    scope text NOT NULL DEFAULT 'global' CHECK (scope IN ('global')),
    mode text NOT NULL DEFAULT 'confirm'
        CHECK (mode IN ('manual', 'confirm', 'auto')),
    -- Версия правил автоматизации. Фиксируется в каждом автоматическом
    -- действии, чтобы можно было объяснить, ПОЧЕМУ переход состоялся.
    rules_version text NOT NULL DEFAULT 'v1',
    -- Кто и когда изменил режим.
    updated_by uuid REFERENCES users(id),
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- Снимок режима на момент включения автоматизации.
    auto_enabled_at timestamptz,
    auto_enabled_by uuid REFERENCES users(id)
);

COMMENT ON TABLE automation_settings IS
    'Режим автоматизации. Синглтон (id=1). По умолчанию confirm — агент готовит переход, модератор утверждает.';

COMMENT ON COLUMN automation_settings.mode IS
    'manual — агент только анализирует; confirm — агент готовит, модератор утверждает; auto — агент сам выполняет только разрешённые обратимые переходы.';

COMMENT ON COLUMN automation_settings.rules_version IS
    'Версия правил автоматизации. Пишется в каждое автоматическое действие.';

-- Синглтон-строка по умолчанию: режим «с подтверждением».
INSERT INTO automation_settings (id, scope, mode, rules_version)
VALUES (1, 'global', 'confirm', 'v1')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. agent_checks — результат проверки заявки цифровым модератором.
--
--    Одна строка на заявку (UNIQUE request_id) — это и защита от дублей
--    при повторной доставке события, и «индикатор Проверено автоматически»
--    в интерфейсе.
--
--    `result`:
--      passed     — проверка пройдена, заявка соответствует требованиям;
--      needs_info — данных недостаточно, сформирован запрос уточнения;
--      ambiguous  — обнаружено противоречие или неопределённость, нужен человек;
--      error      — проверка не завершилась (например, LLM недоступен);
--      skipped    — автоматизация выключена или режим не допускает действий.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agent_checks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id uuid NOT NULL UNIQUE REFERENCES requests(id) ON DELETE CASCADE,
    result text NOT NULL CHECK (result IN (
        'passed', 'needs_info', 'ambiguous', 'error', 'skipped'
    )),
    -- Что именно проверяли (список проверок и их результат).
    checks jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- Найденные проблемы: список {field, reason, clause_id, quote}.
    problems jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- Предложенные действия: [{action, target_status, reason, rule}].
    proposed_actions jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- Запрос уточнения заявителю (текст) — заполняется при needs_info.
    clarification_request text NOT NULL DEFAULT '',
    -- Человекочитаемое объяснение результата.
    reason text NOT NULL DEFAULT '',
    -- Правило, по которому принято решение, и его версия.
    rule_code text NOT NULL DEFAULT '',
    rules_version text NOT NULL DEFAULT 'v1',
    -- Модель/промпт, если в проверке участвовал LLM (может быть пустым —
    -- детерминированная проверка LLM не требует).
    model_version text NOT NULL DEFAULT '',
    prompt_version text NOT NULL DEFAULT '',
    llm_used boolean NOT NULL DEFAULT false,
    -- Событие-источник (id сообщения/события), по которому началась проверка.
    source_event text NOT NULL DEFAULT '',
    -- Кто инициировал: system (агент) / moderator (человек).
    initiated_by text NOT NULL DEFAULT 'system'
        CHECK (initiated_by IN ('system', 'moderator')),
    -- Длительность детерминированной проверки в миллисекундах.
    duration_ms integer NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS agent_checks_result_created_idx
    ON agent_checks(result, created_at DESC);

COMMENT ON TABLE agent_checks IS
    'Результат проверки заявки цифровым модератором. UNIQUE(request_id) — защита от дублей при повторной доставке.';

COMMENT ON COLUMN agent_checks.result IS
    'passed / needs_info / ambiguous / error / skipped.';

COMMENT ON COLUMN agent_checks.initiated_by IS
    'system — агент; moderator — человек запустил проверку вручную.';

-- ---------------------------------------------------------------------
-- 3. automation_actions — журнал автоматических действий.
--
--    Здесь фиксируется ВСЁ, что агент предложил или выполнил: причина,
--    правило, версия правила, источник события и инициатор. Это и есть
--    «журнал автоматических действий» в интерфейсе и основа аудита.
--
--    `idempotency_key` UNIQUE: повторная доставка того же события не
--    создаёт второй переход.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS automation_actions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id uuid NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
    -- Тип действия: check (проверка), propose (предложен переход),
    -- transition (переход выполнен), clarify (запрос уточнения),
    -- escalate (передано человеку), notify (уведомление), draft (проект ответа).
    action text NOT NULL CHECK (action IN (
        'check', 'propose', 'transition', 'clarify', 'escalate',
        'notify', 'draft', 'approve', 'reject', 'recheck'
    )),
    -- Переход, к которому относится действие (если применимо).
    from_status text,
    to_status text,
    -- Человекочитаемая причина.
    reason text NOT NULL DEFAULT '',
    -- Идентификатор и версия правила, по которому принято решение.
    rule_code text NOT NULL DEFAULT '',
    rules_version text NOT NULL DEFAULT 'v1',
    -- Источник события (subject + id события/сообщения).
    source_event text NOT NULL DEFAULT '',
    -- Инициатор: system (агент) / moderator (человек).
    initiated_by text NOT NULL DEFAULT 'system'
        CHECK (initiated_by IN ('system', 'moderator')),
    -- Режим автоматизации на момент действия.
    automation_mode text NOT NULL DEFAULT 'confirm'
        CHECK (automation_mode IN ('manual', 'confirm', 'auto')),
    -- Результат действия: applied / proposed / rejected / skipped / failed.
    outcome text NOT NULL DEFAULT 'applied'
        CHECK (outcome IN ('applied', 'proposed', 'rejected', 'skipped', 'failed')),
    -- Дополнительные детали (JSONB): id задания, id проверки и т.п.
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Ключ идемпотентности — защита от повторного выполнения.
    idempotency_key text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS automation_actions_request_created_idx
    ON automation_actions(request_id, created_at DESC);

CREATE INDEX IF NOT EXISTS automation_actions_created_idx
    ON automation_actions(created_at DESC);

CREATE INDEX IF NOT EXISTS automation_actions_action_idx
    ON automation_actions(action, created_at DESC);

COMMENT ON TABLE automation_actions IS
    'Журнал автоматических действий. Причина, правило, версия правила, источник события, инициатор.';

COMMENT ON COLUMN automation_actions.idempotency_key IS
    'Ключ идемпотентности. UNIQUE — повторная доставка события не создаёт второй переход.';

-- ---------------------------------------------------------------------
-- 4. agent_exceptions — очередь «Требуется решение человека».
--
--    UNIQUE(request_id, kind): одна и та же проблема не попадает в очередь
--    дважды. `status`: open (ждёт человека) / resolved (закрыта).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agent_exceptions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id uuid NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
    -- Тип исключения: ambiguous (неопределённость) / incomplete (не хватает
    -- данных) / llm_error (ошибка LLM) / rule_violation.
    kind text NOT NULL CHECK (kind IN (
        'ambiguous', 'incomplete', 'llm_error', 'rule_violation'
    )),
    -- Причина: почему заявка ушла человеку.
    reason text NOT NULL DEFAULT '',
    -- Детали (JSONB): список проблем.
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
    -- Кто разобрал исключение.
    resolved_by uuid REFERENCES users(id),
    resolved_at timestamptz,
    resolution_note text NOT NULL DEFAULT '',
    -- Кто инициировал постановку в очередь: system / moderator.
    initiated_by text NOT NULL DEFAULT 'system'
        CHECK (initiated_by IN ('system', 'moderator')),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS agent_exceptions_request_kind_idx
    ON agent_exceptions(request_id, kind);

CREATE INDEX IF NOT EXISTS agent_exceptions_open_created_idx
    ON agent_exceptions(created_at DESC) WHERE status = 'open';

COMMENT ON TABLE agent_exceptions IS
    'Очередь исключений «Требуется решение человека».';

-- ---------------------------------------------------------------------
-- 5. agent_tasks — задачи и напоминания модератору.
--
--    Агент сопровождения заявителя создаёт здесь напоминания при риске
--    просрочки (срок ожидания ответа/уточнения близок или истёк).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agent_tasks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id uuid NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
    -- Тип задачи: deadline_risk (риск просрочки) / deadline_overdue
    -- (просрочка) / clarification_pending (ждём ответ заявителя).
    kind text NOT NULL CHECK (kind IN (
        'deadline_risk', 'deadline_overdue', 'clarification_pending'
    )),
    title text NOT NULL,
    note text NOT NULL DEFAULT '',
    due_at timestamptz,
    status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'dismissed')),
    assigned_to uuid REFERENCES users(id),
    -- Ключ идемпотентности: одно напоминание на пару (заявка, вид, срок).
    idempotency_key text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS agent_tasks_open_due_idx
    ON agent_tasks(due_at) WHERE status = 'open';

CREATE INDEX IF NOT EXISTS agent_tasks_request_idx
    ON agent_tasks(request_id, created_at DESC);

COMMENT ON TABLE agent_tasks IS
    'Напоминания и задачи модератору, созданные агентом сопровождения.';

-- ---------------------------------------------------------------------
-- 6. agent_drafts — проекты официального ответа и карточки результата.
--
--    Агент В готовит ЧЕРНОВИК по утверждённому шаблону. Он не подписывает
--    и не отправляет ответ: `official_responses.status` остаётся 'draft',
--    а финальное утверждение делает уполномоченный человек.
--
--    Карточка результата «Что решено / Почему / Что дальше / Сроки».
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agent_drafts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id uuid NOT NULL REFERENCES requests(id) ON DELETE CASCADE,
    -- Тип черновика: official_response (проект письма) / result_card
    -- (карточка результата).
    kind text NOT NULL CHECK (kind IN ('official_response', 'result_card')),
    -- Текст черновика. Для result_card — JSONB с четырьмя блоками.
    content text NOT NULL DEFAULT '',
    structured jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Статус: draft (подготовлен агентом) / approved (утверждён человеком) /
    -- rejected (отклонён).
    status text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'approved', 'rejected')),
    -- Событие-источник, породившее черновик.
    source_event text NOT NULL DEFAULT '',
    idempotency_key text NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS agent_drafts_request_idx
    ON agent_drafts(request_id, created_at DESC);

COMMENT ON TABLE agent_drafts IS
    'Проекты официального ответа и карточки результата. Агент готовит — человек утверждает.';

-- ---------------------------------------------------------------------
-- 7. notifications: расширяем CHECK под новые виды уведомлений агента.
--
--    Новые kinds:
--      auto_checked         — «Проверено автоматически»
--      clarification_auto   — автоматический запрос уточнения
--      deadline_warning     — предупреждение о сроке
--      feedback_requested_auto — запрос обратной связи после завершения
--
--    CHECK-констрейнт пересоздаётся через DROP/CREATE в той же транзакции.
-- ---------------------------------------------------------------------
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;

ALTER TABLE notifications ADD CONSTRAINT notifications_kind_check
    CHECK (kind IN (
        'request_accepted',
        'request_in_progress',
        'clarification_requested',
        'applicant_answered',
        'answer_ready',
        'request_completed',
        'feedback_requested',
        'auto_checked',
        'clarification_auto',
        'deadline_warning',
        'feedback_requested_auto'
    ));

-- Защита от повторной отправки одного и того же уведомления:
-- один запрос → одно уведомление данного вида.
CREATE UNIQUE INDEX IF NOT EXISTS notifications_idempotency_idx
    ON notifications(request_id, kind)
    WHERE request_id IS NOT NULL;

COMMENT ON INDEX notifications_idempotency_idx IS
    'Запрет повторной отправки уведомления по одной заявке и виду (защита от дублей).';

-- ---------------------------------------------------------------------
-- 8. requests: пометка автоматической проверки.
--
--    `auto_checked_at` — когда заявка в последний раз прошла проверку
--    цифровым модератором. NULL → «Проверено автоматически» НЕ показывается
--    (важно: индикатор должен означать реально выполненную проверку).
-- ---------------------------------------------------------------------
ALTER TABLE requests
    ADD COLUMN IF NOT EXISTS auto_checked_at timestamptz,
    ADD COLUMN IF NOT EXISTS auto_check_result text;

COMMENT ON COLUMN requests.auto_checked_at IS
    'Время последней успешной проверки цифровым модератором. NULL — проверка не выполнялась.';

COMMENT ON COLUMN requests.auto_check_result IS
    'Результат последней проверки: passed / needs_info / ambiguous / error.';

COMMIT;
