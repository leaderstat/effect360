"""Final repair v25: force-replace the bad decoder block."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Pattern: locate the entire `let decoder = { ... }` and replace with a clean one.
m = re.search(r"  let decoder = \{\n((?:    .*\n)+?)  \}\n", s)
if not m:
    print("decoder block not found")
else:
    block = m.group(1)
    print("block:", block[:200])

new = """    use total <- field_int(0)
    use needs_clarification <- field_int(1)
    use completed <- field_int(2)
    use overdue <- field_int(3)
    use accepted_count <- field_int(4)
    use first_action_count <- field_int(5)
    use first_action_seconds_sum <- field_float(6)
    use avg_initial_check_ms <- field_float(7)
    use avg_notification_ms <- field_float(8)
    use avg_drafting_ms <- field_float(9)
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
s = s.replace(block, new)
print("replaced")

# Same for `let #(…) = row` — has 12 names, must have 15.
old2 = """      let #(
        total,
        needs_clarification,
        completed,
        overdue,
        _accepted_count,
        first_action_count,
        first_action_seconds_sum,
        needs_clarification,
        completed,
        overdue,
        feedback_clear,
        demo_users,
      ) = row"""
new2 = """      let #(
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
if old2 in s:
    s = s.replace(old2, new2)
    print("tuple fixed")
else:
    print("tuple not found")

PATH.write_text(s, encoding="utf-8")
print("written")
