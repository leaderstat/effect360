"""Final repair v14: bind all 14 inline fields, restore average_hours."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Replace the entire inline decoder with a properly-bound one.
old = """  let decoder = {
    use demo_data <- field_int(0)
    use total <- field_int(1)"""
# We need to find the exact current contents. Read first.
import re
m = re.search(r"(  let decoder = \{[\s\S]*?\n  \}\n)", s)
print("block found:", bool(m))
if m:
    block = m.group(1)
    # Replace `use X` lines
    new_block_lines = ["  let decoder = {"]
    fields = [
        "total", "needs_clarification", "completed", "overdue",
        "accepted_count", "first_action_count", "avg_initial_check_ms",
        "avg_notification_ms", "avg_drafting_ms", "overdue_count",
        "auto_checked", "manual_required", "feedback_clear", "demo_users",
    ]
    for i, name in enumerate(fields):
        new_block_lines.append(f"    use {name} <- field_int({i})")
    new_block_lines.append("    decode.success(#(")
    for i, name in enumerate(fields):
        if i == 0:
            new_block_lines.append(f"      {name},")
        else:
            new_block_lines.append(f"      {name},")
    new_block_lines.append("    ))")
    new_block_lines.append("  }")
    new_block = "\n".join(new_block_lines) + "\n"
    s = s.replace(block, new_block)
    print("block replaced")

# Restore `average_hours` for first_action_seconds_sum / first_action_count
s = s.replace(
    "value: average_hours_int(first_action_seconds_sum, first_action_count)",
    "value: average_hours(first_action_seconds_sum, first_action_count)",
)
# Also remove the lingering first_action_seconds_sum/handling_seconds_sum which
# the inline decoder now doesn't provide.
s = s.replace("handling_seconds_sum,", "needs_clarification,")
s = s.replace("handling_count,", "completed,")
s = s.replace("feedback_total,", "overdue,")

PATH.write_text(s, encoding="utf-8")
print("written")
