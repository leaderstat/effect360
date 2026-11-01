-- Phase 8 follow-up.
--
-- The applicant-support agent (Agent B) writes its notifications and
-- result cards into the `notifications` table. Its kinds — `status_change`,
-- `result_card` and `clarification_auto` — were not present in the
-- vocabulary the constraint was created with, so the writes failed.
-- Widening the constraint is safe: every kind is already routed by the
-- panel.

ALTER TABLE notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;

ALTER TABLE notifications
  ADD CONSTRAINT notifications_kind_check
  CHECK (kind IN (
    'request_accepted',
    'request_in_progress',
    'clarification_requested',
    'applicant_answered',
    'answer_ready',
    'request_completed',
    'feedback_requested',
    'auto_checked',
    'clarification_auto',
    'deadline_warning',
    'feedback_requested_auto',
    'status_change',
    'result_card'
  ));
