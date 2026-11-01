p = r'C:\home\Agents\effectivnost-360\services\frontend\src\effectivnost_360_lustre\phase8_view.gleam'
s = open(p, encoding='utf-8').read()

# Replace literal "\n" strings with actual newlines, but only in signature lines.
import re
# Find lines containing literal "\n"
fixed = []
for line in s.split('\n'):
    if '\\n' in line and 'fn(' in line or '\\n' in line and 'Element(' in line:
        # replace literal \n with actual newline and split
        parts = line.split('\\n')
        # First part stays, then newlines inserted
        for i, part in enumerate(parts):
            if i == 0:
                fixed.append(part)
            else:
                fixed.append('')
                fixed.append(part)
    else:
        fixed.append(line)

open(p, 'w', encoding='utf-8').write('\n'.join(fixed))
print('OK')
