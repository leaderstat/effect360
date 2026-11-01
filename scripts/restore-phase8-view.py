#!/usr/bin/env python3
"""Restore callback parameters in phase8_view.gleam signatures.

The earlier patcher stripped `on_X: fn(...) -> a` params from view
signatures, breaking the calls from app.gleam. This script re-adds them
so each view accepts the callbacks that app.gleam passes.
"""
import re

path = r'C:\home\Agents\effectivnost-360\services\frontend\src\effectivnost_360_lustre\phase8_view.gleam'
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

# Map: view name -> list of (param, type_sig)
views = {
    'dashboard': [
        ('on_refresh', 'fn() -> a'),
        ('on_open_settings', 'fn() -> a'),
        ('on_open_checks', 'fn() -> a'),
        ('on_open_exceptions', 'fn() -> a'),
        ('on_open_journal', 'fn() -> a'),
    ],
    'agent_checks': [
        ('on_recheck', 'fn(String) -> a'),
        ('on_refresh', 'fn() -> a'),
    ],
    'exceptions': [
        ('on_resolve', 'fn(String) -> a'),
        ('on_refresh', 'fn() -> a'),
    ],
    'journal': [
        ('on_filter_mode', 'fn(String) -> a'),
        ('on_refresh', 'fn() -> a'),
    ],
    'settings': [
        ('on_select_mode', 'fn(String) -> a'),
        ('on_save', 'fn() -> a'),
        ('on_refresh', 'fn() -> a'),
    ],
}

# For each view, find the signature and insert params.
# Use a regex that captures the opening `state: ... ,` chunk.
for view, params in views.items():
    # Locate the function: pub fn <name>(\n  ... -> Element(...))
    pattern = re.compile(
        rf'(pub fn {view}\(\n)((?:\s*\w+: [^\n]+,?\n)*?)(\s*\)\) -> Element\([^\)]+\) \{{)',
        re.MULTILINE,
    )
    m = pattern.search(src)
    if not m:
        print(f'NOT FOUND: {view}')
        continue
    head, body, tail = m.group(1), m.group(2), m.group(3)
    new_params = ''.join(f'  {name}: {sig},\n' for name, sig in params)
    new_sig = head + body + new_params + tail
    src = src[:m.start()] + new_sig + src[m.end():]

# Replace `-> Element(Msg)` -> `-> Element(a)` in view signatures.
src = re.sub(r'pub fn (\w+)\([^)]*?\) -> Element\(Msg\)', lambda m: '', src)
# Actually keep Msg as the return type and accept `a` as the callback generic.
# The function signature should be `-> Element(a)` since callbacks return `a`.
src = re.sub(r'(pub fn \w+\([^)]*?)\) )-> Element\(Msg\)', r'\1-> Element(a)', src)

with open(path, 'w', encoding='utf-8') as f:
    f.write(src)

print('OK')
