"""Fix the remaining 3 decoder blocks by inspecting their SELECT and success."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Inspect lines around each broken block to learn the column order
# from the `decode.success(X( field: value,` literal that follows.

# Strategy: walk through each `use $1 <- <helper>($2)` line in order
# across the file, and within a single decoder block bind them to the
# correct variable name from the subsequent `decode.success(X(...))` body.

ORDER = {
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
        "id", "request_id", "subject", "body", "legal_basis",
        "responsible_name", "responsible_contact", "registration_number",
        "response_date", "status_text", "approved_by_name", "approved_at",
    ],
    "EfficiencyMetrics": [
        "total_requests", "auto_checked", "manual_required",
        "avg_initial_check_ms", "clarification_rate_pct", "notification_ms",
        "duplicate_prevented", "drafting_ms",
    ],
}

# Build a flat rewrite plan: at line N, set `use <name> <- ...` based on
# the position within the current decoder fn block.
lines = s.splitlines()
out = []
inside_decoder = None
counter = 0
i = 0
while i < len(lines):
    ln = lines[i]
    # Detect decoder fn start.
    m = re.match(r"^fn (\w+)_decoder\(\) -> decode\.Decoder\(([\w]+)\) \{$", ln)
    if m:
        name = m.group(1)
        inside_decoder = name
        counter = 0
        out.append(ln)
        i += 1
        continue
    # Detect a generic Decoder block: e.g. metrics_decoder
    if inside_decoder is None:
        # Try to find metrics_decoder / feedback_decoder etc.
        mm = re.match(r"^fn (\w+)_decoder\(.*$", ln)
        if mm:
            inside_decoder = mm.group(1)
            counter = 0
            out.append(ln)
            i += 1
            continue
    if inside_decoder is not None and ln.strip() == "}":
        inside_decoder = None
        counter = 0
        out.append(ln)
        i += 1
        continue
    # Inside a decoder: try to rewrite `use $1 <- <helper>($2)`.
    if inside_decoder is not None:
        order = ORDER.get(inside_decoder)
        mm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", ln)
        if mm:
            kind = mm.group(1)
            if order and counter < len(order):
                var = order[counter]
                if kind == "opt_field_text":
                    out.append(f"  use {var} <- opt_field_text({counter}, None)")
                else:
                    out.append(f"  use {var} <- {kind}({counter})")
                counter += 1
                i += 1
                continue
            else:
                # Fallback: just use generic names.
                if kind == "opt_field_text":
                    out.append(f"  use v{counter} <- opt_field_text({counter}, None)")
                else:
                    out.append(f"  use v{counter} <- {kind}({counter})")
                counter += 1
                i += 1
                continue
    out.append(ln)
    i += 1

PATH.write_text("\n".join(out) + "\n", encoding="utf-8")
remaining = [ln for ln in out if re.match(r"^\s*use \$1 <- ", ln)]
print(f"remaining={len(remaining)}")
for ln in remaining[:10]:
    print(ln)
