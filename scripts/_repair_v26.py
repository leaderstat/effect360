"""Final repair v26: rename int_to_float to int.to_float, drop ratio/average_hours from let."""
from pathlib import Path

PATH = Path("services/api/src/effectivnost_360/moderation.gleam")
s = PATH.read_text(encoding="utf-8")

# Add `gleam/int` import if missing
if "import gleam/int" not in s:
    s = s.replace(
        "import gleam/bit_array",
        "import gleam/int\nimport gleam/bit_array",
    )

# Replace int_to_float with int.to_float.
s = s.replace("int_to_float(numerator)", "int.to_float(numerator)")
s = s.replace("int_to_float(denominator)", "int.to_float(denominator)")
s = s.replace("int_to_float(count)", "int.to_float(count)")

PATH.write_text(s, encoding="utf-8")
print("written")
