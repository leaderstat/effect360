"""Final repair v12: last remaining use $1 line."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

old = """  let decoder = {
use $1 <- field_int($2)
    use total <- field_int(0)"""
new = """  let decoder = {
    use demo_data <- field_int(0)
    use total <- field_int(1)"""
if old in s:
    s = s.replace(old, new)
    print("ok")
else:
    print("NOT FOUND")

PATH.write_text(s, encoding="utf-8")
remaining = [ln for ln in s.splitlines() if ln.lstrip().startswith("use $1")]
print(f"remaining={len(remaining)}")
