"""Calibrate the SNOTEL qualification gate instead of guessing it.

The original gate (<=6 km, <=1200 ft) was a guess, and the first nine resorts
suggested it was too strict: Whitefish's station is 30.9 km away and still
scored fifth of nine, Sun Valley's is 11.6 km and scored second. But nine
points is not a curve.

So: for each resort that HAS ERA5 hourly data, fetch not just the nearest
station but the K nearest inside a wide radius. Each one can be scored against
the same model output, which turns "does distance matter" into a measurable
decay curve rather than an opinion. The gate then goes wherever agreement
actually falls off.

Writes _snotel_calib.txt (resort|triplet|km|delta|date|wteq|snwd).
"""
import csv, io, json, math, sys, time, urllib.request, urllib.parse

CSV_PATH = 'ski_resort_stats_2026.csv'
BASE = 'https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1'
RADIUS_KM = 60.0
NEIGHBOURS = 6
START, END = '1999-06-01', '2026-05-31'
OUT = '_snotel_calib.txt'

# the resorts with ERA5 hourly data -- the only ones that can be scored
SCORED = [f.rsplit('_', 1)[0] for f in __import__('os').listdir('json/hourly')
          if f.endswith('.json')]


def get(url, tries=6):
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=180) as r:
                return json.load(r)
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(5 * (i + 1))


def km(a, b, c, d):
    R = 6371.0; p = math.pi / 180
    h = 0.5 - math.cos((c - a) * p) / 2 + math.cos(a * p) * math.cos(c * p) * (1 - math.cos((d - b) * p)) / 2
    return 2 * R * math.asin(math.sqrt(h))


def main():
    global OUT
    if len(sys.argv) > 1: OUT = '_snotel_calib2.txt'
    stations = [s for s in get(BASE + '/stations?networkCodes=SNTL&activeOnly=true')
                if s.get('latitude') and s.get('stationTriplet', '').endswith(':SNTL')]
    rows = {r['resort_name']: r for r in
            csv.DictReader(io.open(CSV_PATH, encoding='utf-8-sig'), delimiter='|')}

    def match(stem):
        """Same rule as h02_shred: exact name, else the unique CSV row starting
        with the base name and ending in the same ' - ST' suffix."""
        if stem in rows: return stem
        base, st = stem.rsplit(' - ', 1)
        c = [n for n in rows if n.startswith(base + ' ') and n.endswith(' - ' + st)]
        return c[0] if len(c) == 1 else None

    want = []   # (resort, station, km, delta)
    seen = set()
    only = set(sys.argv[1:])
    for nm in sorted(SCORED):
        if only and nm not in only: continue
        key = match(nm)
        if not key:
            print('  no CSV row for', nm); continue
        r = rows[key]
        la, lo = float(r['lat']), float(r['lon'])
        mid = r.get('mid_elevation')
        near = sorted(((km(la, lo, s['latitude'], s['longitude']), s) for s in stations),
                      key=lambda z: z[0])[:NEIGHBOURS]
        for d, s in near:
            if d > RADIUS_KM:
                continue
            try:
                delta = float(s['elevation']) - float(mid)
            except Exception:
                delta = None
            want.append((nm, s, d, delta))
            seen.add(s['stationTriplet'])

    print('%d resort-station pairs across %d distinct stations' % (len(want), len(seen)))

    cache = {}
    out = io.open(OUT, 'w', encoding='utf-8', newline='\n')
    n = 0
    for nm, s, d, delta in want:
        trip = s['stationTriplet']
        if trip not in cache:
            u = (BASE + '/data?stationTriplets=' + urllib.parse.quote(trip) +
                 '&elements=WTEQ,SNWD&duration=DAILY&beginDate=' + START + '&endDate=' + END)
            try:
                j = get(u)
            except Exception as e:
                print('  FAILED %s: %s' % (trip, e)); cache[trip] = []; continue
            series = {}
            for b in (j[0].get('data') if j and j[0].get('data') else []):
                series[b['stationElement']['elementCode']] = {v['date']: v.get('value') for v in b['values']}
            w = series.get('WTEQ', {}); sd = series.get('SNWD', {})
            cache[trip] = [(dt, w.get(dt), sd.get(dt)) for dt in sorted(set(w) | set(sd))]
            time.sleep(1)
        for dt, wv, sv in cache[trip]:
            if wv is None and sv is None:
                continue
            out.write('|'.join([nm, trip, '%.2f' % d,
                                '' if delta is None else '%.1f' % delta, dt,
                                '' if wv is None else str(wv),
                                '' if sv is None else str(sv)]) + '\n')
            n += 1
        print('  %-26s %-14s %5.1f km %8s ft' % (nm, trip, d,
              'n/a' if delta is None else '%+.0f' % delta))
    out.close()
    print('rows:', n)


if __name__ == '__main__':
    main()
