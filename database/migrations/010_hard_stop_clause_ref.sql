-- 010_hard_stop_clause_ref.sql
--
-- The hard-stop banner in the Lustre UI rendered the raw clause UUID
-- ("Пункт положения: f1485211-079b-4239-9f10-5a212c837550") because the
-- API only selected `c.id::text AS clause_id`. `clauses.number` is a
-- machine key (`tk259_1`), so it is not a human-readable reference
-- either.
--
-- This migration adds a dedicated, denormalised `clause_ref` column that
-- carries the human-readable normative reference, e.g.
-- "Ст. 259 ч. 1 ТК РФ" or "П. 2 ПП РФ № 501".
--
-- The column is populated from the `reason` column, whose leading segment
-- before the first colon is exactly that reference. It is a safe,
-- idempotent update: no data is deleted and existing rows keep working
-- (the column is nullable, and the API falls back to `clause_id`).

BEGIN;

ALTER TABLE requirement_hard_stops
  ADD COLUMN IF NOT EXISTS clause_ref text;

COMMENT ON COLUMN requirement_hard_stops.clause_ref IS
  'Human-readable normative reference, e.g. "Ст. 259 ч. 1 ТК РФ". Used in the UI banner.';

-- Backfill: the leading segment of `reason` up to the first colon.
UPDATE requirement_hard_stops
   SET clause_ref = btrim(split_part(reason, ':', 1))
 WHERE clause_ref IS NULL
   AND reason IS NOT NULL
   AND position(':' IN reason) > 0
   AND btrim(split_part(reason, ':', 1)) <> '';

-- The same problem affected the "missing fields" list: the API returned
-- only `c.id::text`, so the UI rendered a raw UUID as the clause
-- reference. `clauses.number` is a machine key ("tk259_1"), so we store a
-- separate readable reference on the clause itself.
ALTER TABLE clauses
  ADD COLUMN IF NOT EXISTS clause_ref text;

COMMENT ON COLUMN clauses.clause_ref IS
  'Human-readable normative reference, e.g. "Ст. 259 ч. 1 ТК РФ". Shown in the UI.';

-- Human-readable normative reference for the well-known clauses of the
-- service-trip regulation. `clauses.number` is a machine key
-- ("tk259_1"), so it cannot be shown to a user as-is.
--
-- The mapping is the single source of truth and mirrors
-- database/seeds/005_seed_business_trip_legislation.sql.
UPDATE clauses c
   SET clause_ref = v.clause_ref
  FROM (VALUES
    ('pp501_p2',  'П. 2 ПП РФ № 501'),
    ('pp501_p3',  'П. 3 ПП РФ № 501'),
    ('pp501_p4',  'П. 4 ПП РФ № 501'),
    ('pp501_p6',  'П. 6 ПП РФ № 501'),
    ('pp501_p9',  'П. 9 ПП РФ № 501'),
    ('pp501_p12', 'П. 12 ПП РФ № 501'),
    ('pp501_p23', 'П. 23 ПП РФ № 501'),
    ('tk259_1',   'Ст. 259 ч. 1 ТК РФ'),
    ('tk268',     'Ст. 268 ТК РФ'),
    ('tk203_3',   'Ст. 203 ч. 3 ТК РФ'),
    ('tk167_2',   'Ст. 167 ч. 2 ТК РФ'),
    ('tk259_2',   'Ст. 259 ч. 2 ТК РФ'),
    ('tk153',     'Ст. 153 ТК РФ'),
    ('tk166',     'Ст. 166 ТК РФ')
  ) AS v(number, clause_ref)
 WHERE c.number = v.number
   AND (c.clause_ref IS NULL OR c.clause_ref <> v.clause_ref);

-- Any other clause falls back to its regulation title, so the UI never
-- shows an empty or a raw machine key.
UPDATE clauses c
   SET clause_ref = r.title
  FROM regulations r
 WHERE c.regulation_id = r.id
   AND (c.clause_ref IS NULL OR c.clause_ref = c.number);

-- Now that the clause carries a readable reference, use it for the
-- hard-stop rows. This is the authoritative value; the reason-prefix
-- backfill above is only a fallback.
UPDATE requirement_hard_stops hs
   SET clause_ref = c.clause_ref
  FROM clauses c
 WHERE hs.clause_id = c.id
   AND c.clause_ref IS NOT NULL
   AND (hs.clause_ref IS NULL OR hs.clause_ref <> c.clause_ref);

COMMIT;
