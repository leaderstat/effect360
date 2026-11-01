"""Final repair v15: finish metrics inline decoder."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Map old wrong-named references to correct inline-bound names.
fixes = [
    ("handling_seconds_sum,", "needs_clarification,"),
    ("handling_count,", "completed,"),
    ("feedback_total,", "overdue,"),
    ("value: average_hours(needs_clarification, handling_count)",
     "value: average_hours(needs_clarification, completed)"),
    ("value: ratio(feedback_clear, feedback_total)",
     "value: ratio(feedback_clear, overdue)"),
    ("handling_seconds_sum)", "needs_clarification)"),
]
for old, new in fixes:
    if old in s:
        s = s.replace(old, new)
        print(f"fixed: {old[:30]}...")
    else:
        print(f"NOT found: {old[:30]}")

# Fix Float/Int mismatch: convert int to float via `int.to_float`.
# avg_initial_check_ms is an int. average_hours expects floats. Add conversion.
# We'll wrap with int.to_float(...).
s = s.replace(
    "value: average_hours(avg_initial_check_ms, first_action_count)",
    "value: average_hours(int.to_float(avg_initial_check_ms), int.to_float(first_action_count))",
)
s = s.replace(
    "value: average_hours(avg_notification_ms, accepted_count)",
    "value: average_hours(int.to_float(avg_notification_ms), int.to_float(accepted_count))",
)
s = s.replace(
    "value: average_hours(avg_drafting_ms, completed)",
    "value: average_hours(int.to_float(avg_drafting_ms), int.to_float(completed))",
)

PATH.write_text(s, encoding="utf-8")
print("written")
