-- database/migrations/004_legislation_references.sql
--
-- Фаза 8 + анализ docs/Законодательство_о_командировках_—_статьи.md (26.10.2026).
--
-- ЧТО ДОБАВЛЯЕТСЯ
-- --------------
--  1. `regulatory_references` — каталог НПА с указанием источника, периода действия,
--     версии и статуса (действует / утратил силу / заменён). Не замена `regulations`
--     (которая описывает внутреннее положение организации), а дополняющий
--     внешний реестр. Это даёт gap-detection'у (таблица `gaps`) и панели модератора
--     возможность ссылаться на конкретный НПА.
--  2. `allowance_tiers` — справочник размеров возмещения расходов (суточные,
--     жильё), который НЕ блокирует submit. Это **справочная** информация для
--     бухгалтерии и UI. Записи здесь носят характер «known limits», а не
--     «обязательные поля» — они не подключаются к completeness-движку напрямую.
--  3. `ndf_limits` — справочник необлагаемых лимитов суточных по НК РФ
--     (ст. 217 п. 1, ст. 422 п. 2). Также справочный.
--
-- ЧТО НЕ МЕНЯЕТСЯ
-- ---------------
-- - `regulations`, `clauses`, `requirements`, `request_types`, `requests`,
--   `request_events`, `gaps` — НЕ переименовываются, НЕ удаляются. Миграция
--   исключительно дополняет схему.
-- - Существующие статусы заявки (`draft`, `submitted`, `in_progress`, `returned`,
--   `completed`, `accepted`, `answer_ready`) не изменяются.
--
-- БЕЗОПАСНОСТЬ
-- ------------
-- - Миграция идемпотентна: `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`,
--   все вставки через `ON CONFLICT DO NOTHING`.
-- - Не выполняется DROP и не удаляются данные.
-- - Заполнение нормативных справочников — отдельным seed'ом
--   (`database/seeds/003_seed_business_trip_legislation.sql`).
--
-- ИСТОЧНИКИ НОРМ
-- --------------
-- - ПП РФ от 16.04.2025 № 501 — действует с 01.09.2025 до 01.09.2031
--   (заменяет ПП № 749, утративший силу с 01.09.2025, base.garant.ru/12162866/).
-- - ТК РФ ст. 153, 166, 167, 168, 203, 259, 264, 268, 139.
-- - ПП РФ от 02.10.2002 № 729 — размеры возмещения для федеральных учреждений.
-- - ПП РФ от 26.12.2005 № 812 — суточные за рубежом по странам.
-- - ПП РФ от 24.04.2025 № 540 — средний заработок (заменяет ПП № 922).
-- - НК РФ п. 1 ст. 217, п. 2 ст. 422 — необлагаемые лимиты суточных.
BEGIN;

-- ---------------------------------------------------------------------
-- 1. regulatory_references — внешние нормативные акты, на которые
--    ссылаются требования. Это НЕ то же, что `regulations` (внутренние
--    положения организации). У одного внутреннего положения может быть
--    несколько внешних источников.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS regulatory_references (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    act_kind      text NOT NULL,                  -- 'ТК РФ', 'ПП РФ', 'НК РФ', 'ФЗ'
    number        text NOT NULL,                  -- '501', '749', '729'
    title         text NOT NULL,                  -- полное название НПА
    date_signed   date,                           -- дата подписания
    effective_from date,                          -- дата вступления в силу
    effective_until date,                         -- дата утраты силы (NULL = действует)
    supersedes_id uuid REFERENCES regulatory_references(id),
    publisher     text NOT NULL DEFAULT '',       -- 'Правительство РФ', 'Государственная Дума'
    publication   text NOT NULL DEFAULT '',       -- 'pravo.gov.ru, № 0001202504160034'
    portal_url    text NOT NULL DEFAULT '',       -- ссылка на первоисточник
    status        text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active', 'superseded', 'expired', 'repealed')),
    notes         text NOT NULL DEFAULT '',
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (act_kind, number, date_signed)
);
CREATE INDEX IF NOT EXISTS regulatory_references_status_idx
    ON regulatory_references(status, effective_until);
COMMENT ON TABLE regulatory_references IS
    'Внешние нормативные акты, на которые ссылаются требования заявок. Связаны с `regulations` (внутренние положения организации) и `gaps` (обнаруженные противоречия/пробелы).';

-- ---------------------------------------------------------------------
-- 2. allowance_tiers — справочник размеров возмещения.
--    Эти записи НЕ блокируют submit заявки и НЕ подключаются к completeness
--    gate напрямую. Это «известные лимиты» для бухгалтерии и UI.
--    Если значение null — норма не ограничена (например, для частных
--    работодателей, см. ст. 168 ч. 4 ТК РФ).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS allowance_tiers (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    regulatory_ref_id uuid REFERENCES regulatory_references(id),
    scope         text NOT NULL
                  CHECK (scope IN (
                      'federal_institution',     -- федеральное гос. учреждение (ч. 2 ст. 168 ТК)
                      'private_employer',        -- частный работодатель (ч. 4 ст. 168 ТК)
                      'international_default'   -- по умолчанию за рубежом
                  )),
    category      text NOT NULL
                  CHECK (category IN (
                      'per_diem',                -- суточные
                      'lodging_per_day',         -- жильё за сутки
                      'lodging_no_docs_per_day', -- жильё без документов
                      'transport_max_class'      -- максимальный класс проезда
                  )),
    currency      text NOT NULL DEFAULT 'RUB',
    amount        numeric(12,2),
    unit          text NOT NULL DEFAULT ''
                  CHECK (unit IN ('per_day', 'per_trip', 'class_only', 'note')),
    note          text NOT NULL DEFAULT '',
    effective_from date NOT NULL,
    effective_until date,
    source_url    text NOT NULL DEFAULT '',
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT allowance_tiers_unique UNIQUE (regulatory_ref_id, scope, category, effective_from)
);
CREATE INDEX IF NOT EXISTS allowance_tiers_scope_category_idx
    ON allowance_tiers(scope, category, effective_from DESC);
COMMENT ON TABLE allowance_tiers IS
    'Справочник размеров возмещения командировочных расходов. Используется как референс в UI/бухгалтерии; НЕ блокирует submit.';

-- ---------------------------------------------------------------------
-- 3. ndf_limits — необлагаемые НДФЛ/взносами лимиты суточных (ст. 217 п. 1,
--    ст. 422 п. 2 НК РФ). Тоже справочный.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ndf_limits (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    regulatory_ref_id uuid REFERENCES regulatory_references(id),
    scope         text NOT NULL
                  CHECK (scope IN ('domestic', 'international')),
    amount        numeric(12,2) NOT NULL,
    currency      text NOT NULL DEFAULT 'RUB',
    effective_from date NOT NULL,
    effective_until date,
    note          text NOT NULL DEFAULT '',
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ndf_limits_unique UNIQUE (regulatory_ref_id, scope, effective_from)
);
CREATE INDEX IF NOT EXISTS ndf_limits_scope_date_idx
    ON ndf_limits(scope, effective_from DESC);
COMMENT ON TABLE ndf_limits IS
    'Необлагаемые НДФЛ/взносами лимиты суточных (НК РФ ст. 217 п. 1, ст. 422 п. 2).';

-- ---------------------------------------------------------------------
-- 4. request_events: расширение для хранения основания перехода на уровне
--    ссылки на конкретный НПА (regulatory_ref_id) для аудита.
-- ---------------------------------------------------------------------
ALTER TABLE request_events
    ADD COLUMN IF NOT EXISTS regulatory_ref_id uuid REFERENCES regulatory_references(id);
COMMENT ON COLUMN request_events.regulatory_ref_id IS
    'Ссылка на нормативный акт, ставший основанием перехода/решения. NULL допустим для операционных событий без правового основания.';

COMMIT;
