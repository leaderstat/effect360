-- database/seeds/006_seed_hard_stops.sql
--
-- Заполняет requirement_hard_stops блокирующими правилами для типа
-- заявки «Служебная командировка».
--
-- Каждое правило — пара (field, predicate, action) с привязкой к clause
-- (норме) и regulatory_references (внешнему НПА).
--
-- Действия:
--   block_submit          — жёсткая блокировка отправки
--   needs_employer_review — требуется подтверждение работодателем
--
-- Поддерживаемые предикаты (разбираются в completeness.gleam):
--   <field> == '<value>'    точное строковое равенство
--   <field> != '<value>'    значение отличается
--   <field> in 'a,b,c'      вхождение в перечисление (через запятую)
--
-- Источники норм:
--   ст. 259 ч. 1 ТК РФ — запрет командировок беременных
--   ст. 268 ТК РФ      — запрет командировок несовершеннолетних
--   ст. 203 ч. 3 ТК РФ — ученики по ученическому договору только
--                         по профилю ученичества (требует подтверждения)
--   п. 2 ПП РФ № 501   — запрет направления в командировки ГПХ-работников
--
-- Идемпотентность: ON CONFLICT (request_type_id, field_name, trigger_expr, action) DO NOTHING.

BEGIN;

WITH bt AS (
    SELECT id FROM request_types WHERE name = 'Служебная командировка' LIMIT 1
), refs AS (
    SELECT act_kind, number, id FROM regulatory_references
), clauses AS (
    SELECT number, id, clause_ref FROM clauses
)
INSERT INTO requirement_hard_stops
    (request_type_id, field_name, trigger_expr, action, reason,
     clause_id, clause_ref, regulatory_ref_id, source_kind)
SELECT
    bt.id,
    x.field_name,
    x.trigger_expr,
    x.action,
    x.reason,
    c.id,
    c.clause_ref,
    r.id,
    'legislation_seed'
FROM bt
CROSS JOIN (VALUES
    -- ст. 259 ч. 1 ТК РФ: беременные не направляются
    ('is_pregnant',           'is_pregnant == ''true''',
     'block_submit',
     'Ст. 259 ч. 1 ТК РФ: направление беременных женщин в служебные командировки не допускается',
     'tk259_1',   'ТК РФ', '259'),

    -- ст. 268 ТК РФ: лица до 18 лет не направляются
    ('is_under_18',           'is_under_18 == ''true''',
     'block_submit',
     'Ст. 268 ТК РФ: запрещается направление в служебные командировки работников в возрасте до 18 лет',
     'tk268',      'ТК РФ', '268'),

    -- п. 2 ПП РФ № 501: ГПХ-работники не направляются
    ('employment_type',       'employment_type == ''gph''',
     'block_submit',
     'П. 2 ПП РФ № 501: работники, выполняющие работы по договорам гражданско-правового характера, в служебные командировки не направляются',
     'pp501_p2',   'ПП РФ', '501'),

    -- ст. 203 ч. 3 ТК РФ: ученический договор — только по профилю ученичества
    ('has_apprentice_contract','has_apprentice_contract == ''true''',
     'needs_employer_review',
     'Ст. 203 ч. 3 ТК РФ: ученики по ученическому договору могут направляться в командировки, только если командировка связана с ученичеством. Требуется подтверждение работодателя',
     'tk203_3',    'ТК РФ', '203')
) AS x(field_name, trigger_expr, action, reason, clause_no, ref_kind, ref_number)
LEFT JOIN refs r ON r.act_kind = x.ref_kind AND r.number = x.ref_number
LEFT JOIN clauses c ON c.number = x.clause_no
ON CONFLICT (request_type_id, field_name, trigger_expr, action) DO NOTHING;

-- Обновляем читаемую ссылку для строк, созданных до появления
-- колонки clause_ref (миграция 010).
UPDATE requirement_hard_stops hs
   SET clause_ref = c.clause_ref
  FROM clauses c
 WHERE hs.clause_id = c.id
   AND (hs.clause_ref IS NULL OR hs.clause_ref <> c.clause_ref);

-- Контрольная проверка для CI
DO $$
DECLARE
    n_block_submit int;
    n_review       int;
    n_no_ref       int;
BEGIN
    SELECT count(*) INTO n_block_submit FROM requirement_hard_stops WHERE action = 'block_submit';
    SELECT count(*) INTO n_review       FROM requirement_hard_stops WHERE action = 'needs_employer_review';
    SELECT count(*) INTO n_no_ref       FROM requirement_hard_stops WHERE regulatory_ref_id IS NULL;

    RAISE NOTICE '006_seed_hard_stops OK: block_submit=%, needs_employer_review=%, missing_regulatory_ref=%',
        n_block_submit, n_review, n_no_ref;

    IF n_block_submit < 3 THEN
        RAISE EXCEPTION 'expected at least 3 block_submit rules, got %', n_block_submit;
    END IF;
    IF n_review < 1 THEN
        RAISE EXCEPTION 'expected at least 1 needs_employer_review rule, got %', n_review;
    END IF;
    IF n_no_ref > 0 THEN
        RAISE EXCEPTION 'all hard_stop rules MUST have regulatory_ref_id; % rows missing it', n_no_ref;
    END IF;
END $$;

COMMIT;
