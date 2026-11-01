-- database/migrations/009_requirement_hard_stops.sql
--
-- Разбор результата анализа законодательства о командировках
-- (docs/Законодательство_о_командировках_—_статьи.md).
--
-- ЧТО ДЕЛАЕТ
-- ---------
-- 1. `requirement_hard_stops` — справочник правил, которые ЗАПРЕЩАЮТ
--    направление в служебную командировку (или требуют обязательного
--    подтверждения работодателем). Каждое правило ссылается на clause
--    (норму) и на regulatory_references (внешний НПА) — чтобы решение
--    системы было прослеживаемо до первоисточника.
--
--    Ключевое отличие от `requirements`: `requirements` отвечает на вопрос
--    «какое поле надо заполнить», а `requirement_hard_stops` — «при каком
--    значении поля заявку отправить НЕЛЬЗЯ». Обычный `missing` этого
--    не выражает: для `is_pregnant = 'true'` поле заполнено, и движок
--    completeness посчитал бы заявку полной, хотя отправка запрещена.
--
-- 2. Расширяет `request_events` полем `regulatory_ref_id` — FK на
--    `regulatory_references(id)`. Позволяет в журнале аудита увидеть,
--    на основании какого НПА было принято решение (в т.ч. блокировка).
--
-- 3. Добавляет CHECK-ограничение на `requirement_hard_stops.action`,
--    фиксируя допустимые исходы:
--      - 'block_submit'        — отправка запрещена (жёсткий стоп);
--      - 'needs_employer_review' — требуется подтверждение работодателем,
--        отправка возможна только после проверки человеком.
--
-- НЕ ДЕЛАЕТ
-- ----------
-- - Не изменяет существующие заявки, статусы и историю событий.
-- - Не включает тип заявки «Служебная командировка» (enabled = false
--   остаётся до юридической сверки цитат по первоисточнику).
-- - Не удаляет и не перезаписывает ранее применённые миграции.
--
-- ИДЕМПОТЕНТНОСТЬ
-- --------------
-- CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS,
-- ALTER TABLE ... ADD COLUMN IF NOT EXISTS. Повторный запуск безопасен.
-- Данные заполняются отдельным seed'ом (database/seeds/006_seed_hard_stops.sql).
BEGIN;

-- ---------------------------------------------------------------------
-- 1. Справочник блокирующих правил
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS requirement_hard_stops (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    request_type_id     uuid NOT NULL REFERENCES request_types(id) ON DELETE CASCADE,
    field_name          text NOT NULL,
    -- Триггер блокировки. Поддерживаемые предикаты описаны в
    -- services/api/src/effectivnost_360/completeness.gleam:
    --   "field == 'value'"  — точное строковое равенство
    --   "field != 'value'"  — значение отличается
    --   "field in 'a,b,c'" — вхождение в перечисление
    trigger_expr        text NOT NULL,
    action              text NOT NULL,
    -- Человекочитаемое объяснение блокировки (показывается в UI).
    reason              text NOT NULL,
    clause_id           uuid NOT NULL REFERENCES clauses(id) ON DELETE CASCADE,
    regulatory_ref_id   uuid REFERENCES regulatory_references(id),
    -- Создано вручную/из seed'а — для отслеживания происхождения правила.
    source_kind         text NOT NULL DEFAULT 'legislation_seed',
    created_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT requirement_hard_stops_action_check
        CHECK (action IN ('block_submit', 'needs_employer_review')),
    CONSTRAINT requirement_hard_stops_trigger_check
        CHECK (trigger_expr ~ '^[a-z_][a-z0-9_]* *(==|!=|in) *.*$'),
    CONSTRAINT requirement_hard_stops_unique
        UNIQUE (request_type_id, field_name, trigger_expr, action)
);

CREATE INDEX IF NOT EXISTS requirement_hard_stops_request_type_idx
    ON requirement_hard_stops (request_type_id);

CREATE INDEX IF NOT EXISTS requirement_hard_stops_regulatory_ref_idx
    ON requirement_hard_stops (regulatory_ref_id);

COMMENT ON TABLE requirement_hard_stops IS
    'Правила жёсткой блокировки отправки заявки и требования подтверждения работодателем, выведенные из норм ТК РФ и ПП РФ № 501.';

COMMENT ON COLUMN requirement_hard_stops.trigger_expr IS
    'Предикат срабатывания: "<field> == ''<value>''", "<field> != ''<value>''" или "<field> in ''a,b,c''".';

COMMENT ON COLUMN requirement_hard_stops.action IS
    'block_submit — отправка запрещена; needs_employer_review — требуется подтверждение работодателем.';

COMMENT ON COLUMN requirement_hard_stops.regulatory_ref_id IS
    'Внешний НПА, на основании которого принято правило (для аудита).';

-- ---------------------------------------------------------------------
-- 2. Аудит: ссылка на нормативный акт в журнале событий
-- ---------------------------------------------------------------------
ALTER TABLE request_events
    ADD COLUMN IF NOT EXISTS regulatory_ref_id uuid REFERENCES regulatory_references(id);

CREATE INDEX IF NOT EXISTS request_events_regulatory_ref_idx
    ON request_events (regulatory_ref_id);

COMMENT ON COLUMN request_events.regulatory_ref_id IS
    'НПА, на основании которого принято решение (переход статуса, блокировка отправки).';

COMMIT;
