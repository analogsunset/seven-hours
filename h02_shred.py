"""
Flatten json/hourly/*.json into pipe-delimited text for BULK INSERT, and emit
the per-file header facts (grid point, timezone, units) as a second file.

Why not OPENJSON: each file is ~22 MB holding 18 parallel arrays of 236,688
elements. Shredding that in T-SQL needs a pass per variable per file. This
does the whole set in seconds.

Resort matching is by FILENAME, not coordinate. Two of the nine filenames are
shortened -- "Showdown - MT" for "Showdown Montana - MT" and "Whitefish - MT"
for "Whitefish Mountain - MT" -- so the rule is exact match first, then a
unique prefix within the same state suffix. Coordinates cannot be used: the
returned point is grid-snapped, and nearest-neighbour matching lands Heavenly's
file on Sierra-at-Tahoe and Snowbird's on Alta.

Writes:
    _hourly.txt        ResortName|ObsHour|18 measures
    _hourly_meta.txt   ResortName|FileName|start|end|hours|tz|utcoff|lat|lon|elev
    _hourly_units.txt  ResortName|variable|unit
"""
import csv, glob, io, json, os, re, sys

RANGE_RE = r'_\d{8}-\d{8}\.json$'   # the _YYYYMMDD-YYYYMMDD.json tail on every file

HOURLY_DIR = 'json/hourly'
CSV_PATH = 'ski_resort_stats_2026.csv'

# EXACTLY the order the urls request, because the flat file this writes is read
# by BULK INSERT, which matches on position and not on name. Change one and the
# other must move with it -- stg.HourlyRaw in h01_schema.sql is the mirror.
VARS = ['temperature_2m', 'apparent_temperature', 'snowfall', 'snow_depth', 'rain',
        'cloud_cover', 'cloud_cover_low', 'cloud_cover_mid', 'cloud_cover_high',
        'weather_code',
        'wind_direction_100m', 'wind_direction_10m', 'wind_speed_100m',
        'wind_speed_10m', 'wind_gusts_10m', 'dew_point_2m', 'relative_humidity_2m',
        'sunshine_duration',
        # The radiation block. sunshine_duration is a THRESHOLD (seconds above
        # 120 W/m2 of direct beam) and saturates: a dull hour under full cloud
        # at 230 W/m2 and a brilliant one at 915 both score 3600. These carry
        # the magnitude the threshold throws away. The four "_instant" twins are
        # the value at the timestamp; the plain four are the hour's mean.
        'direct_normal_irradiance', 'diffuse_radiation', 'shortwave_radiation',
        'terrestrial_radiation',
        'direct_normal_irradiance_instant', 'diffuse_radiation_instant',
        'shortwave_radiation_instant', 'terrestrial_radiation_instant',
        'is_day']

EXPECTED_UNITS = {
    'temperature_2m': '°F', 'apparent_temperature': '°F', 'dew_point_2m': '°F',
    'snowfall': 'inch', 'rain': 'inch', 'snow_depth': 'ft',
    'cloud_cover': '%', 'cloud_cover_low': '%', 'cloud_cover_mid': '%',
    'cloud_cover_high': '%',
    'relative_humidity_2m': '%', 'sunshine_duration': 's',
    'direct_normal_irradiance': 'W/m²', 'diffuse_radiation': 'W/m²',
    'shortwave_radiation': 'W/m²', 'terrestrial_radiation': 'W/m²',
    'direct_normal_irradiance_instant': 'W/m²', 'diffuse_radiation_instant': 'W/m²',
    'shortwave_radiation_instant': 'W/m²', 'terrestrial_radiation_instant': 'W/m²',
    'wind_speed_10m': 'mp/h', 'wind_speed_100m': 'mp/h', 'wind_gusts_10m': 'mp/h',
}


def resort_index():
    rows = list(csv.DictReader(io.open(CSV_PATH, encoding='utf-8-sig'), delimiter='|'))
    return {r['resort_name']: r for r in rows}


# The filename rule belongs to h01_fetch.py, which writes the files. These two
# must stay identical to h01_fetch.STEM_ALIAS / safe_stem.
STEM_ALIAS = {
    'Showdown Montana - MT': 'Showdown - MT',
    'Whitefish Mountain - MT': 'Whitefish - MT',
}
ILLEGAL = '<>:"/' + chr(92) + '|?*'


def safe_stem(name):
    """The filename h01_fetch.py writes for a resort. Windows rejects
    <>:"/BACKSLASH|?* so each becomes '-', and two resorts carry a short alias."""
    return STEM_ALIAS.get(name) or ''.join(
        '-' if c in ILLEGAL else c for c in name).strip()


def stem_index(names):
    """Filename -> resort, built FORWARDS from each resort name.

    The old rule guessed backwards from the filename: exact match, else a
    unique prefix within the same ' - ST' suffix. That is lossy, and it failed
    on the one resort whose name contains a character Windows will not put in a
    filename -- 'Boston Mills/Brandywine - OH' is written to disk as
    'Boston Mills-Brandywine - OH', and no prefix rule recovers the slash.
    Deriving the filename from the name instead is exact and needs no guessing.
    """
    ix = {}
    for n in names:
        st = safe_stem(n)
        if st in ix:
            raise SystemExit('two resorts share the filename %r: %r and %r'
                             % (st, ix[st], n))
        ix[st] = n
    return ix


def match_resort(stem, names, by_stem):
    """The resort whose filename is `stem`. Exact name first, so a file named
    after the resort itself still works; then the derived-filename index."""
    if stem in names:
        return stem
    if stem in by_stem:
        return by_stem[stem]
    raise SystemExit('cannot resolve %r to one resort' % (stem,))


def select_files(argv):
    """Every json/hourly/*.json, or only the stems named on the command line.

    A stem is the filename without the _YYYYMMDD-YYYYMMDD.json range, e.g.
    "Showdown - MT". Passing them explicitly is how a two-resort smoke test of
    the whole pipeline runs against the same code the full 431-resort build
    uses -- not a separate script that can drift away from it.
    """
    files = sorted(glob.glob(os.path.join(HOURLY_DIR, '*.json')))
    if not files:
        raise SystemExit('no files in ' + HOURLY_DIR)
    wanted = [a for a in argv if not a.startswith('-')]
    if not wanted:
        return files
    by_file = {re.sub(RANGE_RE, '', os.path.basename(f)): f for f in files}
    missing = [w for w in wanted if w not in by_file]
    if missing:
        raise SystemExit('no file for stem(s): %r' % missing)
    return [by_file[w] for w in wanted]


def main():
    names = resort_index()
    by_stem = stem_index(names)
    files = select_files(sys.argv[1:])
    print('shredding %d of %d file(s) in %s' %
          (len(files), len(glob.glob(os.path.join(HOURLY_DIR, '*.json'))), HOURLY_DIR))

    # Resolve EVERY filename before shredding any of them. The naming rule is
    # cheap to check and expensive to get wrong: at 431 files the old code got
    # 53 resorts and four minutes into the run before hitting a name it could
    # not place, having already written a multi-GB file that was then thrown
    # away. Failing on the whole set up front costs a second.
    pairs = []
    for path in files:
        stem = re.sub(RANGE_RE, '', os.path.basename(path))
        pairs.append((path, stem, match_resort(stem, names, by_stem)))

    out = io.open('_hourly.txt', 'w', encoding='utf-8', newline='\n')
    meta = io.open('_hourly_meta.txt', 'w', encoding='utf-8', newline='\n')
    units_out = io.open('_hourly_units.txt', 'w', encoding='utf-8', newline='\n')
    total = 0

    for path, stem, resort in pairs:
        with io.open(path, encoding='utf-8') as fh:
            doc = json.load(fh)

        h, u = doc['hourly'], doc.get('hourly_units', {})
        n = len(h['time'])
        for v in VARS:
            if v not in h:
                raise SystemExit('%s: missing variable %s' % (stem, v))
            if len(h[v]) != n:
                raise SystemExit('%s: %s has %d values, time has %d' % (stem, v, len(h[v]), n))
            if any(x is None for x in h[v]):
                raise SystemExit('%s: %s contains nulls' % (stem, v))
            exp = EXPECTED_UNITS.get(v)
            got = u.get(v, '')
            if exp and got.replace('Â', '') != exp:
                raise SystemExit('%s: %s unit is %r, expected %r' % (stem, v, got, exp))
            units_out.write('%s|%s|%s\n' % (resort, v, got))

        cols = [h[v] for v in VARS]
        t = h['time']
        w = out.write
        for i in range(n):
            w(resort + '|' + t[i].replace('T', ' ') + '|' +
              '|'.join(str(c[i]) for c in cols) + '\n')

        meta.write('|'.join(str(x) for x in [
            resort, os.path.basename(path), t[0][:10], t[-1][:10], n,
            doc.get('timezone', ''), doc.get('utc_offset_seconds', ''),
            doc.get('latitude', ''), doc.get('longitude', ''), doc.get('elevation', '')]) + '\n')

        total += n
        print('%-28s -> %-28s %7d hours  %s..%s' % (stem, resort, n, t[0][:10], t[-1][:10]))

    out.close(); meta.close(); units_out.close()
    print('\nresorts: %d   hourly rows: %d   _hourly.txt: %.1f MB'
          % (len(files), total, os.path.getsize('_hourly.txt') / 1048576))


if __name__ == '__main__':
    main()
