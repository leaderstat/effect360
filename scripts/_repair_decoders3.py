"""Final repair for response_decoder + TimelineEvent + ApplicantRequest."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Real column orders derived from the SELECT and the OfficialResponse
# type literal in moderation.gleam.
ORDERS = {
    "TimelineEvent": [
        "id", "from_status", "to_status", "actor_role", "actor_name",
        "reason_code", "created_at",
    ],
    "ApplicantRequest": [
        "id", "status_text", "request_type", "title", "created_at",
        "submitted_at", "due_at", "is_overdue", "assignee_name",
        "clarification_note",
    ],
    "OfficialResponse": [
        "id", "request_id", "status", "organization", "requisites",
        "registration_number", "recipient", "subject", "legal_basis",
        "decision_summary", "next_steps", "responsible_executor",
        "contact_for_questions", "signature_block", "body",
        "created_at", "approved_at", "approved_by_name",
    ],
    "EfficiencyMetrics": [
        "total_requests", "auto_checked", "manual_required",
        "avg_initial_check_ms", "clarification_rate_pct", "notification_ms",
        "duplicate_prevented", "drafting_ms",
    ],
}


def map_kind(name: str, idx: int, kind: str) -> str:
    var = ORDERS[name][idx]
    if kind == "opt_field_text":
        return f"  use {var} <- opt_field_text({idx}, None)"
    return f"  use {var} <- {kind}({idx})"


lines = s.splitlines()
out = []
inside_decoder = None
counter = 0
for ln in lines:
    m = re.match(r"^fn (\w+)_decoder\(\) -> decode\.Decoder\(([\w]+)\) \{$", ln)
    if m:
        inside_decoder = m.group(1)
        counter = 0
        out.append(ln)
        continue
    if inside_decoder is not None and ln.strip() == "}":
        inside_decoder = None
        counter = 0
        out.append(ln)
        continue
    if inside_decoder is not None:
        mm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", ln)
        if mm:
            kind = mm.group(1)
            order = ORDERS.get(inside_decoder)
            if order and counter < len(order):
                out.append(map_kind(inside_decoder, counter, kind))
            else:
                if kind == "opt_field_text":
                    out.append(f"  use v{counter} <- opt_field_text({counter}, None)")
                else:
                    out.append(f"  use v{counter} <- {kind}({counter})")
            counter += 1
            continue
    out.append(ln)

PATH.write_text("\n".join(out) + "\n", encoding="utf-8")
remaining = [ln for ln in out if re.match(r"^\s*use \$1 <- ", ln)]
print(f"remaining={len(remaining)}")
for ln in remaining[:8]:
    print(ln)
