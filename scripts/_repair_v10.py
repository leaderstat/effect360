"""Final repair v10: small targeted patches."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# timeline_decoder: 2 missing → `actor_name`, `reason_code` at idx 4, 5
old_t = """fn timeline_decoder() -> decode.Decoder(TimelineEvent) {
  use id <- field_text(0)
  use $1 <- opt_field_text($2, None)
  use from_status <- field_text(1)
  use to_status <- field_text(2)
  use $1 <- opt_field_text($2, None)
  use $1 <- opt_field_text($2, None)
  use actor_role <- field_text(3)
  decode.success(TimelineEvent(
    id: id,
    from_status: from_status,
    to_status: to_status,
    actor_role: actor_role,
    actor_name: actor_name,
    reason_code: reason_code,
    created_at: created_at,
  ))
}
"""
new_t = """fn timeline_decoder() -> decode.Decoder(TimelineEvent) {
  use id <- field_text(0)
  use from_status <- field_text(1)
  use to_status <- field_text(2)
  use actor_role <- field_text(3)
  use actor_name <- opt_field_text(4, None)
  use reason_code <- opt_field_text(5, None)
  use created_at <- field_text(6)
  decode.success(TimelineEvent(
    id: id,
    from_status: from_status,
    to_status: to_status,
    actor_role: actor_role,
    actor_name: actor_name,
    reason_code: reason_code,
    created_at: created_at,
  ))
}
"""
if old_t in s:
    s = s.replace(old_t, new_t)
    print("timeline fixed")
else:
    print("timeline NOT found")

# applicant_request_decoder: 3 missing → created_at(3), submitted_at(4), updated_at(5)
old_a = """fn applicant_request_decoder() -> decode.Decoder(ApplicantRequest) {
  use id <- field_text(0)
  use status_text <- field_text(1)
  use $1 <- opt_field_text($2, None)
  use request_type <- field_text(2)
  use $1 <- opt_field_text($2, None)
  use $1 <- opt_field_text($2, None)
  use title <- field_bool(3)
  decode.success(ApplicantRequest(
    request_id: id,
    status: parse_status(status_text),
    request_type: request_type,
    created_at: created_at,
    submitted_at: submitted_at,
    updated_at: updated_at,
    has_response: has_response,
  ))
}
"""
new_a = """fn applicant_request_decoder() -> decode.Decoder(ApplicantRequest) {
  use id <- field_text(0)
  use status_text <- field_text(1)
  use request_type <- field_text(2)
  use created_at <- field_text(3)
  use submitted_at <- opt_field_text(4, None)
  use updated_at <- opt_field_text(5, None)
  use has_response <- field_bool(6)
  decode.success(ApplicantRequest(
    request_id: id,
    status: parse_status(status_text),
    request_type: request_type,
    created_at: created_at,
    submitted_at: submitted_at,
    updated_at: updated_at,
    has_response: has_response,
  ))
}
"""
if old_a in s:
    s = s.replace(old_a, new_a)
    print("applicant fixed")
else:
    print("applicant NOT found")

PATH.write_text(s, encoding="utf-8")
remaining = [ln for ln in s.splitlines() if ln.lstrip().startswith("use $1 <-")]
print(f"remaining={len(remaining)}")
for ln in remaining[:10]:
    print(ln)
