"""Repair v8: be aggressive — write the patched content unconditionally."""
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
        "extra1", "extra2", "extra3", "extra4", "extra5", "extra6",
        "extra7", "extra8", "extra9", "extra10", "extra11", "extra12",
    ],
}

lines = s.splitlines()
out = []
current = None
counter = 0
re_fn = re.compile(r"^fn (\w+_decoder)\(\) -> decode\.Decoder\(\w+\) \{$")
re_bind = re.compile(r"^(\s*)use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$")
for ln in lines:
    m = re_fn.match(ln)
    if m:
        current = m.group(1)
        counter = 0
        out.append(ln)
        continue
    if current and ln.strip() == "}":
        current = None
        out.append(ln)
        continue
    if current and current in ORDERS:
        m = re_bind.match(ln)
        if m:
            indent, kind = m.group(1), m.group(2)
            order = ORDERS[current]
            if counter < len(order):
                var = order[counter]
            else:
                var = f"v{counter}"
            counter += 1
            if kind == "opt_field_text":
                out.append(f"{indent}use {var} <- opt_field_text({counter - 1}, None)")
            else:
                out.append(f"{indent}use {var} <- {kind}({counter - 1})")
            continue
    out.append(ln)

new_s = "\n".join(out) + "\n"
PATH.write_text(new_s, encoding="utf-8")
remaining = [ln for ln in new_s.splitlines() if re_bind.match(ln)]
print(f"remaining={len(remaining)}")
for ln in remaining[:10]:
    print(ln)
