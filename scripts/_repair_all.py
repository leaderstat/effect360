"""Universal repair for any remaining `use $1 <- ...($2)` patterns."""
from pathlib import Path
import re

p = Path("services/api/src/effectivnost_360/moderation.gleam")
s = p.read_text(encoding="utf-8")

# Generic decoder repair: assigns field_text(0..N) and opt_field_text(0..N)
# in document order.
pattern = re.compile(r"use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)")
counter = {"field_text": 0, "opt_field_text": 0, "field_bool": 0, "field_int": 0, "field_float": 0}
# Need a per-decoder counter, so split by decoder fn blocks.
blocks = s.split("fn ")
new_blocks = []
for blk in blocks:
    if not blk.startswith(("notification_decoder", "timeline_decoder", "feedback_decoder", "queue_decoder", "my_requests_decoder", "metrics_decoder")):
        new_blocks.append(blk)
        continue
    c = 0
    def rep(m, _c=[0]):
        kind = m.group(1)
        _c[0] += 1
        return f"USE_{kind.upper()}_{_c[0]}"
    new = pattern.sub(rep, blk)
    new_blocks.append(new)

new_s = "fn ".join(new_blocks)
# Now replace the markers with the variable names in declaration order.
mapping = {
    "USE_FIELD_TEXT_1": "id",
    "USE_FIELD_TEXT_2": "request_id",
    "USE_FIELD_TEXT_3": "kind",
    "USE_FIELD_TEXT_4": "title",
    "USE_FIELD_TEXT_5": "body",
    "USE_FIELD_TEXT_6": "created_at",
    "USE_OPT_FIELD_TEXT_1": "read_at",
    "USE_OPT_FIELD_TEXT_2": "actor_name",
    "USE_OPT_FIELD_TEXT_3": "reason_code",
    "USE_OPT_FIELD_TEXT_4": "from_status",
    "USE_OPT_FIELD_TEXT_5": "to_status",
    "USE_OPT_FIELD_TEXT_6": "actor_role",
    "USE_FIELD_TEXT_7": "id2",
    "USE_FIELD_TEXT_8": "from_status2",
    "USE_FIELD_TEXT_9": "to_status2",
    "USE_FIELD_TEXT_10": "actor_role2",
    "USE_FIELD_TEXT_11": "created_at2",
    "USE_OPT_FIELD_TEXT_7": "actor_name2",
    "USE_OPT_FIELD_TEXT_8": "reason_code2",
    "USE_FIELD_TEXT_12": "from_status3",
    "USE_FIELD_TEXT_13": "to_status3",
}
for k, v in mapping.items():
    new_s = new_s.replace(k, v)

# Fallback: any remaining USE_FIELD_TEXT_* (numeric) → generated names
new_s = re.sub(r"USE_FIELD_TEXT_(\d+)", lambda m: f"field_{m.group(1)}", new_s)
new_s = re.sub(r"USE_OPT_FIELD_TEXT_(\d+)", lambda m: f"opt_field_{m.group(1)}", new_s)
new_s = re.sub(r"USE_FIELD_BOOL_(\d+)", lambda m: f"field_bool_{m.group(1)}", new_s)
new_s = re.sub(r"USE_FIELD_INT_(\d+)", lambda m: f"field_int_{m.group(1)}", new_s)
new_s = re.sub(r"USE_FIELD_FLOAT_(\d+)", lambda m: f"field_float_{m.group(1)}", new_s)

# If the field name collides with a tuple field in `decode.success(...)`,
# we just rely on the existing decoder success body. That works for our
# actual files.

p.write_text(new_s, encoding="utf-8")
# Sanity
remaining = [ln for ln in new_s.splitlines() if "$1" in ln or "$2" in ln]
print(f"remaining={len(remaining)}")
for ln in remaining[:5]:
    print(ln)
