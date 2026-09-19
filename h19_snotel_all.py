"""Map every resort to its whole SNOTEL neighbourhood, and pull the record.

The gate is now calibrated rather than guessed. Scoring 54 resort-station pairs
against the same model output showed kappa essentially FLAT from 0 to 35 km
(.635 / .599 / .634 / .608 by band) and near-flat against elevation offset
(.62 down to .60 across 0 to >1500 ft). The nearest station was the best one at
only 2 of 9 resorts. The ceiling is ERA5's ~25 km grid cell, not where the
gauge sits -- so a tight radius bought nothing and cost nine tenths of the
usable stations.

It also showed that a CONSENSUS of the neighbourhood beats any single station
at 8 of 9 resorts (mean kappa .632 -> .683), because independent sensor noise
averages out and the weather does not.

So: every station within 35 km, extended to 60 km where fewer than three are in
range. No elevation gate.

Writes _snotel_map_all.txt and _snotel_all.txt.
"""
import csv, io, json, math, os, sys, time, urllib.request, urllib.parse

CSV_PATH = 'ski_resort_stats_2026.csv'
BASE = 'https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1'
RADIUS_KM, FALLBACK_KM, MIN_STATIONS = 35.0, 60.0, 3
START, END = '1999-06-01', '2026-05-31'


def get(url, tries=6):
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=300) as r:
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
    dry = '--dry' in sys.argv
    stations = [s for s in get(BASE + '/stations?networkCodes=SNTL&activeOnly=true')
                if s.get('latitude') and s.get('stationTriplet', '').endswith(':SNTL')]
    rows = list(csv.DictReader(io.open(CSV_PATH, encoding='utf-8-sig'), delimiter='|'))

    pairs, need = [], set()
    for r in rows:
        try:
            la, lo = float(r['lat']), float(r['lon'])
        except Exception:
            continue
        near = sorted(((km(la, lo, s['latitude'], s['longitude']), s) for s in stations),
                      key=lambda z: z[0])
        got = [(d, s) for d, s in near if d <= RADIUS_KM]
        if len(got) < MIN_STATIONS:
            got = [(d, s) for d, s in near if d <= FALLBACK_KM][:MIN_STATIONS]
        for d, s in got:
            try:
                delta = float(s['elevation']) - float(r['mid_elevation'])
            except Exception:
                delta = None
            pairs.append((r['resort_name'], s['stationTriplet'], d, delta))
            need.add(s['stationTriplet'])

    covered = len({p[0] for p in pairs})
    print('resorts with at least one station: %d of %d' % (covered, len(rows)))
    print('resort-station pairs: %d | distinct stations to fetch: %d' % (len(pairs), len(need)))
    import collections
    cnt = collections.Counter(p[0] for p in pairs)
    print('stations per covered resort: median %d, max %d'
          % (sorted(cnt.values())[len(cnt)//2], max(cnt.values())))
    if dry:
        return

    with io.open('_snotel_map_all.txt', 'w', encoding='utf-8', newline='\n') as fh:
        for nm, t, d, dl in pairs:
            fh.write('%s|%s|%.2f|%s\n' % (nm, t, d, '' if dl is None else '%.1f' % dl))

    out = io.open('_snotel_all.txt', 'w', encoding='utf-8', newline='\n')
    n = 0
    for i, trip in enumerate(sorted(need), 1):
        u = (BASE + '/data?stationTriplets=' + urllib.parse.quote(trip) +
             '&elements=WTEQ,SNWD&duration=DAILY&beginDate=' + START + '&endDate=' + END)
        try:
            j = get(u)
        except Exception as e:
            print('  FAILED %s: %s' % (trip, e)); continue
        series = {}
        for b in (j[0].get('data') if j and j[0].get('data') else []):
            series[b['stationElement']['elementCode']] = {v['date']: v.get('value') for v in b['values']}
        w, sd = series.get('WTEQ', {}), series.get('SNWD', {})
        for dt in sorted(set(w) | set(sd)):
            wv, sv = w.get(dt), sd.get(dt)
            if wv is None and sv is None:
                continue
            out.write('|'.join([trip, dt, '' if wv is None else str(wv),
                                '' if sv is None else str(sv)]) + '\n')
            n += 1
        if i % 50 == 0:
            print('  %d/%d stations, %d rows' % (i, len(need), n))
        time.sleep(0.5)
    out.close()
    print('stations: %d | rows: %d' % (len(need), n))


if __name__ == '__main__':
    main()
