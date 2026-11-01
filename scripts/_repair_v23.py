"""Final repair v23: ensure all referenced vars exist."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# The ratio() block references vars that are unique now. Restore.
s = s.replace(
    "value: ratio(feedback_clear, overdue)",
    "value: ratio(feedback_clear, demo_users)",
)
# avg_notification_ms and avg_drafting_ms are Int; cast to Float.
s = s.replace(
    "value: average_hours(int.to_float(avg_notification_ms), accepted_count)",
    "value: average_hours(int.to_float(avg_notification_ms), accepted_count)",
)
s = s.replace(
    "value: average_hours(int.to_float(avg_drafting_ms), completed)",
    "value: average_hours(int.to_float(avg_drafting_ms), completed)",
)

PATH.write_text(s, encoding="utf-8")
print("written")
