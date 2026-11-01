-- database/seeds/002_rollback_demo_business_trip.sql
--
-- Откат DEMO seed.
-- Удаляет:
--   - requirements, привязанные к request_type 'Учебная поездка (DEMO)';
--   - сам request_type;
--   - clauses для regulation 'Synthetic Demo Position on Internal Travel (...)';
--   - саму regulation;
--   - логи в demo_seed_log.
--
-- ⚠️  Созданные заявки НЕ удаляются. Запросы, ссылающиеся на DEMO-тип,
--     отсоединяются от него (request_type_id -> NULL), иначе удаление типа
--     нарушает внешний ключ requests_request_type_id_fkey. Так сохраняются
--     пользовательские данные и история заявок.
--
-- Идемпотентность: каждый DELETE фильтрует по имени/title/version; повторный
-- запуск просто ничего не удаляет.

BEGIN;

-- Сначала отсоединяем заявки от DEMO-типа: FK requests_request_type_id_fkey
-- запрещает удаление типа, на который ещё ссылаются строки.
UPDATE requests
   SET request_type_id = NULL
 WHERE request_type_id IN (
     SELECT id FROM request_types WHERE name = 'Учебная поездка (DEMO)'
 );

DELETE FROM requirements
 WHERE request_type_id IN (
     SELECT id FROM request_types WHERE name = 'Учебная поездка (DEMO)'
 );

DELETE FROM request_types
 WHERE name = 'Учебная поездка (DEMO)';

DELETE FROM clauses
 WHERE regulation_id IN (
     SELECT id FROM regulations
      WHERE title = 'Synthetic Demo Position on Internal Travel (DRAFT, учебный)'
        AND version = '2026-01-01-demo'
 );

DELETE FROM regulations
 WHERE title = 'Synthetic Demo Position on Internal Travel (DRAFT, учебный)'
   AND version = '2026-01-01-demo';

DELETE FROM demo_seed_log
 WHERE seed_name = '002_seed_demo_business_trip';

COMMIT;

-- Контрольная проверка: после rollback этих строк быть не должно.
DO $$
DECLARE
    rec RECORD;
BEGIN
    SELECT
        (SELECT COUNT(*) FROM regulations
          WHERE title = 'Synthetic Demo Position on Internal Travel (DRAFT, учебный)'
            AND version = '2026-01-01-demo') AS reg_count,
        (SELECT COUNT(*) FROM request_types WHERE name = 'Учебная поездка (DEMO)') AS rt_count,
        (SELECT COUNT(*) FROM demo_seed_log
          WHERE seed_name = '002_seed_demo_business_trip') AS log_count
    INTO rec;

    IF rec.reg_count <> 0 OR rec.rt_count <> 0 OR rec.log_count <> 0 THEN
        RAISE EXCEPTION 'rollback check failed: regulation=%, request_type=%, log=%',
            rec.reg_count, rec.rt_count, rec.log_count;
    END IF;

    RAISE NOTICE '002_rollback_demo_business_trip OK: all rows removed';
END $$;
