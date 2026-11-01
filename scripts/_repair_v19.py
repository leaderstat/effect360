"""Final repair v19: average_hours expects Float -> wrap with int.to_float."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

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
s = s.replace(
    "value: average_hours(needs_clarification, completed)",
    "value: average_hours(int.to_float(needs_clarification), int.to_float(completed))",
)

PATH.write_text(s, encoding="utf-8")
print("written")
