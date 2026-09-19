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

script = io.open('_hscript.js', encoding='utf-8').read().rstrip('\n')
digest = hashlib.sha1(script.encode('utf-8')).hexdigest()[:10]

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
  fetch('index.json', { cache: 'no-cache' })
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
""".replace('__HASH__', digest)

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
