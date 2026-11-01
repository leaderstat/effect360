-- database/seeds/002_seed_demo_business_trip.sql
--
-- DEMO seed для синтетического fixture database/seeds/demo_synthetic_fixture.json.
--
-- ⚠️  ВАЖНО ⚠️
--   1. Это **SYNTHETIC / DEMO**, НЕ реальный нормативный акт. Никакой
--      юридической силы не имеет. Не использовать в production.
--   2. Условное требование grant_number применяется только когда
--      funding_source == 'grant'. Полнота проверяется в Gleam API
--      (см. docs/Backlog.md §12.2).
--   3. request_type остаётся `enabled = true` (DEMO-режим), чтобы сценарий
--      можно было пройти вручную. Синтетическая природа сохранена явно:
--      суффикс "(DEMO)" в названии, предупреждение в description и флаг
--      'demo_only' = true в fields_schema. В production такой тип включать
--      нельзя.
--
-- Требования к запуску:
--   - Применить database/migrations/001_initial.sql (PostgreSQL 16, pgcrypto).
--   - Запускать от имени пользователя, у которого есть CREATE/INSERT
--     на схеме, созданной 001_initial.sql.
--
-- Идемпотентность:
--   - ON CONFLICT DO NOTHING по UNIQUE-ограничениям из 001_initial.sql:
--       regulations(title, version)
--       clauses(regulation_id, number)
--       requirements(request_type_id, field_name, clause_id)
--     Повторный запуск безопасен и не дублирует записи.
--   - Каждый запуск пишет строку в SQL-only таблицу `demo_seed_log`
--     (создаётся на лету через CREATE TABLE IF NOT EXISTS, см. ниже)
--     чтобы CI мог подтвердить факт выполнения.
--
-- Откат:
--   BEGIN;
--     DELETE FROM requirements WHERE ...;
--     DELETE FROM request_types WHERE ...;
--     DELETE FROM clauses WHERE regulation_id IN (...);
--     DELETE FROM regulations WHERE ...;
--     DELETE FROM demo_seed_log WHERE seed_name = '002_seed_demo_business_trip';
--   COMMIT;
--   Либо одной командой, вызвав database/seeds/002_rollback_demo_business_trip.sql.

BEGIN;

-- 1. Создаём лог-таблицу для аудита (только для этого seed; не миграция).
CREATE TABLE IF NOT EXISTS demo_seed_log (
    id           bigserial PRIMARY KEY,
    seed_name    text NOT NULL,
    regulation_id uuid,
    request_type_id uuid,
    inserted_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO demo_seed_log (seed_name)
VALUES ('002_seed_demo_business_trip');

-- 2. Regulation (UNIQUE по title, version).
INSERT INTO regulations (title, version, status, source_file_key)
VALUES (
    'Synthetic Demo Position on Internal Travel (DRAFT, учебный)',
    '2026-01-01-demo',
    'draft',  -- 'approved' присваивается администратором отдельно
    'database/seeds/demo_synthetic_fixture.json'
)
ON CONFLICT (title, version) DO NOTHING
RETURNING id;

-- Если уже существует — получим id через SELECT.
DO $$
DECLARE
    reg_id uuid;
    rt_id  uuid;
    cl_id  uuid;
BEGIN
    SELECT id INTO reg_id
        FROM regulations
        WHERE title = 'Synthetic Demo Position on Internal Travel (DRAFT, учебный)'
          AND version = '2026-01-01-demo';

    IF reg_id IS NULL THEN
        RAISE EXCEPTION 'regulation not found after insert';
    END IF;

    -- 3. Clauses (UNIQUE по regulation_id, number). 6 пунктов.
    INSERT INTO clauses (regulation_id, number, text) VALUES
        (reg_id, '1', 'Работник направляется в учебную поездку по решению руководителя подразделения на основании служебного задания.'),
        (reg_id, '2', 'Срок учебной поездки устанавливает работодатель с учётом объёма задания и не может превышать сорока рабочих дней.'),
        (reg_id, '3', 'В задании указываются город и место назначения, цель поездки и планируемые даты начала и окончания.'),
        (reg_id, '4', 'Источник финансирования учебной поездки определяется при направлении. Если источником является грант, в задании указывается номер гранта.'),
        (reg_id, '5', 'Работнику выдаётся аванс на оплату расходов по учебной поездке в пределах утверждённой сметы.'),
        (reg_id, '6', 'По окончании учебной поездки работник представляет краткий отчёт и подтверждающие документы в течение трёх рабочих дней.')
    ON CONFLICT (regulation_id, number) DO NOTHING;

    -- 4. Request type (UNIQUE по name).
    --
    -- Тип ВКЛЮЧЁН (enabled = true), чтобы DEMO-сценарий можно было
    -- пройти вручную в интерфейсе. Синтетическая природа сохранена явно:
    --   - в названии есть суффикс "(DEMO)";
    --   - в description — предупреждение «не для production»;
    --   - в fields_schema стоит флаг 'demo_only' = true.
    --
    -- Юридически неподтверждённые типы (например «Служебная командировка»)
    -- так НЕ включаются: они остаются enabled = false до юридической
    -- сверки цитат по первоисточнику.
    INSERT INTO request_types (
        name, description, regulation_id, fields_schema, enabled
    ) VALUES (
        'Учебная поездка (DEMO)',
        'Synthetic DEMO request type. Not for production use.',
        reg_id,
        jsonb_build_object(
            'fields', jsonb_build_array(
                'destination_city', 'purpose', 'start_date', 'end_date',
                'funding_source', 'grant_number', 'approver_id'
            ),
            'conditional', jsonb_build_object(
                'grant_number', jsonb_build_object(
                    'when', jsonb_build_object('funding_source', 'grant'),
                    'required', true
                )
            ),
            -- classifier_type maps the classifier output ("demo_trip") onto
            -- this request type. The Go consumer uses it to attach the
            -- request type to a classified request; without it the request
            -- type can never be resolved and the completeness gate has no
            -- requirements to check. See cmd/consumer/apply_extraction.go.
            'classifier_type', 'demo_trip',
            'demo_only', true
        ),
        true  -- DEMO-режим: тип работает, но помечен как синтетический.
    )
    ON CONFLICT (name) DO NOTHING
    RETURNING id INTO rt_id;

    IF rt_id IS NULL THEN
        SELECT id INTO rt_id FROM request_types WHERE name = 'Учебная поездка (DEMO)';
    END IF;

    -- ON CONFLICT DO NOTHING не меняет существующую строку, поэтому
    -- отдельно синхронизируем признак DEMO-режима и описание типа.
    UPDATE request_types
       SET enabled = true,
           description = 'Synthetic DEMO request type. Not for production use.',
           fields_schema = fields_schema
                          || jsonb_build_object('demo_only', true)
      WHERE id = rt_id
        AND (enabled IS DISTINCT FROM true
             OR description IS DISTINCT FROM 'Synthetic DEMO request type. Not for production use.'
             OR (fields_schema -> 'demo_only') IS DISTINCT FROM 'true'::jsonb);

    -- 5. Requirements (UNIQUE по request_type_id, field_name, clause_id). 7 требований.
    --    clause_id: ищем по (regulation_id, number) — id подставляется подзапросом.
    INSERT INTO requirements (request_type_id, field_name, required, condition, clause_id, quote, approved_at)
    SELECT
        rt_id, v.field_name, v.required,
        CASE WHEN v.condition IS NULL THEN NULL
             ELSE jsonb_build_object('expression', v.condition) END,
        c.id,
        v.quote,
        NULL  -- approved_at = NULL до утверждения администратором
    FROM (VALUES
        ('destination_city', true, NULL, '3',
         'город и место назначения, цель поездки'),
        ('purpose',          true, NULL, '3',
         'цель поездки и планируемые даты начала и окончания'),
        ('start_date',       true, NULL, '3',
         'планируемые даты начала и окончания'),
        ('end_date',         true, NULL, '2',
         'Срок учебной поездки устанавливает работодатель'),
        ('funding_source',   true, NULL, '4',
         'Источник финансирования учебной поездки определяется при направлении'),
        ('grant_number',     false, 'required if funding_source == ''grant''', '4',
         'Если источником является грант, в задании указывается номер гранта'),
        ('approver_id',      true, NULL, '1',
         'по решению руководителя подразделения')
    ) AS v(field_name, required, condition, clause_number, quote)
    JOIN clauses c
      ON c.regulation_id = reg_id
     AND c.number = v.clause_number
    ON CONFLICT (request_type_id, field_name, clause_id) DO NOTHING;

    -- 6. Финальный лог: фиксируем id'шники для отладки.
    UPDATE demo_seed_log
       SET regulation_id = reg_id,
           request_type_id = rt_id
     WHERE seed_name = '002_seed_demo_business_trip'
       AND inserted_at = (
           SELECT MAX(inserted_at) FROM demo_seed_log
            WHERE seed_name = '002_seed_demo_business_trip'
       );

    RAISE NOTICE '002_seed_demo_business_trip: regulation_id=%, request_type_id=%', reg_id, rt_id;
END $$;

COMMIT;

-- 7. Контрольная проверка для CI.
DO $$
DECLARE
    rec RECORD;
BEGIN
    SELECT
        (SELECT COUNT(*) FROM clauses WHERE regulation_id IN (
            SELECT id FROM regulations
            WHERE title = 'Synthetic Demo Position on Internal Travel (DRAFT, учебный)'
              AND version = '2026-01-01-demo'
        )) AS clauses_count,
        (SELECT COUNT(*) FROM request_types WHERE name = 'Учебная поездка (DEMO)') AS rt_count,
        (SELECT COUNT(*) FROM requirements WHERE request_type_id IN (
            SELECT id FROM request_types WHERE name = 'Учебная поездка (DEMO)'
        )) AS req_count,
        (SELECT enabled FROM request_types WHERE name = 'Учебная поездка (DEMO)') AS rt_enabled
    INTO rec;

    IF rec.clauses_count <> 6 THEN
        RAISE EXCEPTION 'demo seed check failed: expected 6 clauses, got %', rec.clauses_count;
    END IF;
    IF rec.rt_count <> 1 THEN
        RAISE EXCEPTION 'demo seed check failed: expected 1 request_type, got %', rec.rt_count;
    END IF;
    IF rec.req_count <> 7 THEN
        RAISE EXCEPTION 'demo seed check failed: expected 7 requirements, got %', rec.req_count;
    END IF;
    IF rec.rt_enabled IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'demo seed check failed: request_type must be enabled in demo mode (enabled=true), got %', rec.rt_enabled;
    END IF;

    RAISE NOTICE '002_seed_demo_business_trip OK: clauses=%, request_types=%, requirements=%, enabled=%',
        rec.clauses_count, rec.rt_count, rec.req_count, rec.rt_enabled;
END $$;
