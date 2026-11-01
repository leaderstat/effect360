"""Final repair v5."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

lines = s.splitlines()
out = []
i = 0
while i < len(lines):
    ln = lines[i]
    m = re.match(r"^fn (\w+_decoder)\(\) -> decode\.Decoder\((\w+)\) \{$", ln)
    if m:
        out.append(ln)
        i += 1
        # Collect fields from `decode.success(Type(`.
        success_names = []
        success_open = None
        block = []
        depth = 1
        while i < len(lines) and depth > 0:
            cur = lines[i]
            if cur.strip() == "}":
                depth -= 1
                block.append(cur)
                i += 1
                continue
            depth += cur.count("{") - cur.count("}")
            sm = re.match(r"^\s*decode\.success\((\w+)\(\s*$", cur)
            if sm:
                success_open = i
                success_names = []
                block.append(cur)
                i += 1
                continue
            if success_open is not None:
                nm = re.match(r"^\s*(\w+): \w+,?\s*$", cur)
                if nm:
                    success_names.append(nm.group(1))
                elif cur.strip().endswith(")"):
                    success_open = None
            block.append(cur)
            i += 1
        # Rewrite bind lines
        counter = 0
        new_block = []
        for bl in block:
            bm = re.match(r"^  use \$1 <- (field_text|opt_field_text|field_bool|field_int|field_float)\(\$2\)$", bl)
            if bm:
                kind = bm.group(1)
                if counter < len(success_names):
                    var = success_names[counter]
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
