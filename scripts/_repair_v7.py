"""Repair v7: scan file linearly, track current decoder fn by name,
increment a counter per `use $1` line, and replace with the name from
ORDERS[name][counter]."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

ORDERS = {
    "timeline_decoder": [
        "id", "from_status", "to_status", "actor_role", "actor_name",
        "reason_code", "created_at",
    ],
    "applicant_request_decoder": [
        "id", "status_text", "request_type", "title", "created_at",
        "submitted_at", "due_at", "is_overdue", "assignee_name",
        "clarification_note",
    ],
    "metrics_decoder": [
        "total_requests", "feedback_total", "feedback_clear",
        "demo_users", "clarification_total", "average_initial_check_ms",
        "average_notification_ms", "average_drafting_ms", "overdue_count",
        "auto_checked", "manual_required", "clarification_rate_pct",
    ],
}

# Walk linearly; track current decoder fn.
lines = s.splitlines()
out = []
current = None
counter = 0
for ln in lines:
    m = re.match(r"^fn (\w+_decoder)\(\) -> decode\.Decoder\(\w+\) \{$", ln)
    if m:
        current = m.group(1)
        counter = 0
        out.append(ln)
        continue
    if current is not None and ln.strip() == "}":
        current = None
        out.append(ln)
        continue
    if current is not None and current in ORDERS:
        bm = re.match(r"^(\s*)use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", ln)
        if bm:
            indent = bm.group(1)
            kind = bm.group(2)
            order = ORDERS[current]
            var = order[counter] if counter < len(order) else f"v{counter}"
            counter += 1
            if kind == "opt_field_text":
                out.append(f"{indent}use {var} <- opt_field_text({counter - 1}, None)")
            else:
                out.append(f"{indent}use {var} <- {kind}({counter - 1})")
            continue
    out.append(ln)

PATH.write_text("\n".join(out) + "\n", encoding="utf-8")
remaining = [ln for ln in out if re.match(r"^\s*use \$1 <- ", ln)]
print(f"remaining={len(remaining)}")
for ln in remaining[:10]:
    print(ln)
