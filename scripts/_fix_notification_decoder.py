"""Repair the notification_decoder that lost its variable names."""
from pathlib import Path
import re

p = Path("services/api/src/effectivnost_360/moderation.gleam")
src = p.read_text(encoding="utf-8")

old = """fn notification_decoder() -> decode.Decoder(Notification) {
  USE_FIELD_TEXT
  USE_OPT_FIELD_TEXT
  USE_FIELD_TEXT
  USE_FIELD_TEXT
  USE_FIELD_TEXT
  USE_FIELD_TEXT
  USE_OPT_FIELD_TEXT
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
if old in src:
    src = src.replace(old, new)
    p.write_text(src, encoding="utf-8")
    print("ok")
else:
    print("not found")
