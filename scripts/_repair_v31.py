"""Final repair v31: remove the extra } added by v30."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

s = s.replace("}\n\npub fn parse_fields_jsonb", "\n\npub fn parse_fields_jsonb")

PATH.write_text(s, encoding="utf-8")
print("ok")
