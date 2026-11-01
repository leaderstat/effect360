"""Final repair v30: ensure compute_metrics is closed."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Append a closing `}` if the file ends without the function closing.
# Detect: find `pub fn parse_fields_jsonb` — everything before it must be a
# balanced block (ending with `}` at the column 0).
import re
m = re.search(r"^(pub fn parse_fields_jsonb)", s, re.MULTILINE)
if m:
    before = s[:m.start()]
    # Count open/close at column 0.
    open_count = sum(1 for ln in before.splitlines() if ln.startswith("pub fn ") or ln.startswith("fn "))
    close_count = before.count("\n}")
    print(f"opens={open_count} closes={close_count}")
    if open_count > close_count:
        # Add missing closes.
        s = s[:m.start()] + "}\n\n" + s[m.start():]
        print("added closing }")

PATH.write_text(s, encoding="utf-8")
print("written")
