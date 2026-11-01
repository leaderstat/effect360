"""Final repair v13: bind feedback_clear, demo_users, missing fields in metrics inline."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Insert the two missing bindings before decode.success.
old = """    use auto_checked <- field_int(10)
    decode.success(#("""
new = """    use auto_checked <- field_int(10)
    use manual_required <- field_int(11)
    use feedback_clear <- field_int(12)
    use demo_users <- field_int(13)
    decode.success(#("""
if old in s:
    s = s.replace(old, new)
    print("bindings ok")
else:
    print("bindings NOT found")

# Fix `first_action_seconds_sum` (Float -> Int) by truncating to int.
old2 = "value: average_hours(first_action_seconds_sum, first_action_count)"
new2 = "value: average_hours_int(first_action_seconds_sum, first_action_count)"
if old2 in s:
    s = s.replace(old2, new2)
    print("type ok")
else:
    print("type NOT found")

# Also: needs_clarification -> field_int(1) instead of duplicated
# Ensure the inline decoder has all 14 fields bound.
PATH.write_text(s, encoding="utf-8")
print("written")
