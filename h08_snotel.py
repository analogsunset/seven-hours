"""
Match each resort to its nearest SNOTEL station and pull the measured record.

WHY DAILY AND NOT HOURLY. SNOTEL serves both, but accumulation must come from
daily. The sonic depth sensor reports to 1-inch resolution and jitters about an
inch every hour: the median NEGATIVE hourly step is exactly 1.00 in, which is
pure noise. Summing positive hourly steps over a season gives 2,762 in at
Snowbird against a published 838, and 5,448 at Wolf Creek against 430.
Differencing amplifies noise; levels do not. Daily differencing gives 321 and
279 in, which are sane.

WHY SWE AND NOT DEPTH for accumulation. Snow depth accumulation depends on how
often you clear the stake -- resorts clear every 6-12 hours and sum, SNOTEL
reads a settling pack, and the resort number is always larger. Water equivalent
is physically conserved and protocol-independent, so it is the comparable
quantity. Depth is still read as a LEVEL for base depth, where it is reliable.

QUALIFICATION. Distance alone is not enough; elevation is what decides whether
a station represents the ski terrain. Whitefish's nearest station is 31 km away
and 1,300 ft below mid-mountain, which is useless. The gate is distance <= 6 km
AND |elevation - mid_elevation| <= 1200 ft.

Writes _snotel_map.txt and _snotel_daily.txt for BULK INSERT.
"""
import csv, io, json, math, sys, time, urllib.request

CSV_PATH = 'ski_resort_stats_2026.csv'
BASE = 'https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1'
MAX_KM = 6.0
MAX_DELTA_FT = 1200.0
START, END = '1999-06-01', '2026-05-31'


def get(url, tries=6):
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=180) as r:
                return json.load(r)
        except Exception as e:
            if i == tries - 1:
                raise
            time.sleep(5 * (i + 1))   # the AWDB host drops connections intermittently


def km(a, b, c, d):
    R = 6371.0; p = math.pi / 180
    h = 0.5 - math.cos((c - a) * p) / 2 + math.cos(a * p) * math.cos(c * p) * (1 - math.cos((d - b) * p)) / 2
    return 2 * R * math.asin(math.sqrt(h))


def main():
    only = set(sys.argv[1:]) or None

    stations = [s for s in get(BASE + '/stations?networkCodes=SNTL&activeOnly=true')
                if s.get('latitude') and s.get('stationTriplet', '').endswith(':SNTL')]
    print('active SNOTEL stations:', len(stations))

    rows = list(csv.DictReader(io.open(CSV_PATH, encoding='utf-8-sig'), delimiter='|'))
    mapping = []
    for r in rows:
        try:
            la, lo = float(r['lat']), float(r['lon'])
        except Exception:
            continue
        d, s = min(((km(la, lo, x['latitude'], x['longitude']), x) for x in stations), key=lambda z: z[0])
        mid = r.get('mid_elevation')
        try:
            delta = abs(float(s['elevation']) - float(mid)) if mid else None
        except Exception:
            delta = None
        ok = 1 if (d <= MAX_KM and delta is not None and delta <= MAX_DELTA_FT) else 0
        mapping.append(dict(resort=r['resort_name'], triplet=s['stationTriplet'], station=s['name'],
                            km=round(d, 2), elev=s['elevation'],
                            delta=round(delta, 1) if delta is not None else '',
                            qualifies=ok))

    with io.open('_snotel_map.txt', 'w', encoding='utf-8', newline='\n') as fh:
        for m in mapping:
            fh.write('|'.join(str(m[k]) for k in
                     ('resort', 'triplet', 'station', 'km', 'elev', 'delta', 'qualifies')) + '\n')
    print('mapped %d resorts; %d qualify (<=%.0f km, <=%.0f ft)'
          % (len(mapping), sum(m['qualifies'] for m in mapping), MAX_KM, MAX_DELTA_FT))

    # pull the record for whichever resorts were named, else every qualifier
    want = [m for m in mapping if (m['resort'] in only if only else m['qualifies'])]
    print('fetching %d stations %s..%s' % (len(want), START, END))

    out = io.open('_snotel_daily.txt', 'w', encoding='utf-8', newline='\n')
    total = 0
    for m in want:
        u = (BASE + '/data?stationTriplets=' + urllib.parse.quote(m['triplet']) +
             '&elements=WTEQ,SNWD,PREC,TAVG&duration=DAILY&beginDate=' + START + '&endDate=' + END)
        try:
            d = get(u)
        except Exception as e:
            print('  %-28s FAILED %s' % (m['resort'], e)); continue
        if not d or not d[0].get('data'):
            print('  %-28s no data' % m['resort']); continue
        series = {}
        for b in d[0]['data']:
            code = b['stationElement']['elementCode']
            series[code] = {v['date']: v.get('value') for v in b['values']}
        dates = sorted(set().union(*[set(v) for v in series.values()]))
        n = 0
        for dt in dates:
            vals = [series.get(c, {}).get(dt) for c in ('WTEQ', 'SNWD', 'PREC', 'TAVG')]
            if all(v is None for v in vals):
                continue
            out.write('|'.join([m['resort'], m['triplet'], dt] +
                               ['' if v is None else str(v) for v in vals]) + '\n')
            n += 1
        total += n
        print('  %-28s %-22s %5.1f km  %6d days' % (m['resort'], m['station'], m['km'], n))
        time.sleep(1)
    out.close()
    print('total daily rows:', total)


if __name__ == '__main__':
    import urllib.parse
    main()
