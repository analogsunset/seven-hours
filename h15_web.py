"""Assemble the hosted page: web/index.html + web/app.js.

The artifact build (h15_build.py) splices the shell, the whole payload and the
script into ONE file, because that is all an artifact can be. This one keeps the
same shell and the same script and changes only how the data arrives: fetch the
index, then load the script, which finds DATA and META already on window and
starts exactly as it does when they were inlined.

That is the whole trick, and it is why _hscript.js needed no restructuring of
its initialisation: it reads two globals, and it does not care who set them.
"""
import io, os, json, hashlib, re

SRC, OUT = '_hshell.html', 'web'

# The hand-written page, without any build output in it. Both builders read
# this; neither reads its own product any more.
shell = io.open(SRC, encoding='utf-8').read()

# Google Analytics 4, HOSTED BUILD ONLY. Deliberately not in _hshell.html, which
# both builds read: seven_hours.html is a single self-contained file meant to be
# published as a Claude artifact or handed around directly, and a published
# artifact's CSP does not admit googletagmanager.com, so the tag would fail there
# regardless -- and a tracker riding inside a file someone else hosts is a
# different question from one on a page we serve ourselves.
# Injected after <title> so the page_view fires before the payload fetch rather
# than behind it.
GA = """<!-- Google tag (gtag.js) -->
<script async src="https://www.googletagmanager.com/gtag/js?id=G-6P5RZ5GHRY"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());

  gtag('config', 'G-6P5RZ5GHRY');
</script>"""

_anchor = '<title>Seven Hours</title>'
if shell.count(_anchor) != 1:
    raise SystemExit('h15_web.py: cannot place the analytics tag -- expected exactly one '
                     '%r in %s, found %d' % (_anchor, SRC, shell.count(_anchor)))
shell = shell.replace(_anchor, _anchor + '\n' + GA, 1)

script = io.open('_hscript.js', encoding='utf-8').read().rstrip('\n')
digest = hashlib.sha1(script.encode('utf-8')).hexdigest()[:10]

# The build stamp h07_build.py put in index.json. The page already appends it
# to every day/*.json URL; index.json needs it too, and can only get it from
# here -- it is the file that carries the stamp, so it cannot version itself.
# cache: 'no-cache' is NOT enough alone: it forces revalidation, but the
# revalidation is answered by the CDN edge from its own copy while its
# max-age holds. That is how the 2026-09-20 deploy served a current app.js
# against a ten-minute-old index.json -- the script was new and the grid it
# read was one tier behind.
stamp = json.load(io.open(os.path.join(OUT, 'index.json'), encoding='utf-8'))['meta']['build']

# The artifact ships one file, so a stale cache is impossible. Hosted, the data
# and the code change on every rebuild while the URL does not, so the script is
# fingerprinted and the index carries a no-cache hint of its own.
boot = """<script>
(function(){
  var fail = function(msg){
    var g = document.getElementById('grids');
    if (g) g.innerHTML = '<div class="empty">Could not load the mountain data &mdash; '
                       + msg + '</div>';
  };
  fetch('index.json?v=__STAMP__', { cache: 'no-cache' })
    .then(function(r){ if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
    .then(function(j){
      window.DATA = j.resorts;
      window.META = j.meta;
      window.WEBBUILD = true;          // _hscript.js switches its data adapter on this
      var s = document.createElement('script');
      s.src = 'app.__HASH__.js';
      s.onerror = function(){ fail('the script did not load.'); };
      document.body.appendChild(s);
    })
    .catch(function(e){ fail(String(e && e.message || e)); });
})();
</script>
</body>
""".replace('__HASH__', digest).replace('__STAMP__', stamp)

os.makedirs(OUT, exist_ok=True)

# drop the stale fingerprinted scripts from previous builds
for f in os.listdir(OUT):
    if re.match(r'^app\.[0-9a-f]{10}\.js$', f) and f != 'app.%s.js' % digest:
        os.remove(os.path.join(OUT, f))

page = shell + boot
io.open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8', newline='\n').write(page)
io.open(os.path.join(OUT, 'app.%s.js' % digest), 'w', encoding='utf-8', newline='\n').write(script)

# same guard the artifact build carries: a mangled CSS escape once wrote a
# literal NUL that the browser drew as a replacement glyph mid-card
bad = sorted({ord(c) for c in page if ord(c) < 32 and c not in '\n\r\t'})
if bad:
    raise SystemExit('control characters in the built page: %s'
                     % ', '.join('U+%04X' % c for c in bad))

idx = os.path.getsize(os.path.join(OUT, 'index.json'))
print('web/index.html      : %d KB' % (len(page.encode('utf-8')) / 1024))
print('web/app.%s.js : %d KB' % (digest, len(script.encode('utf-8')) / 1024))
print('web/index.json      : %.2f MB raw' % (idx / 1048576.0))
print('\nserve web/ with gzip on .json and .js -- the whole design assumes it.')
