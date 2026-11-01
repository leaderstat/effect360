import re
p = r'C:\home\Agents\effectivnost-360\services\frontend\src\effectivnost_360_lustre\phase8_view.gleam'
s = open(p, encoding='utf-8').read()

patterns = [
    (r'on_recheck: fn\(String\) -> a,\) -> Element\(Msg\)',
     'on_recheck: fn(String) -> a,\n) -> Element(a)'),
    (r'on_resolve: fn\(String\) -> a,\) -> Element\(Msg\)',
     'on_resolve: fn(String) -> a,\n) -> Element(a)'),
    (r'on_filter_mode: fn\(String\) -> a,\) -> Element\(Msg\)',
     'on_filter_mode: fn(String) -> a,\n) -> Element(a)'),
    (r'state: s\.SettingsState,\s+on_save: fn\(\) -> a,\) -> Element\(Msg\)',
     'state: s.SettingsState,\n  on_save: fn() -> a,\n) -> Element(a)'),
    (r'on_save: fn\(\) -> a,\) -> Element\(Msg\)',
     'on_save: fn() -> a,\n) -> Element(a)'),
]
for old, new in patterns:
    new_count = len(re.findall(old, s))
    s = re.sub(old, new, s)
    print(f'{old[:50]}: replaced {new_count}')

open(p, 'w', encoding='utf-8').write(s)
print('OK')
