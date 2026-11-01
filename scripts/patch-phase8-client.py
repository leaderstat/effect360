#!/usr/bin/env python3
"""Replace opt_string("name")("") calls with direct decode.optional_field."""
import re
import sys

path = r'C:\home\Agents\effectivnost-360\services\frontend\src\effectivnost_360_lustre\phase8_client.gleam'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Replace use X <- opt_string("NAME")("") with decode.optional_field call.
pattern = re.compile(r'use (\w+) <- opt_string\("([^"]+)"\)\(""\)')
def repl(m):
    var = m.group(1)
    name = m.group(2)
    return f'use {var}_raw <- decode.optional_field("{name}", "", decode.string)\n  use {var} <- decode.map({var}_raw, fn(v) {{ case v {{ "" -> None other -> Some(other) }} }})'

new_content = pattern.sub(repl, content)
with open(path, 'w', encoding='utf-8') as f:
    f.write(new_content)

print('OK')
