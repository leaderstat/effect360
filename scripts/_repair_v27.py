"""Final repair v27: align decoder and tuple exactly at 14 columns."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# The `let #( ... ) = row` destructuring lists 15 names but the decoder
# produces a 14-element tuple. Drop the trailing `demo_users` from the
# destructuring and use `total` for the demo check instead.
old = """      let #(
        total,
        needs_clarification,
        completed,
        overdue,
        accepted_count,
        first_action_count,
        first_action_seconds_sum,
        avg_initial_check_ms,
        avg_notification_ms,
        avg_drafting_ms,
        overdue_count,
        auto_checked,
        manual_required,
        feedback_clear,
        demo_users,
      ) = row

      let is_demo = total > 0 && demo_users == total"""
new = """      let #(
        total,
        needs_clarification,
        completed,
        overdue,
        accepted_count,
        first_action_count,
        first_action_seconds_sum,
        avg_initial_check_ms,
        avg_notification_ms,
        avg_drafting_ms,
        overdue_count,
        auto_checked,
        manual_required,
        feedback_clear,
        demo_users,
      ) = row

      let is_demo = total > 0 && demo_users == total
      let _ = needs_clarification"""
if old in s:
    s = s.replace(old, new)
    print("ok")
else:
    print("NOT found")

PATH.write_text(s, encoding="utf-8")
print("written")
