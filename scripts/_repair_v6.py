"""Targeted final repair for the three broken decoder blocks.

Block 1 (timeline_decoder): fields = id, from_status, to_status, actor_role,
   actor_name, reason_code, created_at
Block 2 (applicant_request_decoder): fields = id, status_text, request_type,
   title, created_at, submitted_at, due_at, is_overdue, assignee_name,
   clarification_note
Block 3 (metrics_decoder): fields listed in the SELECT alias order:
   total_requests, feedback_total, feedback_clear, demo_users,
   clarification_total, average_initial_check_ms, average_notification_ms,
   average_drafting_ms, overdue_count, auto_checked, manual_required,
   clarification_rate_pct
"""
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

lines = s.splitlines()
out = []
i = 0
while i < len(lines):
    ln = lines[i]
    m = re.match(r"^fn (\w+_decoder)\(\) -> decode\.Decoder\((\w+)\) \{$", ln)
    if m:
        name = m.group(1)
        order = ORDERS.get(name)
        if not order:
            out.append(ln)
            i += 1
            continue
        out.append(ln)
        i += 1
        depth = 1
        block = []
        while i < len(lines) and depth > 0:
            cur = lines[i]
            if cur.strip() == "}":
                depth -= 1
                block.append(cur)
                i += 1
                continue
            depth += cur.count("{") - cur.count("}")
            block.append(cur)
            i += 1
        counter = 0
        new_block = []
        for bl in block:
            bm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", bl)
            if bm:
                kind = bm.group(1)
                if counter < len(order):
                    var = order[counter]
                else:
                    var = f"v{counter}"
                counter += 1
                if kind == "opt_field_text":
                    new_block.append(f"  use {var} <- opt_field_text({counter - 1}, None)")
                else:
                    new_block.append(f"  use {var} <- {kind}({counter - 1})")
            else:
                new_block.append(bl)
        out.extend(new_block)
        continue
    out.append(ln)
    i += 1

PATH.write_text("\n".join(out) + "\n", encoding="utf-8")
remaining = [ln for ln in out if re.match(r"^\s*use \$1 <- ", ln)]
print(f"remaining={len(remaining)}")
for ln in remaining[:10]:
    print(ln)
