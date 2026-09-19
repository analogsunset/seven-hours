"""Assemble seven_hours.html from the shell, the packed payload and the script.

The page was hand-assembled once; this makes it repeatable, because the payload
now changes whenever the model or the SNOTEL comparison changes.
"""
import io, json

# The shell is its own file now. It used to be read back out of
# seven_hours.html -- this script's OWN output -- so the only copy of the
# hand-written page lived inside a 12 MB generated artifact, and a build that
# died between the read and the write would have taken it with it.
shell = io.open('_hshell.html', encoding='utf-8').read().rstrip('\n').split('\n')
shell.append('<script>')

data = io.open('_hviz.json', encoding='utf-8').read()
# The build's own scale. The page writes its every self-description from this
# rather than from text typed into the shell, so "9 resorts / 2.13 million
# hours" cannot go stale the next time the resort set changes.
meta = io.open('_hmeta.json', encoding='utf-8').read()
js = io.open('_hscript.js', encoding='utf-8').read().rstrip('\n')

# JSON.parse, not a JS object literal. The engine parses a 12 MB object literal
# as source (147 ms measured); the same bytes through JSON.parse take 14 ms --
# a 10x win for one line, and it matters at 230 resorts. json.dumps emits a
# correctly escaped JS string literal; the </ guard stops an embedded
# "</script>" from closing the tag early.
def js_string(text):
    return json.dumps(text).replace('</', '<\\/')

out = ('\n'.join(shell) + '\nconst DATA = JSON.parse(' + js_string(data) +
       ');\nconst META = ' + meta +
       ';\n' + js + '\n</script>\n')
io.open('seven_hours.html', 'w', encoding='utf-8', newline='\n').write(out)
# Control characters have no business in a rendered page, and one got in:
# a mangled CSS escape wrote a literal NUL, which the browser drew as a
# replacement glyph in the middle of a card. Cheap to check, invisible to miss.
_bad = sorted({ord(c) for c in out if ord(c) < 32 and c not in '\n\r\t'})
if _bad:
    raise SystemExit('control characters in the built page: %s'
                     % ', '.join('U+%04X' % c for c in _bad))

MB = len(out.encode('utf-8')) / 1048576.0
CAP_MB = 16.0          # the published-artifact ceiling
WARN_MB = 12.0         # heavy enough to be worth knowing before you publish

print('seven_hours.html: %.1f MB (%d KB)' % (MB, round(len(out) / 1024)))
if MB > CAP_MB:
    raise SystemExit(
        'REFUSING: %.1f MB exceeds the %.0f MB published-artifact limit.\n'
        'The payload is ~56 KB per resort, so this is the resort count, not the shell.\n'
        'Ship fewer characters per day, fewer resorts per page, or move the\n'
        'tooltip-only slots out of the page. Better to know now than at publish.'
        % (MB, CAP_MB))
if MB > WARN_MB:
    print('  WARNING: %.1f MB is within %.0f MB of the %.0f MB limit.'
          % (MB, CAP_MB - MB, CAP_MB))
