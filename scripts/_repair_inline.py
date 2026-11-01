"""Repair inline decoder blocks (`let decoder = { ... }`) in load_metrics."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Inline decoder inside `let decoder = { ... }` block in `load_metrics`.
# We rewrite each `use $1 <- ...($2)` in order using the named fields
# of the `#(...)` tuple on the same block.

INLINE_NAMES = [
    "total", "needs_clarification", "completed", "overdue",
    "accepted_count", "first_action_count", "avg_initial_check_ms",
    "avg_notification_ms", "avg_drafting_ms", "overdue_count",
    "auto_checked", "manual_required", "clarification_rate_pct",
    "handling_seconds_sum", "handling_count", "feedback_total",
    "feedback_clear", "demo_users",
]

# Find inline decoders and rewrite.
new_s = s
# First: remove the 12 `use $1 <- field_int($2)` that lie just after `let decoder = {`
m = re.search(r"(let decoder = \{\n)((?:  use \$1 <- \w+\(\$2\)\n)+)(  decode\.success\(#\()", new_s)
if not m:
    print("inline block not found")
else:
    head, binds, tail = m.group(1), m.group(2), m.group(3)
    bind_lines = binds.strip().splitlines()
    rebuilt = []
    counter = 0
    for bl in bind_lines:
        bm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", bl)
        if bm:
            kind = bm.group(1)
            var = INLINE_NAMES[counter]
            counter += 1
            if kind == "opt_field_text":
                rebuilt.append(f"  use {var} <- opt_field_text({counter - 1}, None)")
            else:
                rebuilt.append(f"  use {var} <- {kind}({counter - 1})")
        else:
            rebuilt.append(bl)
    new_binds = "\n".join(rebuilt) + "\n"
    new_s = new_s[:m.start()] + head + new_binds + tail + new_s[m.end():]

PATH.write_text(new_s, encoding="utf-8")
remaining = [ln for ln in new_s.splitlines() if re.match(r"^\s*use \$1 <- ", ln)]
print(f"remaining={len(remaining)}")
for ln in remaining[:10]:
    print(ln)
