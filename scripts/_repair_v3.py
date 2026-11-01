"""Last-mile repair: bind all `use $1 <- ...($2)` lines by positional index,
deriving the variable name from the type definition's argument order."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Extract all `pub type X(\n  field: Type,\n  ...\n)` blocks.
type_re = re.compile(
    r"pub type (\w+) \(\n((?:  \w+: [\w()]+,?\n)+)\)",
)
TYPE_FIELDS = {}
for m in type_re.finditer(s):
    name = m.group(1)
    fields = [ln.split(":")[0].strip() for ln in m.group(2).strip().splitlines()]
    TYPE_FIELDS[name] = fields

# Decoder functions: `fn X_decoder() -> decode.Decoder(T)` -> T's field list.
decoder_re = re.compile(
    r"fn (\w+_decoder)\(\) -> decode\.Decoder\((\w+)\)",
)
decoder_type = {}
for m in decoder_re.finditer(s):
    decoder_type[m.group(1)] = m.group(2)

lines = s.splitlines()
out = []
in_decoder = None
counter = 0
for ln in lines:
    m = re.match(r"^fn (\w+_decoder)\(\) -> decode\.Decoder\(([\w]+)\) \{$", ln)
    if m:
        in_decoder = m.group(1)
        counter = 0
        out.append(ln)
        continue
    if in_decoder is not None and ln.strip() == "}":
        in_decoder = None
        counter = 0
        out.append(ln)
        continue
    if in_decoder is not None:
        bm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", ln)
        if bm:
            kind = bm.group(1)
            t = decoder_type.get(in_decoder)
            fields = TYPE_FIELDS.get(t, []) if t else []
            if counter < len(fields):
                var = fields[counter]
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
print("types=", list(TYPE_FIELDS.keys()))
print("decoders=", list(decoder_type.keys()))
