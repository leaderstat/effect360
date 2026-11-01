"""Last-mile repair: rewrite all `use $1 <- ...($2)` lines by positional index
within the decoder block, deriving names from the decoder fn's `decode.success(X(...))`
literal argument order."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

lines = s.splitlines()
out = []
in_decoder = None
in_success = None
field_order = []
counter = 0

for ln in lines:
    m = re.match(r"^fn (\w+)_decoder\(\) -> decode\.Decoder\(([\w]+)\) \{$", ln)
    if m:
        in_decoder = m.group(1)
        field_order = []
        counter = 0
        out.append(ln)
        continue
    if in_decoder is not None and ln.strip() == "}":
        in_decoder = None
        out.append(ln)
        continue
    if in_decoder is not None:
        # collect `decode.success(X(` arg list until matching `))`
        mm = re.match(r"^  decode\.success\(([\w]+)\(\s*$", ln)
        if mm and in_success is None:
            in_success = mm.group(1)
            out.append(ln)
            continue
        if in_success:
            # `field: name,` lines accumulate names
            name_m = re.match(r"^    (\w+): \w+,?$", ln)
            if name_m:
                field_order.append(name_m.group(1))
            elif ln.strip() == "))" or ln.strip().endswith(")"):
                in_success = None
            out.append(ln)
            continue
        # bind lines
        bm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", ln)
        if bm:
            kind = bm.group(1)
            if counter < len(field_order):
                var = field_order[counter]
            else:
                var = f"v{counter}"
            counter += 1
            if kind == "opt_field_text":
                out.append(f"  use {var} <- opt_field_text({counter - 1}, None)")
            else:
                out.append(f"  use {var} <- {kind}({counter - 1})")
            continue
    out.append(ln)

PATH.write_text("\n".join(out) + "\n", encoding="utf-8")
remaining = [ln for ln in out if re.match(r"^\s*use \$1 <- ", ln)]
print(f"remaining={len(remaining)}")
for ln in remaining[:8]:
    print(ln)
