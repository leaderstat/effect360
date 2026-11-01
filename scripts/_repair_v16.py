"""Final repair v16."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

s = s.replace(
    "value: average_hours(needs_clarification, completed)",
    "value: average_hours(int.to_float(needs_clarification), int.to_float(completed))",
)
s = s.replace(
    "value: ratio(feedback_clear, overdue)",
    "value: ratio(int.to_float(feedback_clear), int.to_float(overdue))",
)

PATH.write_text(s, encoding="utf-8")
print("written")
