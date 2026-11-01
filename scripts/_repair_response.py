"""Targeted fix for response_decoder + queue_decoder block that double-bound some fields."""
from pathlib import Path
import re

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Remove the duplicate v0..v3 lines and bind the remaining ones.
old = """fn response_decoder() -> decode.Decoder(OfficialResponse) {
  use id <- field_text(0)
  use request_id <- field_text(1)
  use subject <- field_text(2)
  use body <- field_text(3)
  use legal_basis <- field_text(4)
  use responsible_name <- field_text(5)
  use responsible_contact <- field_text(6)
  use registration_number <- field_text(7)
  use response_date <- field_text(8)
  use status_text <- field_text(9)
  use approved_by_name <- field_text(10)
  use approved_at <- field_text(11)
  use v0 <- field_text(0)
  use v1 <- field_text(1)
  use v2 <- field_text(2)
  use v3 <- field_text(3)
  use $1 <- opt_field_text($2, None)
  use $1 <- opt_field_text($2, None)
  decode.success(OfficialResponse(
    id: id,
    request_id: request_id,
"""
new = """fn response_decoder() -> decode.Decoder(OfficialResponse) {
  use id <- field_text(0)
  use request_id <- field_text(1)
  use subject <- field_text(2)
  use body <- field_text(3)
  use legal_basis <- field_text(4)
  use responsible_name <- field_text(5)
  use responsible_contact <- field_text(6)
  use registration_number <- field_text(7)
  use response_date <- field_text(8)
  use status_text <- field_text(9)
  use approved_by_name <- opt_field_text(10, None)
  use approved_at <- opt_field_text(11, None)
  decode.success(OfficialResponse(
    id: id,
    request_id: request_id,
"""
assert old in s, "anchor not found"
s = s.replace(old, new)
PATH.write_text(s, encoding="utf-8")
remaining = [ln for ln in s.splitlines() if re.match(r"^\s*use \$1 <- ", ln)]
print(f"remaining={len(remaining)}")
for ln in remaining[:8]:
    print(ln)
