"""Final repair v17: ratio() takes Int (percent)."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# ratio is defined as fn(Int, Int) -> Int in this project (percent),
# so feedback_clear/overdue should remain Int.
s = s.replace(
    "value: ratio(int.to_float(feedback_clear), int.to_float(overdue))",
    "value: ratio(feedback_clear, overdue)",
)

PATH.write_text(s, encoding="utf-8")
print("written")
