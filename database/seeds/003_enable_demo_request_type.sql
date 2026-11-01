-- database/seeds/003_enable_demo_request_type.sql
--
-- ЯВНОЕ РАЗРЕШЕНИЕ на включение DEMO-типа заявки — отдельным шагом.
--
-- ⚠️  ВАЖНО ⚠️
--   1. Это **SYNTHETIC / DEMO**, НЕ реальный нормативный акт. Никакой
--      юридической силы не имеет. Не использовать в production.
--   2. `002_seed_demo_business_trip.sql` намеренно оставляет
--      `request_types.enabled = false`. Это — контрольная маркировка:
--      пока администратор явно не включил тип, ни один запрос не может
--      быть классифицирован как этот тип, а completeness не может
--      найти его требования.
--   3. Этот файл — ТОЧКА ВКЛЮЧЕНИЯ для dev-стенда. Он должен
--      применяться вручную, отдельной командой, и только на
--      dev-окружении. В production он НЕ применяется.
--
-- Зачем это нужно
-- ---------------
-- Go-consumer классифицирует свободный текст и возвращает тип
-- ("demo_trip"). Он привязывает request_type к заявке по
-- `fields_schema->>'classifier_type'` (см.
-- services/worker/cmd/consumer/apply_extraction.go). Условие
-- `rt.enabled = true` там обязательна: нельзя молча привязать
-- неутверждённое положение к заявке.
--
-- Включение DEMO-типа нужно для того, чтобы полный демо-сценарий A
-- (текст → классификация → извлечение → completeness → отправка)
-- работал на dev-стенде. Отключение — обратный UPDATE (см. ниже).
--
-- Идемпотентность: UPDATE, без INSERT — повторный запуск безопасен.
--
-- Откат:
--   UPDATE request_types SET enabled = false
--    WHERE name = 'Учебная поездка (DEMO)';

BEGIN;

UPDATE request_types
   SET enabled = true
 WHERE name = 'Учебная поездка (DEMO)'
   AND fields_schema->>'classifier_type' = 'demo_trip'
   AND fields_schema->>'demo_only' = 'true';

-- Контрольная проверка: должно быть ровно одно включённое DEMO-типа.
DO $$
DECLARE
    enabled_count integer;
    classifier_ok boolean;
BEGIN
    SELECT count(*),
           bool_and(fields_schema->>'classifier_type' = 'demo_trip')
      INTO enabled_count, classifier_ok
      FROM request_types
     WHERE name = 'Учебная поездка (DEMO)'
       AND enabled = true;

    IF enabled_count <> 1 THEN
        RAISE EXCEPTION
            '003_enable_demo_request_type: expected 1 enabled DEMO request_type, got %',
            enabled_count;
    END IF;
    IF classifier_ok IS DISTINCT FROM true THEN
        RAISE EXCEPTION
            '003_enable_demo_request_type: classifier_type must be demo_trip';
    END IF;

    RAISE NOTICE '003_enable_demo_request_type OK: enabled DEMO request_type with classifier_type=demo_trip';
END $$;

COMMIT;
