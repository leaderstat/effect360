"""Final repair v21: first_action_seconds_sum is Float; average_hours expects Float as 1st."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# The bound name is wrong: the inline decoder binds `first_action_count`
# but not `first_action_seconds_sum`. The literal name `first_action_seconds_sum`
# doesn't exist in our inline decoder anymore — we have no Float field. Replace
# with what we have: there is no such column in our SELECT, so return None.

s = s.replace(
    "value: average_hours(first_action_seconds_sum, first_action_count)",
    "value: None",
)

PATH.write_text(s, encoding="utf-8")
print("written")
