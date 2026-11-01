"""Final repair v29: full rewrite of the load_metrics decoder."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Locate the load_metrics block: between `pub fn load_metrics(` and `Ok(metric)`.
# Replace it with a clean, consistent 14-column decoder.
m = re.search(
    r"(pub fn compute_metrics\([\s\S]*?let decoder = \{)([\s\S]*?)(  \}\n)",
    s,
)
if not m:
    print("compute_metrics block not found")
else:
    head, _, tail = m.group(1), m.group(2), m.group(3)
    new_decoder = """  let decoder = {
    use total <- field_int(0)
    use needs_clarification <- field_int(1)
    use completed <- field_int(2)
    use overdue <- field_int(3)
    use accepted_count <- field_int(4)
    use first_action_count <- field_int(5)
    use first_action_seconds_sum <- field_int(6)
    use avg_initial_check_ms <- field_int(7)
    use avg_notification_ms <- field_int(8)
    use avg_drafting_ms <- field_int(9)
    use overdue_count <- field_int(10)
    use auto_checked <- field_int(11)
    use manual_required <- field_int(12)
    use feedback_clear <- field_int(13)
    use demo_users <- field_int(14)
    decode.success(#(
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
    ))
"""
    s = s[:m.start(2)] + "\n" + new_decoder + s[m.end(2):]
    print("decoder replaced")

# Replace the `let #(…) = row` destructuring block to match.
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
      ) = row"""
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
      ) = row"""
if old in s:
    print("tuple already aligned")
else:
    print("tuple needs alignment")

PATH.write_text(s, encoding="utf-8")
print("written")
