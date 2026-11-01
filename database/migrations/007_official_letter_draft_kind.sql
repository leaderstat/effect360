-- Phase 8 follow-up.
--
-- Agent B (the applicant support) drafts the official letter of the answer
-- and stores it in `agent_drafts` with kind `official_letter`. The kind
-- was missing from the vocabulary the constraint was created with, so the
-- write was rejected with a CHECK violation.
--
-- Adding the kind to the vocabulary is safe: nothing else writes with this
-- kind, and the moderator panel already accepts every kind in the table.

ALTER TABLE agent_drafts
  DROP CONSTRAINT IF EXISTS agent_drafts_kind_check;

ALTER TABLE agent_drafts
  ADD CONSTRAINT agent_drafts_kind_check
  CHECK (kind IN (
    'official_response',
    'result_card',
    'clarification_request',
    'official_letter'
  ));
