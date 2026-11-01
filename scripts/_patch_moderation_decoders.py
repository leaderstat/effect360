"""
scripts/_patch_moderation_decoders.py

Apply the Postgres-binary -> Gleam-String decoder fix to moderation.gleam.

pgo returns every text column as an Erlang binary (`BitArray`), but the
Gleam stdlib `decode.string` decoder expects a Gleam-String (a list of
UtfCodepoint).  These patches:

  1. Add `bit_array`, `field_text`, `opt_field_text`, `field_int`,
     `field_float`, `field_bool` helpers near the imports.
  2. Replace `use X <- decode.field(N, decode.string)` with
     `use X <- field_text(N)`, etc.
  3. Replace the small `status_decoder`, `request_id_decoder`,
     `count_decoder`, `optional_text_decoder` bodies with the new helpers.

Usage:  python scripts/_patch_moderation_decoders.py path/to/moderation.gleam
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

PATH = Path(sys.argv[1])
src = PATH.read_text(encoding="utf-8")

# -------------------------------------------------------------
# 1. Add helpers + bit_array import after the existing `import gleam/string`
# -------------------------------------------------------------
helpers = """
// -------------------------------------------------------------
// Postgres binary -> Gleam-String decoders
// -------------------------------------------------------------
//
// `pgo` returns every text column as an Erlang binary (`BitArray` in Gleam),
// but `decode.string` expects a Gleam-String (a list of `UtfCodepoint`).
// These helpers accept the field by index, coerce the binary to a String via
// `bit_array.to_string`, and feed the value to the next decoder step.

fn field_text(idx: Int, next) {
  use bits <- decode.field(idx, decode.bit_array)
  case bit_array.to_string(bits) {
    Ok(s) -> next(s)
    Error(_) -> decode.failure(Nil, decode.string)
  }
}

fn opt_field_text(idx: Int, default: Option(String), next) {
  use bits <- decode.optional_field(idx, Error(Nil), decode.optional(decode.bit_array))
  case bits {
    Ok(b) ->
      case bit_array.to_string(b) {
        Ok(s) -> next(Some(s))
        Error(_) -> next(default)
      }
    Error(_) -> next(default)
  }
}

fn field_int(idx: Int, next) {
  use n <- decode.field(idx, decode.int)
  next(n)
}

fn field_float(idx: Int, next) {
  use n <- decode.field(idx, decode.float)
  next(n)
}

fn field_bool(idx: Int, next) {
  use b <- decode.field(idx, decode.bool)
  next(b)
}
"""

if "fn field_text" not in src:
    src = src.replace(
        "import gleam/dict.{type Dict}\nimport gleam/dynamic/decode",
        "import gleam/bit_array\nimport gleam/dict.{type Dict}\nimport gleam/dynamic/decode",
    )
    src = src.replace("import gleam/string\n", "import gleam/string\n" + helpers)

# -------------------------------------------------------------
# 2. Rewrite small decoders
# -------------------------------------------------------------
src = src.replace(
    "fn status_decoder() -> decode.Decoder(Status) {\n  use raw <- decode.field(0, decode.string)\n  decode.success(parse_status(raw))\n}",
    "fn status_decoder() -> decode.Decoder(Status) {\n  use raw <- field_text(0)\n  decode.success(parse_status(raw))\n}",
)
src = src.replace(
    "fn request_id_decoder() -> decode.Decoder(String) {\n  use id <- decode.field(0, decode.string)\n  decode.success(id)\n}",
    "fn request_id_decoder() -> decode.Decoder(String) {\n  use id <- field_text(0)\n  decode.success(id)\n}",
)
src = src.replace(
    "fn count_decoder() -> decode.Decoder(Int) {\n  use value <- decode.field(0, decode.int)\n  decode.success(value)\n}",
    "fn count_decoder() -> decode.Decoder(Int) {\n  use value <- field_int(0)\n  decode.success(value)\n}",
)
src = src.replace(
    "fn optional_text_decoder() -> decode.Decoder(Option(String)) {\n  use value <- decode.optional_field(0, None, decode.optional(decode.string))\n  decode.success(value)\n}",
    "fn optional_text_decoder() -> decode.Decoder(Option(String)) {\n  use value <- opt_field_text(0, None)\n  decode.success(value)\n}",
)

# -------------------------------------------------------------
# 3. Field rewrite patterns (handled carefully — proper backrefs).
# -------------------------------------------------------------
patterns = [
    (re.compile(r"use (\w+) <- decode\.field\((\d+), decode\.string\)"),
     r"use \1 <- field_text(\2)"),
    (re.compile(r"use (\w+) <- decode\.optional_field\((\d+), None, decode\.optional\(decode\.string\)\)"),
     r"use \1 <- opt_field_text(\2, None)"),
    (re.compile(r"use (\w+) <- decode\.field\((\d+), decode\.bool\)"),
     r"use \1 <- field_bool(\2)"),
    (re.compile(r"use (\w+) <- decode\.field\((\d+), decode\.int\)"),
     r"use \1 <- field_int(\2)"),
    (re.compile(r"use (\w+) <- decode\.field\((\d+), decode\.float\)"),
     r"use \1 <- field_float(\2)"),
]
for pat, repl in patterns:
    src = pat.sub(repl, src)

PATH.write_text(src, encoding="utf-8")
print(f"patched {PATH}")
