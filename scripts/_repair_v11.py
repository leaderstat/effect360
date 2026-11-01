"""Final repair v11: precise fix of the two remaining blocks."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

old = """fn applicant_request_decoder() -> decode.Decoder(ApplicantRequest) {
  use id <- field_text(0)
  use status_text <- field_text(1)
  use $1 <- opt_field_text($2, None)
  use request_type <- field_text(2)
  use $1 <- opt_field_text($2, None)
  use $1 <- opt_field_text($2, None)
  use title <- field_bool(3)
"""
new = """fn applicant_request_decoder() -> decode.Decoder(ApplicantRequest) {
  use id <- field_text(0)
  use status_text <- field_text(1)
  use request_type <- field_text(2)
  use created_at <- field_text(3)
  use submitted_at <- opt_field_text(4, None)
  use updated_at <- opt_field_text(5, None)
  use has_response <- field_bool(6)
"""
if old in s:
    s = s.replace(old, new)
    print("applicant fixed")
else:
    print("applicant NOT found")

# And one inline field_int: insert named binding.
old2 = """  use $1 <- field_int($2)
  decode.success(#("""
new2 = """  use demo_data -> field_int(0)
  decode.success(#("""
if old2 in s:
    s = s.replace(old2, new2)
    print("metrics inline fixed")
else:
    print("metrics inline NOT found")

PATH.write_text(s, encoding="utf-8")
remaining = [ln for ln in s.splitlines() if ln.lstrip().startswith("use $1")]
print(f"remaining={len(remaining)}")
