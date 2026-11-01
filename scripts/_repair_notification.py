"""Final fix: repair notification_decoder field bindings."""
from pathlib import Path

p = Path("services/api/src/effectivnost_360/moderation.gleam")
s = p.read_text(encoding="utf-8")

old = """fn notification_decoder() -> decode.Decoder(Notification) {
  use $1 <- field_text($2)
  use $1 <- opt_field_text($2, None)
  use $1 <- field_text($2)
  use $1 <- field_text($2)
  use $1 <- field_text($2)
  use $1 <- field_text($2)
  use $1 <- opt_field_text($2, None)
  decode.success(Notification(
    id: id,
    request_id: request_id,
    kind: kind,
    title: title,
    body: body,
    created_at: created_at,
    read_at: read_at,
  ))
}
"""
new = """fn notification_decoder() -> decode.Decoder(Notification) {
  use id <- field_text(0)
  use request_id <- field_text(1)
  use kind <- field_text(2)
  use title <- field_text(3)
  use body <- field_text(4)
  use created_at <- field_text(5)
  use read_at <- opt_field_text(6, None)
  decode.success(Notification(
    id: id,
    request_id: request_id,
    kind: kind,
    title: title,
    body: body,
    created_at: created_at,
    read_at: read_at,
  ))
}
"""
if old in s:
    p.write_text(s.replace(old, new), encoding="utf-8")
    print("OK")
else:
    print("NOT_FOUND")
