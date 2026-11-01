"""Final repair v32: ensure the file ends with a single `}`."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Insert the missing closing } right before parse_fields_jsonb.
old = """      ])]
    })
    Ok(_) -> Error(sql.QueryError("metrics query returned no row"))
  })
}

pub fn parse_fields_jsonb"""
new = """      ])]
    })
    Ok(_) -> Error(sql.QueryError("metrics query returned no row"))
  })
}


pub fn parse_fields_jsonb"""
# Try not to over-modify; just ensure closing brace is there exactly once.
# Count leading `}\n\n` before "pub fn parse_fields_jsonb".
idx = s.index("pub fn parse_fields_jsonb")
prefix = s[:idx]
last_50 = prefix[-60:]
print(repr(last_50))
