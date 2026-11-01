-- Phase 8 follow-up.
--
-- 1) `agent_exceptions.kind` must accept the full vocabulary of the domain
--    (`needs_info`, `ambiguous`, `error`), not only the two legacy values.
--    The digital moderator sends the CHECK RESULT as the exception kind, so
--    the constraint has to match `automation.CheckResult`.
--
-- 2) `request_events.actor_id` references `users(id)`. Automatic actions are
--    performed by the system, not by a human, so the system needs its own
--    user row. Without it every automated transition violates the FK.

-- 1. Widen the exception kinds.
--
-- The kind carries the CHECK RESULT, so the constraint has to accept the
-- whole vocabulary of `automation.CheckResult`: passed, needs_info,
-- ambiguous, error and skipped. `incomplete` is kept for the rows that
-- were written before the check result became the kind.
ALTER TABLE agent_exceptions
  DROP CONSTRAINT IF EXISTS agent_exceptions_kind_check;

ALTER TABLE agent_exceptions
  ADD CONSTRAINT agent_exceptions_kind_check
  CHECK (kind IN (
    'incomplete', 'needs_info', 'ambiguous', 'error', 'skipped', 'passed'
  ));

-- 1b. The draft of the clarification request is a draft too, so the digital
--     moderator may store it next to the letter draft and the result card.
ALTER TABLE agent_drafts
  DROP CONSTRAINT IF EXISTS agent_drafts_kind_check;

ALTER TABLE agent_drafts
  ADD CONSTRAINT agent_drafts_kind_check
  CHECK (kind IN ('official_response', 'result_card', 'clarification_request'));

-- 2. The system user that owns automatic actions.
--
-- The e-mail columns store the UTF-8 bytes of the e-mail (see
-- `database/seeds/004_seed_demo_users.sql`); `email_lookup_hash` is the
-- sha256 digest that the login flow looks up. The id matches
-- `agent_api.system_actor_id`, so the audit trail names the system as the
-- actor of an automatic transition.
--
-- The row is inserted only once; re-running the migration is a no-op.
INSERT INTO users (
  id,
  email_ciphertext,
  email_lookup_hash,
  full_name_ciphertext,
  display_name,
  role,
  is_demo
)
VALUES (
  '00000000-0000-0000-0000-000000000000',
  convert_to('system@effectivnost-360.invalid', 'UTF8'),
  digest('system@effectivnost-360.invalid', 'sha256'),
  convert_to('Автоматизация', 'UTF8'),
  'Автоматизация',
  'manager',
  false
)
ON CONFLICT (email_lookup_hash) DO NOTHING;
