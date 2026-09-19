"""Pack the ski-day model into the payload the page ships with.

Per resort, per season, one string of eight characters per day covering Dec 1
to Apr 30: tier, felt temperature (mean, low and high), sun fraction, peak
gust, the measured 24- and 72-hour snowfall in inches plus the 72-hour water
equivalent, 72-hour
snow as a
multiple of that resort's own "fresh" threshold, the single reason the day
landed in its tier, what the day looked like, and -- where a SNOTEL station
stands close enough to the terrain -- the same figure from the MEASURED record.
36,756 days across 9 resorts and 27 winters comes to about 220 KB, so the whole
record travels with the page and the trip window stays selectable in the
browser.

Snow is carried RELATIVE to each resort's own fresh cut, not in inches,
because the modelled inches are 4-5x low by a factor that differs per resort.
A value of 1.0 means "this resort's 80th-percentile snowfall".

The sixth character is the same quantity built from MEASURED water equivalent:
a consensus of every SNOTEL station within 35 km, each normalised by its own
80th percentile before averaging, then divided by the resort's consensus fresh
line. Character 5 is what the model thought; character 6 is what the gauges
measured, on the same scale.
"""
import io, json, collections, math


def r0(x):
    """Round half AWAY FROM ZERO, the way T-SQL's ROUND does.

    Python rounds halves to even, so 14.5 packs as 14 while the model, which
    tested ROUND(MeanApparentF, 0) in SQL, saw 15. On the mean temperature that
    is the difference between a day reading "14F" and being rejected as too
    cold -- the exact contradiction the exact-integer packing exists to stop.

    EVERY quantised field goes through this, not just temperature. The sun
    fraction is the one that bites: meteo.vSkiDaySnow picks the Visibility
    label from ROUND(SunFraction * 90, 0) in T-SQL, so packing the same value
    with Python's banker's rounding let the two disagree by one step on exact
    halves -- a day could be labelled "Partly cloudy" beside a percentage that
    reads as Clear. Gust and the two snow multiples had the same split; it cost
    640 of 114,352 packed values a one-step drift from the SQL they came from.
    """
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))

A = ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
     "abcdefghijklmnopqrstuvwxyz"
     "!#$%&()*+,-./:;<=>?@[]^_{|}~" + chr(39) + chr(96))
assert len(A) >= 92 and '"' not in A and chr(92) not in A

# Must stay identical, and in the same order, to FAILS in _hscript.js and
# _hverify.js -- the index is what ships, not the string.
FAILS = ['Great', 'Rain on snow', 'Wind hold', 'Flat light', 'Too cold',
         'Too warm', 'Cloudy and cold', 'No week snow', 'No fresh snow', 'Grey']
FAIL_IX = {f: i for i, f in enumerate(FAILS)}

# Six opaque-cloud bands plus flat light, darkest first so the index still
# rises with the light. Replaces the old sunshine-fraction labels.
VIS = ['Flat light', 'Cloudy', 'Mostly cloudy', 'Partly sunny',
       'Mostly sunny', 'Sunny', 'Bluebird']
VIS_IX = {v: i for i, v in enumerate(VIS)}

# Felt temperature ships as an EXACT rounded integer. The alphabet holds 92
# values and the mean spans -41..60, so the window is -33..58: that clamps 7
# days out of 36,756, all of them far outside the 14-45F band the tiers test,
# so no clamped day can cross a threshold.
#
# The daily low and high ship as OFFSETS from that mean (mean-low, high-mean),
# never as absolute values. Packing them absolutely needed -41..65 and silently
# clamped 264 April highs to 51. The offsets top out at 34 and 20.
#
# The model's own cold/warm tests run on this same rounded mean, so a day can
# never read "14F" and be rejected as too cold.
TMIN, TMAX = -33, 58

# AIR temperature rides beside the felt one, and it ships as an OFFSET from
# the rounded felt mean -- the wind-chill gap -- rather than on a window of
# its own. The gap is tightly clustered (mean 7.4F, reaching 20.3F) and turns
# slightly negative on sunny days where the apparent reads above the air, so
# a bias of 20 covers -20..+71 with room to spare, where an absolute window
# would have had to straddle Alaskan Januarys and Arizona Aprils at once.
# The daily low and high then ride as offsets from the air mean, exactly as
# the felt low and high ride from theirs.
GAPMIN = -20

days = collections.defaultdict(lambda: collections.defaultdict(dict))
# per SEASON, not per resort: the page filters by year range, and the fail mix
# is season-level, so precomputing it here lets failCounts() add up a handful
# of integers instead of rescanning every packed day on every render.
fails = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
weekcut = {}
cut24 = {}
for line in io.open('_resorts.txt', encoding='utf-8'):
    q = [x.strip() for x in line.rstrip().split('|')]
    if len(q) == 30:
        # q[8] is the model-inch equivalent of a 5-inch week; q[29] the
        # equivalent of 2 inches in 24h. Both are what the packed snow slots
        # below are expressed as multiples of.
        try: weekcut[q[0]] = float(q[8])
        except Exception: pass
        try: cut24[q[0]] = float(q[29])
        except Exception: pass

# The day export's column order, straight from h14_export.sql. Reading fields
# by NAME rather than position is the whole point: inserting IsEpic in the
# middle shifted every later index by one, and a positional parser answers that
# by silently mis-typing every column after it.
DAY_COLS = ['name', 'date', 'season', 'good', 'great', 'epic', 'covered', 'fresh',
            'app', 'sun', 'gust', 'hold', 'flat', 'snow72', 'base', 'reason',
            'measRel', 'vis', 'appLo', 'appHi', 'newSnow72', 'swe72', 'newSnow24',
            'failMask', 'temp', 'tempLo', 'tempHi',
            'opq', 'snow24', 'snow168', 'newSnow168']


def num(v, cast=float):
    v = v.strip()
    return cast(v) if v not in ('', 'NULL') else None


for line in io.open('_skidays.txt', encoding='utf-8'):
    parts = [x.strip() for x in line.rstrip().split('|')]
    if len(parts) != len(DAY_COLS):
        continue
    d = dict(zip(DAY_COLS, parts))
    try:
        nm, dte, sy = d['name'], d['date'], int(d['season'])
        tier = 3 if int(d['epic']) else (2 if int(d['great']) else (1 if int(d['good']) else 0))
        app, sun, gust = float(d['app']), float(d['sun']), float(d['gust'])
        snow72 = float(d['snow72'])
        reason, vis = d['reason'], d['vis']
        meas = num(d['measRel'])
        alo, ahi = float(d['appLo']), float(d['appHi'])
        nsn, swe, n24 = num(d['newSnow72']), num(d['swe72']), num(d['newSnow24'])
        fmask = int(d['failMask'])
        tmp, tlo, thi = float(d['temp']), float(d['tempLo']), float(d['tempHi'])
        opq = float(d['opq'])
        s24, s168 = float(d['snow24']), float(d['snow168'])
        n168 = num(d['newSnow168'])
    except Exception:
        continue
    days[nm][sy][dte] = (
        A[tier],
        A[max(TMIN, min(TMAX, r0(app))) - TMIN],            # exact degrees F
        A[r0(sun * 90)],                                    # 0..1
        A[r0(min(90.0, gust))],                             # mph, capped at 90
        # A WEEK of snow as a multiple of this resort's 5-inch line, 0..3x ->
        # 0..90. Both Great paths require this to clear 1.0, so it is the single
        # most load-bearing number on the cell.
        A[r0(min(3.0, s168 / weekcut.get(nm, 1e9) if weekcut.get(nm) else 0) * 30)],
        # the same week, measured, as a multiple of a flat 5 inches
        (A[r0(min(3.0, n168 / 5.0) * 30)] if n168 is not None else ' '),
        A[FAIL_IX.get(reason, 0)],   # why this day landed where it did
        A[VIS_IX.get(vis, 4)],       # what it looked like
        A[max(0, min(91, r0(app) - r0(alo)))],     # degrees below the mean
        A[max(0, min(91, r0(ahi) - r0(app)))],     # degrees above the mean
        (A[min(91, r0(nsn))] if nsn is not None else ' '),        # in of new snow
        (A[min(91, r0(swe * 10))] if swe is not None else ' '),   # in of water x10
        (A[min(91, r0(n24))] if n24 is not None else ' '),        # in of new snow, 24h
        A[min(63, fmask)],   # every Good-tier test this day failed, as bit flags
        A[max(0, min(91, r0(tmp) - r0(app) - GAPMIN))],  # air temp, offset from felt
        A[max(0, min(91, r0(tmp) - r0(tlo)))],           # degrees below the air mean
        A[max(0, min(91, r0(thi) - r0(tmp)))],           # degrees above the air mean
        # opaque sky cover to half a percent, 0..100 -> 0..50. The band label in
        # slot 7 is derived from this same rounded value in SQL, so the two can
        # never disagree.
        A[max(0, min(91, r0(opq / 2.0)))],
        # 24h snow as a multiple of this resort's 2-inch line. Great's second
        # path and Epic both read it; shipped so an ungauged resort's tooltip
        # can still say how big the morning was.
        A[r0(min(3.0, s24 / cut24.get(nm, 1e9) if cut24.get(nm) else 0) * 30)],
    )
    fails[nm][sy][reason] += 1

out = []
for line in io.open('_resorts.txt', encoding='utf-8'):
    p = [x.strip() for x in line.rstrip('\n').split('|')]
    if len(p) != 30:
        continue
    nm = p[0]
    # sqlcmd renders NULLs as the literal 'NULL'; several resorts lack acreage,
    # a ticket price, or a published mid-elevation
    def num(i, cast=float):
        v = p[i].strip()
        return cast(v) if v not in ('', 'NULL') else None
    seasons = sorted(days[nm])
    # every season as a Dec 1 -> Apr 30 string, gaps left blank
    import datetime
    packed = []
    for sy in seasons:
        s = []
        d = datetime.date(sy, 12, 1)
        end = datetime.date(sy + 1, 4, 30)
        while d <= end:
            key = d.strftime('%Y%m%d')
            rec = days[nm][sy].get(key)
            s.append(''.join(rec) if rec else ' ' * 19)
            d += datetime.timedelta(days=1)
        packed.append(''.join(s))
    out.append(dict(
        name=nm, state=p[1], midFt=num(2, int), vert=num(3, int), acres=num(4, int),
        greenPct=num(5), greenAc=num(6, int), usd=num(7, int),
        weekCut=num(8), coverCut=num(9), modelSnowIn=num(10),
        snowSource=p[11], gauges=num(12, int), nearestKm=num(13),
        kappa=num(14), recall=num(15),
        # ticket prices in the resort's own currency; several have none published
        cur=p[16] or None, peak=num(17, int), adv=num(18, int),
        # only ever ship an https link; anything else is dropped rather than
        # rendered into an anchor
        map=(p[19] if p[19].startswith('https://') else None),
        region=p[20] or None,
        # the terrain split; green already ships above. Percentages are
        # shares of skiable acreage, and do not always total exactly 1.
        bluePct=num(21), blueAc=num(22, int),
        blackPct=num(23), blackAc=num(24, int),
        baseFt=num(25, int), summitFt=num(26, int),
        lifts=num(27, int), runs=num(28, int), cut24=num(29),
        y0=seasons[0], s=packed,
        fails=[[fails[nm][sy].get(f, 0) for f in FAILS] for sy in seasons],
    ))

out.sort(key=lambda r: r['name'])
js = json.dumps(out, separators=(',', ':'))
io.open('_hviz.json', 'w', encoding='utf-8').write(js)

# ---------------------------------------------------------------------------
# The build's own scale, for the prose. Everything the page asserts about
# ITSELF -- how many resorts, how many winters, how many hours -- is written
# from here rather than typed into the HTML, because typed counts were correct
# on the day they were typed and silently wrong every day after.
#
# EpicMin/EpicMax cannot come from SQL: they are the per-resort MEAN epic days
# per season, and only this script has the packed per-season day lists in hand.
# ---------------------------------------------------------------------------
meta = {}
try:
    row = io.open('_meta.txt', encoding='utf-8').read().strip().split('|')
    keys = ['resorts', 'winters', 'hours', 'firstYear', 'lastYear',
            'refResorts', 'snotelReach', 'badged', 'minVert', 'loaded', 'eligible',
            'baseMeasuredPct', 'flatLightPct']
    meta = dict(zip(keys, [int(x.strip()) for x in row]))
except Exception as e:
    raise SystemExit('cannot read _meta.txt (run h14_export.sql first): %s' % e)

epic_rates = []
for r in out:
    per = [sum(1 for d in days[r['name']][sy].values() if d[0] == A[3])
           for sy in sorted(days[r['name']])]
    if per:
        epic_rates.append(sum(per) / float(len(per)))
if epic_rates:
    meta['epicMin'] = round(min(epic_rates), 1)
    meta['epicMax'] = round(max(epic_rates), 1)

# how many of the shown resorts carry a measured-snow badge
meta['measured'] = sum(1 for r in out if r['snowSource'] == 'measured')

# The vertical cut is declared separately in each of h14_export.sql's three
# batches, because sqlcmd batches do not share variables. If those ever drift
# apart the card query and the day query would disagree about which resorts
# exist, and the page would ship cards with no days behind them. Cheaper to
# fail here than to publish that.
if meta['resorts'] != len(out):
    raise SystemExit(
        'resort-count mismatch: the card export has %d resorts, the meta row says %d.\n'
        'The vertical cut has drifted between the batches of h14_export.sql.'
        % (len(out), meta['resorts']))
io.open('_hmeta.json', 'w', encoding='utf-8').write(json.dumps(meta, separators=(',', ':')))
print('resorts:', len(out), '| seasons each:', sorted({len(r['s']) for r in out}))
print('season string lengths:', sorted({len(s) for r in out for s in r['s']}), '(= days x 19)')
print('KB:', round(len(js) / 1024))
print('fail categories:', FAILS)
print('meta:', meta)
