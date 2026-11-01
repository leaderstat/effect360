-- database/seeds/004_seed_demo_users.sql
--
-- DEMO-пользователи для Фазы 7 (модерация + кабинет заявителя).
--
-- ⚠️  ВАЖНО ⚠️
--   1. Это СИНТЕТИЧЕСКИЕ данные. Никаких реальных ПДн.
--   2. Все `email_ciphertext` / `full_name_ciphertext` — это UTF-8 байты
--      плейсхолдера, а НЕ реальное шифрование (AES-GCM в v0.1 не реализован,
--      см. Backlog.md §11). Для демо-стенда этого достаточно, потому что
--      доступ к данным всё равно проходит через проверку роли на сервере.
--   3. `email_lookup_hash` — sha256 от email, как в `001_initial.sql`.
--      В PostgreSQL это `digest(<email>, 'sha256')` из расширения pgcrypto:
--      функции `sha256()` в СУБД нет, а `digest()` возвращает сразу `bytea`,
--      ровно тот тип, который ждёт колонка `users.email_lookup_hash`.
--
-- Идемпотентность: INSERT ... ON CONFLICT DO NOTHING по `email_lookup_hash`.

BEGIN;

-- --- Заявитель ---
INSERT INTO users (
  email_ciphertext,
  email_lookup_hash,
  full_name_ciphertext,
  display_name,
  role,
  is_demo
)
VALUES (
  convert_to('demo.applicant@example.invalid', 'UTF8'),
  digest('demo.applicant@example.invalid', 'sha256'),
  convert_to('Демо Заявитель', 'UTF8'),
  'Демо Заявитель',
  'applicant',
  true
)
ON CONFLICT (email_lookup_hash) DO NOTHING;

-- --- Модератор / исполнитель ---
INSERT INTO users (
  email_ciphertext,
  email_lookup_hash,
  full_name_ciphertext,
  display_name,
  role,
  is_demo
)
VALUES (
  convert_to('demo.moderator@example.invalid', 'UTF8'),
  digest('demo.moderator@example.invalid', 'sha256'),
  convert_to('Демо Модератор', 'UTF8'),
  'Демо Модератор',
  'executor',
  true
)
ON CONFLICT (email_lookup_hash) DO NOTHING;

-- --- Руководитель (роль manager — только агрегаты, без имён заявителей) ---
INSERT INTO users (
  email_ciphertext,
  email_lookup_hash,
  full_name_ciphertext,
  display_name,
  role,
  is_demo
)
VALUES (
  convert_to('demo.manager@example.invalid', 'UTF8'),
  digest('demo.manager@example.invalid', 'sha256'),
  convert_to('Демо Руководитель', 'UTF8'),
  'Демо Руководитель',
  'manager',
  true
)
ON CONFLICT (email_lookup_hash) DO NOTHING;

-- --- Контрольная проверка: ожидаем ровно по одному DEMO-пользователю каждой роли ---
DO $$
DECLARE
  applicant_count integer;
  executor_count integer;
  manager_count integer;
BEGIN
  SELECT count(*) INTO applicant_count
    FROM users WHERE role = 'applicant' AND is_demo = true;
  SELECT count(*) INTO executor_count
    FROM users WHERE role = 'executor' AND is_demo = true;
  SELECT count(*) INTO manager_count
    FROM users WHERE role = 'manager' AND is_demo = true;

  IF applicant_count <> 1 OR executor_count <> 1 OR manager_count <> 1 THEN
    RAISE EXCEPTION
      '004_seed_demo_users: expected 1 demo user per role, got applicant=%, executor=%, manager=%',
      applicant_count, executor_count, manager_count;
  END IF;

  RAISE NOTICE '004_seed_demo_users OK: 1 applicant + 1 executor + 1 manager';
END $$;

COMMIT;
