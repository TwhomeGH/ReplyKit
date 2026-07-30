import re

with open('liveAPP.xcodeproj/project.pbxproj', 'r', encoding='utf-8') as f:
    c = f.read()

# Check all section headers have corresponding end markers
sections = re.findall(r'/\* Begin (.+?) section \*/', c)
print('Sections found:', len(sections))

errors = 0
for s in sections:
    end_pattern = r'/\* End ' + re.escape(s) + r' section \*/'
    if not re.search(end_pattern, c):
        print('  MISSING END for section: ' + s)
        errors += 1

# Check widget target UUID
count = c.count('CE281B282E5ACD670023BBC4')
print('Widget target UUID occurrences: ' + str(count))

# Check for widget and activity kit references
print('liveAPPWidget references: ' + str(c.count('liveAPPWidget')))
print('ActivityKit references: ' + str(c.count('ActivityKit')))

# Check root object
ro = re.search(r'rootObject = ([A-F0-9]+)', c)
print('Root object: ' + (ro.group(1) if ro else 'MISSING'))

# Check project file is parseable by checking basic structure
if c.startswith('// !$*UTF8*$!'):
    print('UTF8 marker: OK')
else:
    print('UTF8 marker: MISSING - file may be corrupted')
    errors += 1

if errors == 0:
    print('ALL CHECKS PASSED')
else:
    print(str(errors) + ' ERROR(s) found')
