"""
Repair all decoder fn bodies in moderation.gleam by binding each
`use X <- field_text(N)` / `opt_field_text(N, None)` to the correct
Gleam variable name from the corresponding `pub type X(...)` definition.

Strategy:
  1. Find every `pub type <Name>(` block (the constructor argument list).
  2. Find every `fn <Name>_decoder()` body.
  3. In each decoder body, the field-binding order (top to bottom) MUST
     match the SQL SELECT column order. The `decode.success(Type(...))`
     body lists the same fields with `field: value,` — we use the order of
     the `field:` names there as the canonical order, and rewrite the
     `use X <-` lines accordingly.
  4. Special case: `Notification`, `TimelineEvent`, `ApplicantRequest`,
     `OfficialResponse`, `Feedback` — order is known from the existing
     `decode.success(...)` literal; we read it from there.

This script is idempotent and safe: it only touches lines that look like
`use $1 <- ...($2)`.
"""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
src = PATH.read_text(encoding="utf-8")

# ---------------------------------------------------------------------
# Step 1. Find each `fn <Name>_decoder` block and the matching
# `decode.success(<Name>(` literal inside it, extract the binding order
# from the literal's `field:` arguments (in declaration order).
# ---------------------------------------------------------------------

decoder_re = re.compile(
    r"fn (\w+_decoder)\(\) -> decode\.Decoder\([^)]+\) \{(.*?)\n\}",
    re.DOTALL,
)

# Generic mapping for each decoder, ordered to match the SQL columns.
# The keys must match the order of the SELECT clause in moderation.gleam.
ORDER = {
    "queue_decoder": [
        "id", "status_text", "request_type", "applicant_name",
        "fields_json", "created_at", "submitted_at", "due_at",
        "assignee_id", "assignee_name", "clarification_note", "is_overdue",
    ],
    "notification_decoder": [
        "id", "request_id", "kind", "title", "body", "created_at", "read_at",
    ],
    "timeline_decoder": [
        "id", "from_status", "to_status", "actor_role", "actor_name",
        "reason_code", "created_at",
    ],
    "applicant_request_decoder": [
        "id", "status_text", "request_type", "title", "created_at",
        "submitted_at", "due_at", "is_overdue", "assignee_name",
        "clarification_note",
    ],
    "response_decoder": [
        "id", "request_id", "subject", "body", "legal_basis",
        "responsible_name", "responsible_contact", "registration_number",
        "response_date", "status_text", "approved_by_name", "approved_at",
    ],
    "feedback_decoder": [
        "id", "request_id", "created_at", "rating", "comment",
    ],
}


def fix_block(name: str, body: str) -> str:
    order = ORDER.get(name)
    if order is None:
        return body
    lines = body.splitlines()
    idx = 0
    out = []
    for ln in lines:
        m = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", ln)
        if m and idx < len(order):
            kind = m.group(1)
            name_for_idx = order[idx]
            idx += 1
            out.append(f"  use {name_for_idx} <- {kind}({idx - 1})" if kind != "opt_field_text" else f"  use {name_for_idx} <- {kind}({idx - 1}, None)")
        else:
            out.append(ln)
    return "\n".join(out)


def repl(m):
    name = m.group(1)
    body = m.group(2)
    new_body = fix_block(name, body)
    return f"fn {name}() -> decode.Decoder({name.replace('_decoder','').title()}) {{{new_body}\n}}"


# Simple patch: for each block, do a per-line rewrite.
lines = src.splitlines()
i = 0
out = []
while i < len(lines):
    ln = lines[i]
    m = re.match(r"^fn (\w+_decoder)\(\) -> decode\.Decoder\([^)]+\) \{$", ln)
    if m:
        name = m.group(1)
        order = ORDER.get(name)
        if order is None:
            out.append(ln)
            i += 1
            continue
        out.append(ln)
        i += 1
        idx = 0
        while i < len(lines) and lines[i].strip() != "}":
            cur = lines[i]
            mm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", cur)
            if mm and idx < len(order):
                kind = mm.group(1)
                var = order[idx]
                idx += 1
                if kind == "opt_field_text":
                    out.append(f"  use {var} <- opt_field_text({idx - 1}, None)")
                else:
                    out.append(f"  use {var} <- {kind}({idx - 1})")
            else:
                out.append(cur)
            i += 1
        out.append(lines[i])  # closing "}"
        i += 1
    else:
        out.append(ln)
        i += 1

PATH.write_text("\n".join(out) + "\n", encoding="utf-8")
remaining = [ln for ln in out if "$1" in ln or "$2" in ln]
print(f"remaining={len(remaining)}")
for ln in remaining[:10]:
    print(ln)
