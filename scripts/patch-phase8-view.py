#!/usr/bin/env python3
"""Mass-patch phase8_view.gleam:
- Remove all `on_X: fn(...) -> a` callback params from view signatures.
- Replace every `event.on_click(fn(_) { on_X() })` with a `event.on_click(Msg)` value.
- Return `Element(Msg)` everywhere.
"""
import re

path = r'C:\home\Agents\effectivnost-360\services\frontend\src\effectivnost_360_lustre\phase8_view.gleam'
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

# Map callback name -> Msg variant
cb_to_msg = {
    'on_refresh': 'PanelRefresh',
    'on_open_settings': 'PanelOpenSettings',
    'on_open_checks': 'PanelOpenChecks',
    'on_open_exceptions': 'PanelOpenExceptions',
    'on_open_journal': 'PanelOpenJournal',
    'on_recheck': 'AgentRecheck',
    'on_resolve': 'ExceptionResolve',
    'on_filter_mode': 'JournalFilterChanged',
    'on_select_mode': 'SettingsModePicked',
    'on_save': 'SettingsSave',
}

# Replace event.on_click(fn(_) { on_X(...) }) -> event.on_click(MsgVariant(...))
def on_click_repl(m):
    body = m.group(1).strip()
    # find first callback name
    for cb, variant in cb_to_msg.items():
        if body.startswith(cb + '('):
            # extract argument(s)
            inside = body[len(cb):]  # "(arg)"
            args = inside.strip('()')
            return f'event.on_click({variant}({args}))'
        elif body == cb + '()':
            return f'event.on_click({variant})'
    return m.group(0)

src = re.sub(r'event\.on_click\(fn\(_\) \{ ([\w_]+\([^)]*\)) \}\)', on_click_repl, src)
src = re.sub(r'event\.on_click\(fn\(_\) \{ ([\w_]+\(\)) \}\)', on_click_repl, src)
src = re.sub(r'event\.on_click\(fn\(_\) \{ ([\w_]+) \}\)', on_click_repl, src)

# Remove callback parameters from function signatures
# Match: `on_name: fn(...) -> a,` (allow optional trailing space)
for cb in cb_to_msg.keys():
    src = re.sub(
        rf'\s*{cb}: fn\([^)]*\) -> a,\n',
        '',
        src,
    )

# Replace `-> Element(a)` -> `-> Element(Msg)`
src = src.replace('-> Element(a)', '-> Element(Msg)')

with open(path, 'w', encoding='utf-8') as f:
    f.write(src)

print('OK')
