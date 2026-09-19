"""Build the hosted payload: one small index plus one detail file per resort.

WHY THIS EXISTS ALONGSIDE h07_pack.py
-------------------------------------
h07_pack.py squeezes every day into 19 characters of a 92-character alphabet.
That exists for exactly one reason: a published artifact is a single
UNCOMPRESSED HTML file under 16 MB, and inside that constraint the packing is
the only way 154 resorts fit.

Served over HTTP the constraint inverts. Measured on this dataset, gzipped:

    packed alphabet   11.49 MB raw -> 6.69 MB gzip
    JSON columnar     27.53 MB raw -> 6.04 MB gzip

Columnar JSON is 10% SMALLER over the wire than the packing, because gzip finds
the structure the alphabet threw away. So the hosted build ships plain integers
and lets the transport compress them -- which also deletes the four-way
positional invariant between h14_export.sql, h07_pack.py, _hscript.js and
_hverify.js that has silently broken this project twice.

THE SPLIT. The grid must rank 431 resorts before it can draw anything, so
whatever the sort reads has to arrive up front; everything else can wait until a
card is on screen.

    index.json      tier + wind-held + cleared-the-week, one char per day,
                    plus the card metadata and the season-level fail counts.
                    ~420 KB gzipped for all 431 resorts.
    day/<slug>.json the other 16 fields, columnar, ~35 KB gzipped each.

Values are the SAME quantised integers h07_pack.py ships, just written as JSON
rather than alphabet offsets, so the two builds render identical numbers and the
verification can compare them directly.
"""
import io, json, math, os, re, gzip, collections

OUT = 'web'
r0 = lambda x: int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))
# Python rounds halves to EVEN and SQL Server rounds them away from zero. That
# split put 640 of 114,352 values one step off the database once. It applies to
# any integer we quantise, packed or not, so it survives the rewrite.

FAILS = ['Great', 'Rain on snow', 'Wind hold', 'Flat light', 'Too cold',
         'Too warm', 'Cloudy and cold', 'No week snow', 'No fresh snow', 'Grey']
FAIL_IX = {f: i for i, f in enumerate(FAILS)}

DAY_COLS = ['name', 'date', 'season', 'good', 'great', 'epic', 'covered', 'fresh',
            'app', 'sun', 'gust', 'hold', 'flat', 'snow72', 'base', 'reason',
            'measRel', 'vis', 'appLo', 'appHi', 'newSnow72', 'swe72', 'newSnow24',
            'failMask', 'temp', 'tempLo', 'tempHi',
            'opq', 'snow24', 'snow168', 'newSnow168', 'isWeek']

# the detail file's columns, in order. tier/held/week live in the index; `sun`
# is no longer displayed anywhere and `vis` is derivable from opq plus the
# flat-light bit, so neither is shipped.
DETAIL = ['app', 'appLo', 'appHi', 'temp', 'tempLo', 'tempHi',
          'opq', 'gust', 'reason', 'fail',
          'wkModel', 'wkMeas', 'd24Model', 'd24Meas', 'd72Meas', 'swe']

IDX = '0123456789ABCDEF'          # 16 values: tier | held<<2 | week<<3


def num(v, cast=float):
    v = v.strip()
    return cast(v) if v not in ('', 'NULL') else None


def slug(name):
    return re.sub(r'-+', '-', re.sub(r'[^a-z0-9]+', '-', name.lower())).strip('-')


# --------------------------------------------------------------- resort cards
weekcut, cut24, cards = {}, {}, []
for line in io.open('_resorts_all.txt', encoding='utf-8'):
    p = [x.strip() for x in line.rstrip('\n').split('|')]
    if len(p) != 30:
        continue
    nm = p[0]
    n = lambda i, cast=float: num(p[i], cast)
    try: weekcut[nm] = float(p[8])
    except Exception: pass
    try: cut24[nm] = float(p[29])
    except Exception: pass
    cards.append(dict(
        name=nm, slug=slug(nm), state=p[1], midFt=n(2, int), vert=n(3, int),
        acres=n(4, int), greenPct=n(5), greenAc=n(6, int), usd=n(7, int),
        weekCut=n(8), coverCut=n(9), modelSnowIn=n(10),
        snowSource=p[11], gauges=n(12, int), nearestKm=n(13),
        kappa=n(14), recall=n(15),
        cur=p[16] or None, peak=n(17, int), adv=n(18, int),
        map=(p[19] if p[19].startswith('https://') else None),
        region=p[20] or None,
        bluePct=n(21), blueAc=n(22, int), blackPct=n(23), blackAc=n(24, int),
        baseFt=n(25, int), summitFt=n(26, int), lifts=n(27, int), runs=n(28, int),
        cut24=n(29)))

by_name = {c['name']: c for c in cards}

# ------------------------------------------------------------------- the days
days = collections.defaultdict(lambda: collections.defaultdict(dict))
for line in io.open('_skidays_all.txt', encoding='utf-8'):
    parts = [x.strip() for x in line.rstrip().split('|')]
    if len(parts) != len(DAY_COLS):
        continue
    d = dict(zip(DAY_COLS, parts))
    nm = d['name']
    if nm not in by_name:
        continue
    try:
        sy = int(d['season'])
        app = float(d['app'])
        tmp = float(d['temp'])
        wk  = weekcut.get(nm)
        c24 = cut24.get(nm)
        n168, n72, n24 = num(d['newSnow168']), num(d['newSnow72']), num(d['newSnow24'])
        rec = dict(
            tier=3 if int(d['epic']) else (2 if int(d['great']) else (1 if int(d['good']) else 0)),
            app=r0(app),
            appLo=max(0, min(91, r0(app) - r0(float(d['appLo'])))),
            appHi=max(0, min(91, r0(float(d['appHi'])) - r0(app))),
            temp=r0(tmp),
            tempLo=max(0, min(91, r0(tmp) - r0(float(d['tempLo'])))),
            tempHi=max(0, min(91, r0(float(d['tempHi'])) - r0(tmp))),
            opq=r0(float(d['opq']) / 2.0) * 2,
            gust=r0(min(90.0, float(d['gust']))),
            reason=FAIL_IX.get(d['reason'], 0),
            fail=int(d['failMask']),
            isWeek=int(d['isWeek']),
            wkModel=r0(min(3.0, float(d['snow168']) / wk if wk else 0) * 30),
            wkMeas=(r0(min(3.0, n168 / 5.0) * 30) if n168 is not None else None),
            d24Model=r0(min(3.0, float(d['snow24']) / c24 if c24 else 0) * 30),
            d24Meas=(min(91, r0(n24)) if n24 is not None else None),
            d72Meas=(min(91, r0(n72)) if n72 is not None else None),
            swe=(min(91, r0(num(d['swe72']) * 10)) if num(d['swe72']) is not None else None))
    except Exception:
        continue
    days[nm][sy][d['date']] = rec

# ------------------------------------------------- index + per-resort details
import datetime

os.makedirs(os.path.join(OUT, 'day'), exist_ok=True)
index, detail_sizes = [], []

for c in cards:
    nm = c['name']
    seasons = sorted(days[nm])
    if not seasons:
        continue
    grid, cols, fails = [], {k: [] for k in DETAIL}, []
    for sy in seasons:
        s, fc = [], [0] * len(FAILS)
        d, end = datetime.date(sy, 12, 1), datetime.date(sy + 1, 4, 30)
        while d <= end:
            rec = days[nm][sy].get(d.strftime('%Y%m%d'))
            if rec is None:
                s.append(' ')
                for k in DETAIL:
                    cols[k].append(None)
            else:
                held = 1 if (rec['fail'] & 2) else 0
                # SQL's answer, not a re-derivation. This line used to read
                # rec['wkModel'] >= 30 -- modelled snow only -- so a gauged
                # resort's card disagreed with its own tiers on 98,896 days,
                # and _wverify.js re-derived it the same way and passed.
                week = rec['isWeek']
                s.append(IDX[rec['tier'] | (held << 2) | (week << 3)])
                fc[rec['reason']] += 1
                for k in DETAIL:
                    cols[k].append(rec[k])
            d += datetime.timedelta(days=1)
        grid.append(''.join(s))
        fails.append(fc)

    det = json.dumps([cols[k] for k in DETAIL], separators=(',', ':'))
    path = os.path.join(OUT, 'day', c['slug'] + '.json')
    io.open(path, 'w', encoding='utf-8').write(det)
    detail_sizes.append(len(gzip.compress(det.encode('utf-8'), 9)))

    # weekCut and cut24 both stay: the detail ships the ratios already, but the
    # card can name the lines, and anything checking this build has to be able
    # to recompute them. Carrying one and not the other was an oversight.
    entry = dict(c)
    entry.update(y0=seasons[0], s=grid, fails=fails)
    index.append(entry)

index.sort(key=lambda r: r['name'])

# --------------------------------------------------------------------- meta
row = io.open('_meta_all.txt', encoding='utf-8').read().strip().split('|')
keys = ['resorts', 'winters', 'hours', 'firstYear', 'lastYear',
        'refResorts', 'snotelReach', 'badged', 'minVert', 'loaded', 'eligible',
        'baseMeasuredPct', 'flatLightPct']
meta = {k: int(v) for k, v in zip(keys, row)}
if meta['resorts'] != len(index):
    raise SystemExit('meta says %d resorts, built %d -- the export and the build '
                     'disagree about coverage' % (meta['resorts'], len(index)))

per_season = []
for r in index:
    n = len(r['s'])
    epic = sum(1 for s in r['s'] for ch in s if ch != ' ' and (IDX.index(ch) & 3) == 3)
    per_season.append(epic / float(n))
meta.update(epicMin=round(min(per_season), 1), epicMax=round(max(per_season), 1),
            measured=sum(1 for r in index if r['snowSource'] == 'measured'),
            fails=FAILS, detail=DETAIL)

blob = json.dumps({'meta': meta, 'resorts': index}, separators=(',', ':'))
io.open(os.path.join(OUT, 'index.json'), 'w', encoding='utf-8').write(blob)

# -------------------------------------------------------------------- budgets
idx_gz = len(gzip.compress(blob.encode('utf-8'), 9))
print('resorts            : %d' % len(index))
print('index.json         : %.2f MB raw, %d KB gzip' % (len(blob) / 1048576.0, idx_gz / 1024))
print('day/*.json         : %d files, avg %d KB gzip, max %d KB gzip'
      % (len(detail_sizes), sum(detail_sizes) / len(detail_sizes) / 1024,
         max(detail_sizes) / 1024))
print('first paint        : %d KB gzip (index only)' % (idx_gz / 1024))

CAP_IDX_KB, CAP_DET_KB = 750, 60
if idx_gz / 1024 > CAP_IDX_KB:
    raise SystemExit('REFUSING: index.json is %d KB gzip, over the %d KB first-paint '
                     'budget. Move a field out of the index into the detail files.'
                     % (idx_gz / 1024, CAP_IDX_KB))
if max(detail_sizes) / 1024 > CAP_DET_KB:
    raise SystemExit('REFUSING: largest detail file is %d KB gzip, over the %d KB '
                     'budget.' % (max(detail_sizes) / 1024, CAP_DET_KB))
