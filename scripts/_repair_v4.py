"""Final repair: bind `use $1 <- ...($2)` to the right variable by reading
the corresponding `decode.success(X(field: name, field: name, ...))` literal."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Walk through the file: when we enter a `fn <X>_decoder()` block, find
# the matching `decode.success(<Type>(` literal in the same block; collect
# the `field:` names in order; use them to rename the bound variables.

lines = s.splitlines()
out = []
i = 0
while i < len(lines):
    ln = lines[i]
    m = re.match(r"^fn (\w+_decoder)\(\) -> decode\.Decoder\((\w+)\) \{$", ln)
    if m:
        decoder_name = m.group(1)
        out.append(ln)
        i += 1
        block_lines = []
        # Collect until matching closing `}` at top-level.
        depth = 1
        while i < len(lines) and depth > 0:
            cur = lines[i]
            if cur.strip() == "}":
                depth -= 1
                block_lines.append(cur)
                i += 1
                continue
            depth += cur.count("{") - cur.count("}")
            block_lines.append(cur)
            i += 1
        # Locate the success literal.
        success_idx = None
        success_names = []
        for j, bl in enumerate(block_lines):
            sm = re.match(r"^\s*decode\.success\(\s*$", bl)
            if sm:
                success_idx = j
                continue
            if success_idx is not None and j > success_idx:
                # collect `field: name,` lines until `))`
                nm = re.match(r"^\s*(\w+): \w+,?\s*$", bl)
                if nm:
                    success_names.append(nm.group(1))
                elif bl.strip().startswith("))"):
                    break
        # Rewrite `use $1 <- kind($2)` lines.
        counter = 0
        new_block = []
        for bl in block_lines:
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
for ln in remaining[:8]:
    print(ln)
