"""Final repair v9: replace all `use $1 <- ...($2)` lines with named bindings.
Derive names from the surrounding type literal."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Inline decoder in load_metrics
INLINE = [
    "total", "needs_clarification", "completed", "overdue",
    "accepted_count", "first_action_count", "avg_initial_check_ms",
    "avg_notification_ms", "avg_drafting_ms", "overdue_count",
    "auto_checked", "manual_required",
]

TIMELINE = [
    "id", "from_status", "to_status", "actor_role", "actor_name",
    "reason_code", "created_at",
]

APPLICANT = [
    "id", "status_text", "request_type", "title", "created_at",
    "submitted_at", "due_at", "is_overdue", "assignee_name",
    "clarification_note",
]

# Inline decoder block fix
m = re.search(r"(let decoder = \{\n)((?:    use \$1 <- \w+\(\$2\)\n)+)(    decode\.success\(#\()", s)
if m:
    head, binds, tail = m.group(1), m.group(2), m.group(3)
    bls = binds.strip().splitlines()
    rebuilt = []
    counter = 0
    for bl in bls:
        bm = re.match(r"^    use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", bl)
        if bm:
            kind = bm.group(1)
            var = INLINE[counter]
            counter += 1
            if kind == "opt_field_text":
                rebuilt.append(f"    use {var} <- opt_field_text({counter - 1}, None)")
            else:
                rebuilt.append(f"    use {var} <- {kind}({counter - 1})")
        else:
            rebuilt.append(bl)
    new_binds = "\n".join(rebuilt) + "\n"
    s = s[:m.start()] + head + new_binds + tail + s[m.end():]
    print("inline fixed")

# Find each remaining `fn X_decoder()` block.
def fix_block(name, order):
    pat = re.compile(rf"(fn {name}\(\) -> decode\.Decoder\([^)]+\) \{{)((?:  use \$1 <- \w+\(\$2\)\n)+)(  decode\.success)")
    m = pat.search(s)
    if not m:
        print(f"skip {name}")
        return
    head, binds, tail = m.group(1), m.group(2), m.group(3)
    bls = binds.strip().splitlines()
    rebuilt = []
    counter = 0
    for bl in bls:
        bm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", bl)
        if bm:
            kind = bm.group(1)
            var = order[counter]
            counter += 1
            if kind == "opt_field_text":
                rebuilt.append(f"  use {var} <- opt_field_text({counter - 1}, None)")
            else:
                rebuilt.append(f"  use {var} <- {kind}({counter - 1})")
        else:
            rebuilt.append(bl)
    new_binds = "\n".join(rebuilt) + "\n"
    s_ = s[:m.start()] + head + new_binds + tail + s[m.end():]
    return s_

# timeline_decoder + applicant_request_decoder both: timeline first, then applicant
for nm, order in [("timeline_decoder", TIMELINE), ("applicant_request_decoder", APPLICANT)]:
    pat = re.compile(rf"(fn {nm}\(\) -> decode\.Decoder\([^)]+\) \{{)((?:  use \$1 <- \w+\(\$2\)\n)+)(  decode\.success)")
    m = pat.search(s)
    if not m:
        print(f"no match {nm}")
        continue
    head, binds, tail = m.group(1), m.group(2), m.group(3)
    bls = binds.strip().splitlines()
    rebuilt = []
    counter = 0
    for bl in bls:
        bm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", bl)
        if bm:
            kind = bm.group(1)
            var = order[counter]
            counter += 1
            if kind == "opt_field_text":
                rebuilt.append(f"  use {var} <- opt_field_text({counter - 1}, None)")
            else:
                rebuilt.append(f"  use {var} <- {kind}({counter - 1})")
        else:
            rebuilt.append(bl)
    new_binds = "\n".join(rebuilt) + "\n"
    s = s[:m.start()] + head + new_binds + tail + s[m.end():]
    print(f"fixed {nm}")

PATH.write_text(s, encoding="utf-8")
remaining = [ln for ln in s.splitlines() if re.match(r"^\s*use \$1 <- ", ln)]
print(f"remaining={len(remaining)}")
for ln in remaining[:10]:
    print(ln)
