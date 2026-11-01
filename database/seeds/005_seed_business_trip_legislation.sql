-- database/seeds/003_seed_business_trip_legislation.sql
--
-- Загрузка нормативных актов и справочников для типа заявки
-- «Служебная командировка».
--
-- ⚠️  ИСТОЧНИКИ
--   1. docs/Законодательство_о_командировках_—_статьи.md (собрано 26.10.2026).
--   2. Ссылки на consultant.ru и garant.ru указаны в самом документе.
--   3. Полные тексты пунктов НПА должны быть сверены с первоисточником
--      перед включением `request_type.enabled = true`.
--
-- ЧТО ДЕЛАЕТ
--   1. Заполняет `regulatory_references` — внешние НПА с метаданными.
--   2. Заполняет `allowance_tiers` — справочник размеров возмещения
--      (ПП № 729: жильё ≤550 ₽/сут, суточные 100 ₽/сут, и т.п.).
--   3. Заполняет `ndf_limits` — необлагаемые лимиты суточных (НК РФ 700/2500 ₽).
--   4. Создаёт фикстуру в `regulations` / `clauses` / `request_types` /
--      `requirements`, описанную в database/seeds/business_trip_fixture.json.
--      Цитаты проверены scripts/verify_fixture_citations.py (2026-10-28).
--
-- ТРЕБОВАНИЯ
--   - 001_initial.sql
--   - 002_moderation_360.sql
--   - 003_automation_agents.sql
--   - 004_legislation_references.sql
--
-- ИДЕМПОТЕНТНОСТЬ
--   - regulatory_references UNIQUE (act_kind, number, date_signed)
--   - allowance_tiers / ndf_limits: по (regulatory_ref_id, scope, category)
--   - regulations UNIQUE (title, version) — из 001_initial.sql
--   - clauses UNIQUE (regulation_id, number) — из 001_initial.sql
--   - requirements UNIQUE (request_type_id, field_name, clause_id)
--   Все вставки через ON CONFLICT DO NOTHING.
--
-- ОТКАТ
--   BEGIN;
--     DELETE FROM requirements WHERE request_type_id IN (...);
--     DELETE FROM request_types WHERE name = 'Служебная командировка';
--     DELETE FROM clauses WHERE regulation_id IN (...);
--     DELETE FROM regulations WHERE title = 'Положение об особенностях направления работников в служебные командировки';
--     DELETE FROM allowance_tiers WHERE ...;
--     DELETE FROM ndf_limits WHERE ...;
--     DELETE FROM regulatory_references WHERE ...;
--   COMMIT;
BEGIN;

-- =====================================================================
-- 1. regulatory_references: внешние НПА
-- =====================================================================
-- ПП РФ от 16.04.2025 № 501 (действующий, заменяет № 749 с 01.09.2025)
INSERT INTO regulatory_references (act_kind, number, title, date_signed, effective_from, effective_until, publisher, publication, portal_url, status, notes)
VALUES (
    'ПП РФ',
    '501',
    'Об особенностях направления работников в служебные командировки',
    '2025-04-16',
    '2025-09-01',
    '2031-09-01',
    'Правительство Российской Федерации',
    'Официальный интернет-портал правовой информации (pravo.gov.ru), опубликовано 16.04.2025, № 0001202504160034. Собрание законодательства РФ, 2025, № 17, ст. 1195.',
    'https://www.consultant.ru/document/cons_doc_LAW_503406/856de09213dec309d439af5754055dbc4acab98d/',
    'active',
    'Заменяет ПП № 749 (утратил силу с 01.09.2025). Действует до 01.09.2031.'
)
ON CONFLICT (act_kind, number, date_signed) DO NOTHING;

-- ПП РФ от 13.10.2008 № 749 (утратил силу с 01.09.2025)
INSERT INTO regulatory_references (act_kind, number, title, date_signed, effective_from, effective_until, publisher, publication, portal_url, status, notes)
VALUES (
    'ПП РФ',
    '749',
    'Об особенностях направления работников в служебные командировки',
    '2008-10-13',
    '2008-10-13',
    '2025-09-01',
    'Правительство Российской Федерации',
    'Российская газета, 2008, 22 октября',
    'https://base.garant.ru/12162866/',
    'repealed',
    'Утратил силу с 01.09.2025. Заменён ПП № 501. Используется только для gap-detection (положение № 0053/о ссылается на утративший силу акт).'
)
ON CONFLICT (act_kind, number, date_signed) DO NOTHING;

-- ТК РФ — базовые статьи о командировках
INSERT INTO regulatory_references (act_kind, number, title, date_signed, effective_from, publisher, publication, portal_url, status, notes)
VALUES
    ('ТК РФ', '166', 'Понятие служебной командировки',                       '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2002, № 1, ст. 3', 'https://www.consultant.ru/document/cons_doc_LAW_34683/9d204a7e952ea1b8293d96849eebc0217b1ab81b/', 'active', 'Определение командировки'),
    ('ТК РФ', '167', 'Гарантии при направлении в командировки',               '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2002, № 1, ст. 3', 'https://www.consultant.ru/document/cons_doc_LAW_34683/8f491cd5c0dfd8755a0ee803e669f53cb22d89e8/', 'active', 'Ч. 2: защита инвалидов'),
    ('ТК РФ', '168', 'Возмещение расходов при командировках',                 '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2002, № 1, ст. 3', 'https://www.consultant.ru/document/cons_doc_LAW_34683/20f26d6f52c6bf331795839d40a065b6cb0fb84c/', 'active', 'Ч. 2 для фед. учреждений, ч. 4 для остальных'),
    ('ТК РФ', '153', 'Оплата труда в выходные и праздники',                  '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2002, № 1, ст. 3', 'https://www.consultant.ru/document/cons_doc_LAW_34683/a6a0176ee414c56cbffecc3d3fe9c161603a3b35/', 'active', 'П. 5 ПП 501 ссылается'),
    ('ТК РФ', '203', 'Ученический договор',                                  '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2002, № 1, ст. 3', 'https://www.consultant.ru/document/cons_doc_LAW_34683/118b569b77161faa3ec44a22ea0350e8d21350fc/', 'active', 'Ч. 3: ограничения для учеников'),
    ('ТК РФ', '259', 'Гарантии беременным и лицам с семейными обязанностями', '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2002, № 1, ст. 3', 'https://www.consultant.ru/document/cons_doc_LAW_34683/b3b98c8b54f919c352560aadad5f95df943fd9fe/', 'active', 'Ч. 1: жёсткий запрет; ч. 2–3: защищённые категории'),
    ('ТК РФ', '264', 'Гарантии отцам и опекунам несовершеннолетних',         '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2002, № 1, ст. 3', 'https://www.consultant.ru/document/cons_doc_LAW_34683/59143acbc00a36c5440ea89e99e30f512a448118/', 'active', 'Распространение ст. 259'),
    ('ТК РФ', '268', 'Запрет направления в командировки работников до 18 лет', '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2002, № 1, ст. 3', 'https://www.consultant.ru/document/cons_doc_LAW_34683/b635caacf52f1698330c7c27b9cccb0a9c23bcb9/', 'active', 'Исключения — творческие работники, спортсмены по ст. 348.8'),
    ('ТК РФ', '139', 'Исчисление средней заработной платы',                  '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2002, № 1, ст. 3', 'https://www.consultant.ru/document/cons_doc_LAW_34683/', 'active', 'Конкретный порядок — ПП № 540 от 24.04.2025')
ON CONFLICT (act_kind, number, date_signed) DO NOTHING;

-- ПП РФ от 02.10.2002 № 729 (размеры возмещения для федеральных учреждений)
INSERT INTO regulatory_references (act_kind, number, title, date_signed, effective_from, publisher, publication, portal_url, status, notes)
VALUES (
    'ПП РФ',
    '729',
    'О размерах возмещения расходов при служебных командировках работников, заключающих трудовой договор о работе в федеральных государственных органах, работников государственных внебюджетных фондов Российской Федерации, федеральных государственных учреждений',
    '2002-10-02',
    '2002-10-02',
    'Правительство Российской Федерации',
    'Собрание законодательства РФ, 2002, № 40, ст. 3939 (ред. от 28.10.2022)',
    'https://www.consultant.ru/document/cons_doc_LAW_38935/',
    'active',
    'Справочный: жильё ≤550 ₽/сут, суточные 100 ₽/сут.'
)
ON CONFLICT (act_kind, number, date_signed) DO NOTHING;

-- ПП РФ от 26.12.2005 № 812 (суточные за рубежом)
INSERT INTO regulatory_references (act_kind, number, title, date_signed, effective_from, publisher, publication, portal_url, status, notes)
VALUES (
    'ПП РФ',
    '812',
    'О размерах и порядке выплаты суточных в иностранной валюте и надбавок к суточным в иностранной валюте при служебных командировках на территории иностранных государств работников, заключающих трудовой договор о работе в федеральных государственных органах, работников государственных внебюджетных фондов Российской Федерации, федеральных государственных учреждений',
    '2005-12-26',
    '2006-01-01',
    'Правительство Российской Федерации',
    'Собрание законодательства РФ, 2006, № 1, ст. 215 (ред. от 28.10.2022)',
    'https://www.consultant.ru/document/cons_doc_LAW_57424/',
    'active',
    'Размеры суточных по странам в Приложении № 1.'
)
ON CONFLICT (act_kind, number, date_signed) DO NOTHING;

-- ПП РФ от 24.04.2025 № 540 (средний заработок; заменяет № 922)
INSERT INTO regulatory_references (act_kind, number, title, date_signed, effective_from, effective_until, publisher, publication, portal_url, status, notes)
VALUES (
    'ПП РФ',
    '540',
    'Об особенностях порядка исчисления средней заработной платы',
    '2025-04-24',
    '2025-09-01',
    NULL,
    'Правительство Российской Федерации',
    'pravo.gov.ru',
    'https://www.consultant.ru/document/cons_doc_LAW_504093/',
    'active',
    'Заменяет ПП № 922 с 01.09.2025.'
)
ON CONFLICT (act_kind, number, date_signed) DO NOTHING;

-- ПП РФ от 24.12.2007 № 922 (утратил силу с 01.09.2025)
INSERT INTO regulatory_references (act_kind, number, title, date_signed, effective_from, effective_until, publisher, publication, portal_url, status, notes)
VALUES (
    'ПП РФ',
    '922',
    'Об особенностях порядка исчисления средней заработной платы',
    '2007-12-24',
    '2008-01-01',
    '2025-09-01',
    'Правительство Российской Федерации',
    'Российская газета, 2007, 31 декабря',
    'https://base.garant.ru/12158040/',
    'repealed',
    'Утратил силу с 01.09.2025. Заменён ПП № 540.'
)
ON CONFLICT (act_kind, number, date_signed) DO NOTHING;

-- НК РФ — необлагаемые лимиты
INSERT INTO regulatory_references (act_kind, number, title, date_signed, effective_from, publisher, publication, portal_url, status, notes)
VALUES
    ('НК РФ', '217.1', 'Доходы, не подлежащие налогообложению (суточные)', '1998-07-31', '1999-01-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 1998, № 31, ст. 3823', 'https://www.consultant.ru/law/podborki/sutochnye_700_rublej/', 'active', 'Лимит: 700 ₽ Россия, 2500 ₽ зарубеж'),
    ('НК РФ', '422.2', 'Страховые взносы (необлагаемые суммы)',            '2001-12-30', '2002-02-01', 'Государственная Дума РФ', 'Собрание законодательства РФ, 2001, № 52, ст. 5146', 'https://www.consultant.ru/document/cons_doc_LAW_28165/30e4690deae106140c96017db18054a3175e14f6/', 'active', 'В тех же пределах, что НДФЛ')
ON CONFLICT (act_kind, number, date_signed) DO NOTHING;

-- =====================================================================
-- 2. allowance_tiers — справочник размеров возмещения (ПП № 729)
-- =====================================================================
-- Получаем id ПП № 729
DO $$
DECLARE
    ref_pp729_id uuid;
    ref_pp812_id uuid;
BEGIN
    SELECT id INTO ref_pp729_id FROM regulatory_references
        WHERE act_kind = 'ПП РФ' AND number = '729' AND date_signed = '2002-10-02';
    SELECT id INTO ref_pp812_id FROM regulatory_references
        WHERE act_kind = 'ПП РФ' AND number = '812' AND date_signed = '2005-12-26';

    -- Суточные: 100 ₽/сутки (ПП № 729)
    INSERT INTO allowance_tiers (regulatory_ref_id, scope, category, currency, amount, unit, note, effective_from, source_url)
    VALUES (ref_pp729_id, 'federal_institution', 'per_diem', 'RUB', 100.00, 'per_day',
            'Суточные для федеральных государственных учреждений (ПП № 729 п. 1).',
            '2002-10-02', 'https://www.consultant.ru/document/cons_doc_LAW_38935/')
    ON CONFLICT DO NOTHING;

    -- Жильё: ≤550 ₽/сутки с документами (ПП № 729)
    INSERT INTO allowance_tiers (regulatory_ref_id, scope, category, currency, amount, unit, note, effective_from, source_url)
    VALUES (ref_pp729_id, 'federal_institution', 'lodging_per_day', 'RUB', 550.00, 'per_day',
            'Жильё с подтверждающими документами — фактически по документам, но не более 550 ₽/сутки (ПП № 729 п. 1).',
            '2002-10-02', 'https://www.consultant.ru/document/cons_doc_LAW_38935/')
    ON CONFLICT DO NOTHING;

    -- Жильё без документов: 12 ₽/сутки (ПП № 729)
    INSERT INTO allowance_tiers (regulatory_ref_id, scope, category, currency, amount, unit, note, effective_from, source_url)
    VALUES (ref_pp729_id, 'federal_institution', 'lodging_no_docs_per_day', 'RUB', 12.00, 'per_day',
            'Жильё без документов — 12 ₽/сутки (ПП № 729 п. 1).',
            '2002-10-02', 'https://www.consultant.ru/document/cons_doc_LAW_38935/')
    ON CONFLICT DO NOTHING;

    -- Проезд: не выше купе скорого фирменного / эконом-класса
    INSERT INTO allowance_tiers (regulatory_ref_id, scope, category, currency, amount, unit, note, effective_from, source_url)
    VALUES (ref_pp729_id, 'federal_institution', 'transport_max_class', 'RUB', NULL, 'class_only',
            'Проезд не выше купе скорого фирменного поезда или эконом-класса самолёта; такси не возмещается; без билетов — по минимальной стоимости (ПП № 729 п. 1).',
            '2002-10-02', 'https://www.consultant.ru/document/cons_doc_LAW_38935/')
    ON CONFLICT DO NOTHING;

    -- Международный проезд: по аналогии, без суммы
    INSERT INTO allowance_tiers (regulatory_ref_id, scope, category, currency, amount, unit, note, effective_from, source_url)
    VALUES (ref_pp812_id, 'international_default', 'per_diem', 'USD', NULL, 'per_day',
            'Размеры суточных в иностранной валюте по странам — Приложение № 1 к ПП № 812 (ред. 28.10.2022).',
            '2006-01-01', 'https://www.consultant.ru/document/cons_doc_LAW_57424/')
    ON CONFLICT DO NOTHING;

    RAISE NOTICE 'allowance_tiers seeded: 5 records (4 federal + 1 international)';
END $$;

-- =====================================================================
-- 3. ndf_limits — необлагаемые лимиты суточных (НК РФ ст. 217 п. 1)
-- =====================================================================
DO $$
DECLARE
    ref_nk217_id uuid;
BEGIN
    SELECT id INTO ref_nk217_id FROM regulatory_references
        WHERE act_kind = 'НК РФ' AND number = '217.1';

    -- 700 ₽ в сутки (Россия)
    INSERT INTO ndf_limits (regulatory_ref_id, scope, amount, currency, effective_from, note)
    VALUES (ref_nk217_id, 'domestic', 700.00, 'RUB', '2009-01-01',
            'Не облагаются НДФЛ суточные в пределах 700 ₽/сутки (НК РФ ст. 217 п. 1). Те же пределы — для страховых взносов (ст. 422 п. 2).')
    ON CONFLICT DO NOTHING;

    -- 2 500 ₽ в сутки (зарубеж)
    INSERT INTO ndf_limits (regulatory_ref_id, scope, amount, currency, effective_from, note)
    VALUES (ref_nk217_id, 'international', 2500.00, 'RUB', '2009-01-01',
            'Не облагаются НДФЛ суточные в пределах 2500 ₽/сутки при зарубежных командировках (НК РФ ст. 217 п. 1).')
    ON CONFLICT DO NOTHING;

    RAISE NOTICE 'ndf_limits seeded: 2 records (domestic + international)';
END $$;

-- =====================================================================
-- 4. Загрузка фикстуры «Служебная командировка» в regulations/clauses/
--    request_types/requirements. Цитаты проверены
--    scripts/verify_fixture_citations.py (2026-10-28, 21 passed checks).
-- =====================================================================
DO $$
DECLARE
    reg_id  uuid;
    rt_id   uuid;
    cl_id   uuid;
BEGIN
    -- 4.1 Regulation
    INSERT INTO regulations (title, version, status, source_file_key)
    VALUES (
        'Положение об особенностях направления работников в служебные командировки',
        '2025-04-16',
        'approved',
        'database/seeds/business_trip_fixture.json'
    )
    ON CONFLICT (title, version) DO NOTHING
    RETURNING id INTO reg_id;

    IF reg_id IS NULL THEN
        SELECT id INTO reg_id FROM regulations
            WHERE title = 'Положение об особенностях направления работников в служебные командировки'
              AND version = '2025-04-16';
    END IF;

    -- 4.2 Clauses — 14 пунктов (ПП 501 + ТК РФ).
    -- clause_id хранится в поле `number` с префиксом (например, 'pp501_p2').
    -- Это сделано потому, что regulations.title содержит "Положение", и для
    -- него используются ссылки и на ПП 501, и на ТК РФ — в одном нормативном
    -- пространстве. Хранение clause_id как `number` сохраняет ссылочную
    -- целостность (UNIQUE (regulation_id, number)).
    INSERT INTO clauses (regulation_id, number, clause_ref, text) VALUES
        (reg_id, 'pp501_p2', 'П. 2 ПП РФ № 501',  'В служебные командировки направляются работники, состоящие в трудовых отношениях. Работники, выполняющие работы (оказывающие услуги) по гражданско-правовым договорам, в служебные командировки не направляются.'),
        (reg_id, 'pp501_p3', 'П. 3 ПП РФ № 501',  'Местом постоянной работы работника является место, указанное в трудовом договоре. Служебная командировка оформляется письменным решением работодателя.'),
        (reg_id, 'pp501_p4', 'П. 4 ПП РФ № 501',  'Срок служебной командировки определяется работодателем. Днем выезда в служебную командировку считается дата отправления транспортного средства от места постоянной работы, а днем приезда — дата прибытия транспортного средства к месту постоянной работы. При отправлении транспортного средства до 24 часов включительно днем отъезда в командировку считаются текущие сутки, а с 00 часов и позднее — последующие сутки. Время нахождения в пути сверх установленного графика движения транспорта учитывается отдельно. Выход работника на работу в день отъезда и день приезда согласуется с работодателем.'),
        (reg_id, 'pp501_p6', 'П. 6 ПП РФ № 501',  'Фактический срок пребывания работника в месте командировки определяется по проездным документам, представляемым работником по возвращении из служебной командировки. В случае отсутствия проездных документов — по документам о найме жилого помещения. При отсутствии и тех и других документов — по служебной записке и (или) иному документу принимающей стороны, содержащему даты прибытия и убытия работника.'),
        (reg_id, 'pp501_p9', 'П. 9 ПП РФ № 501',  'Суточные выплачиваются за каждый день нахождения в служебной командировке, включая выходные и нерабочие праздничные дни, а также дни в пути. При возможности ежедневного возвращения к месту постоянного жилья суточные не выплачиваются. Вопрос о возможности ежедневного возвращения к месту постоянного жилья решается руководителем.'),
        (reg_id, 'pp501_p12', 'П. 12 ПП РФ № 501', 'Расходы по найму жилого помещения возмещаются работнику, за исключением случаев, когда работнику предоставляется бесплатное жилое помещение.'),
        (reg_id, 'pp501_p23', 'П. 23 ПП РФ № 501', 'Работник представляет авансовый отчёт в течение трёх рабочих дней после возвращения из служебной командировки с приложением документов о найме жилого помещения, проездных и иных документов, подтверждающих произведённые в командировке расходы.'),
        (reg_id, 'tk259_1', 'Ст. 259 ч. 1 ТК РФ',   'Направление в служебные командировки, служебные поездки беременных женщин не допускается.'),
        (reg_id, 'tk268', 'Ст. 268 ТК РФ',     'Запрещаются направление в служебные командировки, привлечение к сверхурочной работе, работе в ночное время, в выходные и нерабочие праздничные дни работников в возрасте до восемнадцати лет.'),
        (reg_id, 'tk203_3', 'Ст. 203 ч. 3 ТК РФ',   'Ученики по ученическому договору не могут направляться в служебные командировки, не связанные с ученичеством.'),
        (reg_id, 'tk167_2', 'Ст. 167 ч. 2 ТК РФ',   'Направление инвалидов в служебные командировки допускается только с их письменного согласия и при условии, что такая командировка не запрещена им в соответствии с медицинским заключением. При этом инвалиды должны быть в письменной форме ознакомлены с правом отказаться от направления в служебную командировку.'),
        (reg_id, 'tk259_2', 'Ст. 259 ч. 2 ТК РФ',   'Направление в служебные командировки, служебные поездки женщин, имеющих детей в возрасте до трёх лет, допускается только с их письменного согласия и при условии, что такая командировка не запрещена им в соответствии с медицинским заключением. Указанные работники должны быть в письменной форме ознакомлены с правом отказаться от направления в служебную командировку.'),
        (reg_id, 'tk153', 'Ст. 153 ТК РФ',     'Работа в выходной или нерабочий праздничный день оплачивается не менее чем в двойном размере. По желанию работника, работавшего в выходной или нерабочий праздничный день, ему может быть предоставлен другой день отдыха. В этом случае работа в выходной или нерабочий праздничный день оплачивается в одинарном размере, а день отдыха оплате не подлежит.'),
        (reg_id, 'tk166', 'Ст. 166 ТК РФ',     'Служебная командировка — поездка работника по распоряжению работодателя на определённый срок для выполнения служебного поручения вне места постоянной работы. Особенности направления работников в служебные командировки устанавливаются Правительством Российской Федерации.')
    ON CONFLICT (regulation_id, number) DO NOTHING;

    -- 4.3 Request type — enabled = false (citation_blocker остаётся для
    --     контроля версий quote; см. docs/LEGISLATION-IMPACT.md).
    INSERT INTO request_types (
        name, description, regulation_id, fields_schema, enabled
    ) VALUES (
        'Служебная командировка',
        'Заявка на направление работника в служебную командировку по ПП РФ № 501 от 16.04.2025. Заменяет ПП № 749 с 01.09.2025.',
        reg_id,
        jsonb_build_object(
            'fields', jsonb_build_array(
                'destination_city', 'purpose', 'start_date', 'end_date',
                'employment_type', 'is_pregnant', 'is_under_18', 'has_apprentice_contract',
                'disability_group', 'written_consent_disability', 'medical_clearance_disability',
                'protected_category', 'written_consent_protected', 'medical_clearance_protected',
                'daily_return_home', 'trip_scope', 'weekend_dates_acknowledged',
                'organization', 'estimated_expenses', 'actual_stay_docs'
            ),
            'conditional', jsonb_build_object(
                'written_consent_disability', jsonb_build_object('when', jsonb_build_object('disability_group', '!= ''none'''), 'required', true),
                'medical_clearance_disability', jsonb_build_object('when', jsonb_build_object('disability_group', '!= ''none'''), 'required', true),
                'written_consent_protected', jsonb_build_object('when', jsonb_build_object('protected_category', '!= ''none'''), 'required', true),
                'medical_clearance_protected', jsonb_build_object('when', jsonb_build_object('protected_category', '!= ''none'''), 'required', true),
                'weekend_dates_acknowledged', jsonb_build_object('when', jsonb_build_object('weekend_dates_present', 'true'), 'required', true),
                'actual_stay_docs', jsonb_build_object('when', jsonb_build_object('after_return', 'true'), 'required', true)
            ),
            'hard_stops', jsonb_build_array(
                jsonb_build_object('field', 'employment_type', 'value', 'gph', 'clause', 'pp501_p2'),
                jsonb_build_object('field', 'is_pregnant', 'value', true, 'clause', 'tk259_1'),
                jsonb_build_object('field', 'is_under_18', 'value', true, 'clause', 'tk268')
            ),
            'classifier_type', 'business_trip',
            'regulation_external_refs', jsonb_build_array('pp501', 'tk166', 'tk167', 'tk168', 'tk153', 'tk203', 'tk259', 'tk264', 'tk268', 'tk139')
        ),
        false  -- НЕ ВКЛЮЧАТЬ до юридической сверки clause.text с первоисточником
    )
    ON CONFLICT (name) DO NOTHING
    RETURNING id INTO rt_id;

    IF rt_id IS NULL THEN
        SELECT id INTO rt_id FROM request_types WHERE name = 'Служебная командировка';
    END IF;

    -- 4.4 Requirements — 17 штук. clause_id ищем по (regulation_id, number).
    --    Выражение condition в JSON в формате, который понимает
    --    services/api/src/effectivnost_360/completeness.gleam::evaluate_condition:
    --      "required if <field> == '<literal>'"
    INSERT INTO requirements (request_type_id, field_name, required, condition, clause_id, quote, approved_at)
    SELECT
        rt_id, v.field_name, v.required,
        CASE WHEN v.condition IS NULL THEN NULL
             ELSE to_jsonb(v.condition) END,
        c.id,
        v.quote,
        NULL
    FROM (VALUES
        -- обязательные поля
        ('destination_city', true, NULL, 'pp501_p3',  'Местом постоянной работы работника является место, указанное в трудовом договоре. Служебная командировка оформляется письменным решением работодателя.'),
        ('start_date',       true, NULL, 'pp501_p4',  'Днем выезда в служебную командировку считается дата отправления транспортного средства от места постоянной работы'),
        ('end_date',         true, NULL, 'pp501_p4',  'днем приезда — дата прибытия транспортного средства к месту постоянной работы'),
        ('purpose',          true, NULL, 'tk166',     'Служебная командировка — поездка работника по распоряжению работодателя на определённый срок для выполнения служебного поручения вне места постоянной работы.'),
        ('employment_type',  true, NULL, 'pp501_p2',  'Работники, выполняющие работы (оказывающие услуги) по гражданско-правовым договорам, в служебные командировки не направляются.'),
        ('is_pregnant',      true, NULL, 'tk259_1',   'Направление в служебные командировки, служебные поездки беременных женщин не допускается.'),
        ('is_under_18',      true, NULL, 'tk268',     'Запрещаются направление в служебные командировки, привлечение к сверхурочной работе, работе в ночное время, в выходные и нерабочие праздничные дни работников в возрасте до восемнадцати лет.'),
        ('has_apprentice_contract', true, NULL, 'tk203_3', 'Ученики по ученическому договору не могут направляться в служебные командировки, не связанные с ученичеством.'),
        ('daily_return_home', true, NULL, 'pp501_p9', 'При возможности ежедневного возвращения к месту постоянного жилья суточные не выплачиваются.'),
        -- условные поля
        ('written_consent_disability',    false, 'required if disability_group != ''none''', 'tk167_2', 'Направление инвалидов в служебные командировки допускается только с их письменного согласия'),
        ('medical_clearance_disability',  false, 'required if disability_group != ''none''', 'tk167_2', 'при условии, что такая командировка не запрещена им в соответствии с медицинским заключением'),
        ('written_consent_protected',     false, 'required if protected_category != ''none''', 'tk259_2', 'допускается только с их письменного согласия'),
        ('medical_clearance_protected',   false, 'required if protected_category != ''none''', 'tk259_2', 'при условии, что такая командировка не запрещена им в соответствии с медицинским заключением'),
        ('weekend_dates_acknowledged',    false, 'required if weekend_dates_present == ''true''', 'tk153', 'Работа в выходной или нерабочий праздничный день оплачивается не менее чем в двойном размере.'),
        ('actual_stay_docs',              false, 'required if after_return == ''true''',         'pp501_p6', 'Фактический срок пребывания работника в месте командировки определяется по проездным документам, представляемым работником по возвращении из служебной командировки.'),
        -- необязательные поля
        ('organization',         false, NULL, 'pp501_p3',  'Служебная командировка оформляется письменным решением работодателя.'),
        ('estimated_expenses',   false, NULL, 'pp501_p12', 'Расходы по найму жилого помещения возмещаются работнику')
    ) AS v(field_name, required, condition, clause_number, quote)
    JOIN clauses c ON c.regulation_id = reg_id AND c.number = v.clause_number
    ON CONFLICT (request_type_id, field_name, clause_id) DO NOTHING;

    RAISE NOTICE 'business_trip fixture seeded: regulation_id=%, request_type_id=%', reg_id, rt_id;
END $$;

-- =====================================================================
-- 5. Gap: утративший силу ПП № 749 в положении № 0053/о Финуниверситета
--    (по данным docs/Законодательство_о_командировках_—_статьи.md, раздел
--    «Главное»). Это готовый пример «устаревшей внешней ссылки» для панели
--    пробелов регламента. Используем WHERE NOT EXISTS вместо ON CONFLICT,
--    потому что у таблицы `gaps` (001_initial.sql) нет подходящего UNIQUE
--    ограничения, а миграцию 001 менять нельзя.
-- =====================================================================
INSERT INTO gaps (regulation_id, kind, clause_id, description, source, status)
SELECT
    r.id,
    'outdated_external_reference',
    NULL,
    'Пункт 1.1 Положения Финуниверситета № 0053/о от 18.01.2023 ссылается на ПП РФ № 749 (утратило силу с 01.09.2025). Требуется заменить ссылку на ПП РФ № 501 от 16.04.2025.',
    'docs/Законодательство_о_командировках_—_статьи.md, раздел «Главное»; fa.ru/international-activity/abroad/',
    'proposed'
FROM regulations r
WHERE r.title = 'Положение об особенностях направления работников в служебные командировки'
  AND r.version = '2025-04-16'
  AND NOT EXISTS (
      SELECT 1 FROM gaps g
      WHERE g.regulation_id = r.id
        AND g.kind = 'outdated_external_reference'
        AND g.description LIKE 'Пункт 1.1 Положения Финуниверситета%'
  );

-- =====================================================================
-- 6. Контрольная проверка для CI.
-- =====================================================================
DO $$
DECLARE
    rec RECORD;
BEGIN
    SELECT
        (SELECT COUNT(*) FROM regulatory_references)                                                              AS refs_count,
        (SELECT COUNT(*) FROM allowance_tiers)                                                                    AS tiers_count,
        (SELECT COUNT(*) FROM ndf_limits)                                                                         AS ndf_count,
        (SELECT COUNT(*) FROM regulations WHERE title = 'Положение об особенностях направления работников в служебные командировки' AND version = '2025-04-16') AS reg_count,
        (SELECT COUNT(*) FROM clauses WHERE regulation_id IN (SELECT id FROM regulations WHERE version = '2025-04-16')) AS clauses_count,
        (SELECT COUNT(*) FROM request_types WHERE name = 'Служебная командировка')                                 AS rt_count,
        (SELECT COUNT(*) FROM requirements WHERE request_type_id IN (SELECT id FROM request_types WHERE name = 'Служебная командировка')) AS req_count,
        (SELECT enabled FROM request_types WHERE name = 'Служебная командировка')                                  AS rt_enabled,
        (SELECT COUNT(*) FROM gaps WHERE kind = 'outdated_external_reference')                                   AS gaps_count
    INTO rec;

    IF rec.refs_count < 12 THEN
        RAISE EXCEPTION 'seed check failed: expected ≥12 regulatory_references, got %', rec.refs_count;
    END IF;
    IF rec.tiers_count <> 5 THEN
        RAISE EXCEPTION 'seed check failed: expected 5 allowance_tiers, got %', rec.tiers_count;
    END IF;
    IF rec.ndf_count <> 2 THEN
        RAISE EXCEPTION 'seed check failed: expected 2 ndf_limits, got %', rec.ndf_count;
    END IF;
    IF rec.reg_count <> 1 THEN
        RAISE EXCEPTION 'seed check failed: expected 1 regulation, got %', rec.reg_count;
    END IF;
    IF rec.clauses_count <> 14 THEN
        RAISE EXCEPTION 'seed check failed: expected 14 clauses, got %', rec.clauses_count;
    END IF;
    IF rec.rt_count <> 1 THEN
        RAISE EXCEPTION 'seed check failed: expected 1 request_type, got %', rec.rt_count;
    END IF;
    IF rec.req_count <> 17 THEN
        RAISE EXCEPTION 'seed check failed: expected 17 requirements, got %', rec.req_count;
    END IF;
    IF rec.rt_enabled IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'seed check failed: request_type must remain disabled (enabled=false), got %', rec.rt_enabled;
    END IF;
    IF rec.gaps_count < 1 THEN
        RAISE WARNING 'seed check warning: expected ≥1 gap for outdated PP749 reference, got %', rec.gaps_count;
    END IF;

    RAISE NOTICE '003_seed_business_trip_legislation OK: refs=%, tiers=%, ndf=%, regulation=%, clauses=%, request_types=%, requirements=%, enabled=%, gaps=%',
        rec.refs_count, rec.tiers_count, rec.ndf_count, rec.reg_count, rec.clauses_count, rec.rt_count, rec.req_count, rec.rt_enabled, rec.gaps_count;
END $$;

COMMIT;
