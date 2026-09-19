"""
Download one Open-Meteo hourly archive file per resort into json/hourly/.

Output name is "<stem>_<start><end>.json", e.g.

    Snowbird - UT_19990601-20260531.json

which is what h02_shred.py globs for. Two stems are deliberately shorter than
the resort name -- "Showdown - MT" and "Whitefish - MT" -- so the stem lives in
_coords.txt rather than being derived here.

BUDGET, NOT CALL COUNT
----------------------
Open-Meteo bills a request by weight, not by hitting the endpoint once:

    weight = (variables / 10) * (days / 14)

At 27 variables over 1999-06-01..2026-05-31 that is 9,862 days, so ONE resort
costs ~1,902 of the 10,000/day free-tier budget. Four resorts exhausts a day,
and the whole 431-resort list is ~820,000 units, or roughly 82 days. That is
the entire reason a full run appears to "stop working" partway: the quota is
spent, not broken.

None of which applies to --local, where the instance is yours. Against the
self-hosted server the binding constraint is not quota but latency: each cold
resort costs a few thousand sequential S3 range reads, which is what --jobs
overlaps.

So this script meters itself. It estimates the weight before each request,
refuses to start one it cannot afford, records what it spent in
_fetch_state.json, and says when the budget refills. Re-running is always safe:
completed files are verified and skipped, so a run resumed the next day picks
up exactly where the last one stopped.

An --api-key switches to customer-api.open-meteo.com, where the minute/hour/day
windows do not apply and the monthly allowance is the only ceiling.

ELEVATION IS NOT OPTIONAL
------------------------
Each request sends &elevation=<summit metres>. Without it the model answers for
its own grid cell -- 3062 m for Snowbird against a 2859 m summit -- and every
temperature is downscaled to the wrong altitude. The originals were pulled with
the override, so a file fetched without it silently disagrees with its
neighbours. verify() therefore checks the returned elevation and rejects a file
that came back on the grid height.

Writes:
    json/hourly/<stem>_<start><end>.json
    _fetch_state.json    rolling record of spent budget
"""
import argparse, csv, io, json, os, re, sys, threading, time
import urllib.error, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta

COORDS_PATH = '_coords.txt'
STATE_PATH = '_fetch_state.json'
OUT_DIR = os.path.join('json', 'hourly')

FREE_HOST = 'archive-api.open-meteo.com'
PAID_HOST = 'customer-api.open-meteo.com'

# A self-hosted instance (docker ghcr.io/open-meteo/open-meteo with
# REMOTE_DATA_DIRECTORY pointing at the S3 open-data bucket) serves the same
# /v1/archive from the same code, streaming ERA5 chunks on demand. Verified
# 2026-09-05 against Snowbird for January 2020: all 18 variables and every
# header field byte-identical to the public API, at 163 ms generation against
# the public endpoint's 11,363 ms. It is your machine, so no quota applies.
LOCAL_HOST = '127.0.0.1:8080'

# Must stay in lockstep with h02_shred.VARS AND with the column order of
# stg.HourlyRaw in sql/h01_schema.sql: the shred writes these columns in this
# order and BULK INSERT is positional, so a variable inserted here without the
# matching SQL column silently shifts every later column by one.
#
# 2026-09-05: cloud_cover and the radiation block were added, taking the list
# from 19 variables to 27. Positions matter -- cloud_cover goes in FRONT of the
# three layer fields and the radiation block sits between sunshine_duration and
# is_day, which is what the urls request and what the API returns.
#
# COST: weight is linear in variable count, so this raised the per-resort cost
# from ~1,338 to ~1,902 units. On the free tier's 10,000/day that is 4 resorts
# a day instead of 7. Note also that Open-Meteo names it terrestrial_radiation,
# NOT terrestrial_solar_radiation -- the latter is rejected by both endpoints.
VARS = ['temperature_2m', 'apparent_temperature', 'snowfall', 'snow_depth', 'rain',
        'cloud_cover', 'cloud_cover_low', 'cloud_cover_mid', 'cloud_cover_high',
        'weather_code',
        'wind_direction_100m', 'wind_direction_10m', 'wind_speed_100m',
        'wind_speed_10m', 'wind_gusts_10m', 'dew_point_2m', 'relative_humidity_2m',
        'sunshine_duration',
        'direct_normal_irradiance', 'diffuse_radiation', 'shortwave_radiation',
        'terrestrial_radiation',
        'direct_normal_irradiance_instant', 'diffuse_radiation_instant',
        'shortwave_radiation_instant', 'terrestrial_radiation_instant',
        'is_day']

START = '1999-06-01'
END = '2026-05-31'

# Free-tier ceilings, from open-meteo.com/en/pricing.
LIMIT_DAY = 10000
LIMIT_HOUR = 5000
LIMIT_MINUTE = 600

# Leave a little headroom: the server's accounting and ours will not agree to
# the decimal, and overshooting costs a 429 plus a wasted 22 MB transfer.
SAFETY = 0.95


# -- budget ----------------------------------------------------------------

def weight(n_vars, start, end):
    """Open-Meteo's fractional call weight for one single-location request."""
    days = (date.fromisoformat(end) - date.fromisoformat(start)).days + 1
    return (n_vars / 10.0) * (days / 14.0)


def load_state(path=STATE_PATH):
    try:
        with io.open(path, encoding='utf-8') as fh:
            state = json.load(fh)
    except (IOError, OSError, ValueError):
        state = {}
    state.setdefault('spends', [])
    return state


def save_state(state, path=STATE_PATH):
    # Anything older than a day cannot constrain us; drop it so the file does
    # not grow without bound.
    cutoff = time.time() - 86400
    state['spends'] = [s for s in state['spends'] if s['at'] > cutoff]
    with io.open(path, 'w', encoding='utf-8') as fh:
        json.dump(state, fh, indent=2)


def spent_since(state, seconds):
    cutoff = time.time() - seconds
    return sum(s['units'] for s in state['spends'] if s['at'] > cutoff)


def budget_report(state):
    return {
        'minute': (spent_since(state, 60), LIMIT_MINUTE),
        'hour': (spent_since(state, 3600), LIMIT_HOUR),
        'day': (spent_since(state, 86400), LIMIT_DAY),
    }


def wait_needed(state, units):
    """Seconds to wait before starting a request costing `units`.

    The test is whether a window is ALREADY spent, not whether this request
    would fit inside it. One 27-year call is worth 1,268 units against a
    600/minute ceiling, so "does it fit" is never satisfiable and would refuse
    to start anything. Open-Meteo does not pre-reject an oversized call either
    -- it serves it and then blocks whatever comes next until the window rolls
    forward. This mirrors that.

    Returns 0 to go now, a positive number of seconds to wait, or None if no
    amount of waiting helps.
    """
    waits = []
    for seconds, limit in ((60, LIMIT_MINUTE), (3600, LIMIT_HOUR), (86400, LIMIT_DAY)):
        if spent_since(state, seconds) < limit * SAFETY:
            continue
        # Window is spent. Wait for its oldest entry to age out.
        cutoff = time.time() - seconds
        inside = sorted(x['at'] for x in state['spends'] if x['at'] > cutoff)
        if not inside:
            return None
        waits.append(inside[0] + seconds - time.time() + 1)
    return max(waits) if waits else 0.0


def record(state, units):
    state['spends'].append({'at': time.time(), 'units': units})


# -- resorts ---------------------------------------------------------------

def load_resorts(path=COORDS_PATH):
    """ResortName|lat|lon|FileStem|elevation_m"""
    out = []
    with io.open(path, encoding='utf-8') as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('|')
            if len(parts) < 5:
                sys.exit('%s:%d: expected Name|lat|lon|stem|elevation_m'
                         % (path, lineno))
            out.append({
                'name': parts[0],
                'lat': float(parts[1]),
                'lon': float(parts[2]),
                'stem': parts[3],
                'elev': float(parts[4]),
            })
    return out


# The CSV is the source of truth: 431 resorts, each with a prebuilt URL in
# openmeteo_hourly_api_call. We send that URL verbatim rather than rebuilding
# it, so what goes out is exactly what the column says.
CSV_PATH = 'ski_resort_stats_2026.csv'

# Two files predate the CSV and were saved under a shortened name. Mapping to
# them here is what stops a full run from re-fetching 2,536 units of data that
# is already on disk.
STEM_ALIAS = {
    'Showdown Montana - MT': 'Showdown - MT',
    'Whitefish Mountain - MT': 'Whitefish - MT',
}


def safe_stem(name):
    """Windows rejects <>:"/\|?* in filenames. One resort has a slash."""
    return STEM_ALIAS.get(name) or re.sub(r'[<>:"/\|?*]', '-', name).strip()


def load_csv(path=CSV_PATH):
    """resort_name|...|openmeteo_hourly_api_call, pipe-delimited despite .csv"""
    out = []
    with io.open(path, encoding='utf-8-sig') as fh:
        for row in csv.DictReader(fh, delimiter='|'):
            url = (row.get('openmeteo_hourly_api_call') or '').strip()
            name = (row.get('resort_name') or '').strip()
            if not url or not name:
                continue
            q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            elev = q.get('elevation', [None])[0]
            out.append({
                'name': name,
                'stem': safe_stem(name),
                'url': url,
                'lat': float(q.get('latitude', [0])[0]),
                'lon': float(q.get('longitude', [0])[0]),
                # Four rows have no mid_elevation_meters, so their URL carries
                # no override and the model answers on its own grid. Nothing to
                # check against in that case.
                'elev': float(elev) if elev else None,
                'start': q.get('start_date', [START])[0],
                'end': q.get('end_date', [END])[0],
                'nvars': len(q.get('hourly', [''])[0].split(',')),
            })
    return out


def bands(resorts, n):
    """Split a geo-sorted list into n contiguous geographic bands.

    Each worker sweeps its own band in order, so its consecutive resorts keep
    hitting the chunks the previous one just cached. Round-robin would instead
    scatter every worker across the continent and make all of them cold at
    once, which is the opposite of what we want.
    """
    if n <= 1:
        return [resorts]
    size = (len(resorts) + n - 1) // n
    return [resorts[i:i + size] for i in range(0, len(resorts), size)]


def geo_sort(resorts):
    """Order so that geographic neighbours run consecutively.

    Against a self-hosted instance this is the single biggest speedup
    available. The server streams ERA5 chunks from S3 and caches them; a
    chunk spans one latitude row by six longitudes, so two resorts in the
    same range share almost all of their chunks. Measured cold vs warm on
    the same box: Alyeska in a fresh region took 654 s, Alta next door to an
    already-cached point took 2 s. Alphabetical order -- the CSV's order --
    bounces between Alaska and Vermont and pays the cold price nearly every
    time.

    Latitude is the primary key because it selects the chunk row.
    """
    return sorted(resorts, key=lambda r: (round(r.get('lat', 0.0) * 4),
                                          round(r.get('lon', 0.0) * 4)))


def out_path(stem, start, end, out_dir=OUT_DIR):
    tag = '%s-%s' % (start.replace('-', ''), end.replace('-', ''))
    return os.path.join(out_dir, '%s_%s.json' % (stem, tag))


def expected_hours(start, end):
    return ((date.fromisoformat(end) - date.fromisoformat(start)).days + 1) * 24


# -- validation ------------------------------------------------------------

def verify(path, start, end, variables, elev=None):
    """(ok, detail). A 22 MB file that parses is not necessarily complete."""
    try:
        with io.open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
    except (IOError, OSError) as exc:
        return False, 'unreadable (%s)' % exc
    except ValueError as exc:
        return False, 'not valid JSON (%s)' % exc

    hourly = doc.get('hourly') or {}
    times = hourly.get('time') or []
    want = expected_hours(start, end)
    if len(times) != want:
        return False, 'has %d hours, expected %d' % (len(times), want)

    missing = [v for v in variables if v not in hourly]
    if missing:
        return False, 'missing variables: %s' % ', '.join(missing)
    short = [v for v in variables if len(hourly[v]) != want]
    if short:
        return False, 'short arrays: %s' % ', '.join(short)

    # An elevation mismatch means the file came back on the model grid rather
    # than the summit, so its temperatures belong to a different altitude.
    got = doc.get('elevation')
    if elev is not None and (got is None or abs(float(got) - elev) > 0.5):
        return False, ('elevation %s, expected %s -- fetched without the '
                       'elevation override' % (got, elev))
    return True, '%d hours, %d vars, %.0f m' % (want, len(variables), float(got or 0))


# -- fetching --------------------------------------------------------------

def retarget(url, host):
    """Point a CSV url at a different host, query string untouched."""
    parts = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit(('http' if host.startswith('127.') else 'https',
                                    host, parts.path, parts.query, ''))


def build_url(resort, start, end, variables, api_key=None):
    """Mirrors the original pull exactly, elevation override included."""
    params = [
        ('latitude', '%.6f' % resort['lat']),
        ('longitude', '%.6f' % resort['lon']),
        ('start_date', start),
        ('end_date', end),
        ('hourly', ','.join(variables)),
        ('timezone', 'auto'),
        ('temperature_unit', 'fahrenheit'),
        ('wind_speed_unit', 'mph'),
        ('precipitation_unit', 'inch'),
        # %.4f, not %g: %g rounds to 6 significant digits, which turns
        # 2859.024 into 2859.02 and makes new files disagree with the
        # originals in _hourly_meta.txt for no reason.
        ('elevation', '%.4f' % resort['elev']),
    ]
    host = FREE_HOST
    if api_key:
        host = PAID_HOST
        params.append(('apikey', api_key))
    return 'https://%s/v1/archive?%s' % (host, urllib.parse.urlencode(params))


class RateLimited(Exception):
    def __init__(self, retry_after):
        Exception.__init__(self, 'rate limited')
        self.retry_after = retry_after


def _discard(path):
    try:
        os.remove(path)
    except OSError:
        pass


def _retry_after(headers, body):
    raw = headers.get('Retry-After') if headers else None
    if raw:
        try:
            return max(1.0, float(raw))
        except ValueError:
            pass
    # Open-Meteo says "Minutely API request limit exceeded" and similar. The
    # minute window is the only one worth actively waiting out in-run.
    if 'inutely' in body:
        return 60.0
    if 'ourly' in body:
        return 900.0
    return 3600.0


def _stream(url, part, timeout):
    req = urllib.request.Request(url, headers={
        'User-Agent': 'ski_resort_stats/1.0 (personal research)',
        'Accept': 'application/json',
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            with io.open(part, 'wb') as fh:
                while True:
                    chunk = resp.read(1 << 20)
                    if not chunk:
                        break
                    fh.write(chunk)
    except urllib.error.HTTPError as exc:
        body = exc.read(2000).decode('utf-8', 'replace')
        if exc.code == 429:
            raise RateLimited(_retry_after(exc.headers, body))
        reason = body
        try:
            reason = json.loads(body).get('reason', body)
        except ValueError:
            pass
        raise RuntimeError('HTTP %d: %s' % (exc.code, reason.strip()[:300]))


def download(url, dest, timeout=600):
    """Stream to <dest>.part, then rename. A partial file is never left behind
    under the real name, so 'file exists' always means 'file finished'."""
    part = dest + '.part'
    try:
        _stream(url, part, timeout)
    except BaseException:
        # Covers the errors raised out of _stream and a Ctrl-C landing
        # mid-transfer. None should leave 20 MB of half a resort on disk.
        _discard(part)
        raise
    os.replace(part, dest)
    return os.path.getsize(dest)


# -- main ------------------------------------------------------------------

def run(args):
    if args.csv:
        resorts = load_csv(args.csv)
        source = args.csv
    else:
        resorts = load_resorts(args.coords)
        source = args.coords
    for r in resorts:
        # A CSV row carries its own range in the URL; _coords.txt rows take
        # the command-line default.
        r.setdefault('start', args.start)
        r.setdefault('end', args.end)
        r.setdefault('nvars', len(VARS))

    if args.only:
        wanted = [w.lower() for w in args.only]
        resorts = [r for r in resorts
                   if any(w in r['name'].lower() or w in r['stem'].lower()
                          for w in wanted)]
        if not resorts:
            sys.exit('no resort in %s matched %s' % (source, ', '.join(args.only)))

    if args.geo_sort:
        resorts = geo_sort(resorts)

    os.makedirs(args.out_dir, exist_ok=True)
    state = load_state(args.state)
    for r in resorts:
        r['unit'] = weight(r['nvars'], r['start'], r['end'])
    total = sum(r['unit'] for r in resorts)

    print('%d resort(s) from %s' % (len(resorts), source))
    print('%.0f call units for the whole list' % total, end='')
    if args.host:
        print(' | %s -- self-hosted, no quota' % args.host)
    elif args.api_key:
        print(' | customer endpoint, free-tier windows not applied')
    else:
        rep = budget_report(state)
        print(' | free tier: day %.0f/%d, hour %.0f/%d' % (
            rep['day'][0], LIMIT_DAY, rep['hour'][0], LIMIT_HOUR))
        typical = resorts[0]['unit'] if resorts else 1.0
        room = int((LIMIT_DAY * SAFETY - rep['day'][0]) // typical)
        print('%.0f units each -> room for %d more today, %.1f days for the rest'
              % (typical, max(0, room), total / LIMIT_DAY))
    print('')

    ctl = {'done': 0, 'skipped': 0, 'failed': 0, 'throttled': 0,
           'lock': threading.Lock(), 'stop': False}

    jobs = max(1, args.jobs)
    if jobs > 1 and not (args.host or args.api_key):
        sys.exit('--jobs > 1 needs --local/--host or --api-key: against the free '
                 'tier the budget gate has to stay serial.')

    if jobs == 1:
        serial(resorts, args, state, ctl)
    else:
        # One contiguous geographic band per worker. Each cold request is
        # ~4,100 sequential S3 round-trips server-side at ~4% CPU and well
        # under a MB/s, so the work is latency-bound and overlapping it is
        # nearly free.
        groups = bands(resorts, jobs)
        print('%d worker(s) over bands of %s resorts'
              % (len(groups), '/'.join(str(len(g)) for g in groups)))
        print('')
        with ThreadPoolExecutor(max_workers=len(groups)) as pool:
            list(pool.map(lambda g: serial(g, args, state, ctl), groups))

    print('')
    print('%d downloaded, %d already present, %d failed, %d x 429 from the server'
          % (ctl['done'], ctl['skipped'], ctl['failed'], ctl['throttled']))
    return 1 if ctl['failed'] else 0


def say(ctl, msg):
    with ctl['lock']:
        print(msg, flush=True)


def bump(ctl, key, n=1):
    with ctl['lock']:
        ctl[key] += n


def serial(resorts, args, state, ctl):
    """Process a list of resorts in order. Safe to run several of these at once
    as long as each has its own slice -- they share only the counters and the
    print lock, and every resort writes to its own file."""
    for resort in resorts:
        if ctl['stop']:
            return
        start, end, unit = resort['start'], resort['end'], resort['unit']
        dest = out_path(resort['stem'], start, end, args.out_dir)
        label = resort['name']

        if os.path.exists(dest) and not args.force:
            ok, detail = verify(dest, start, end, VARS, resort['elev'])
            if ok:
                say(ctl, 'skip  %-24s %s' % (label, detail))
                bump(ctl, 'skipped')
                continue
            say(ctl, 'redo  %-24s existing file %s' % (label, detail))

        if args.dry_run:
            say(ctl, 'would %-24s -> %s' % (label, dest))
            continue

        # --trust-server: skip our own arithmetic and let Open-Meteo decide.
        # The published 600/min is smaller than a single 1,268-unit request, so
        # if that figure is stale our gate is throttling against a number that
        # does not exist. This asks, honours whatever 429 and Retry-After come
        # back, and records what the server actually enforced. The server stays
        # the authority either way -- the difference is that we stop guessing
        # on its behalf.
        if not args.api_key and not args.trust_server and not args.host:
            wait = wait_needed(state, unit)
            if wait is None:
                say(ctl, 'stop  %-24s one request (%.0f units) exceeds the whole '
                         'daily free-tier budget' % (label, unit))
                bump(ctl, 'failed')
                ctl['stop'] = True
                return
            if wait > args.max_wait:
                rep = budget_report(state)
                resume = datetime.now() + timedelta(seconds=wait)
                say(ctl, ('Budget spent after %d file(s) this run: %.0f/%d units'
                          ' today. Next request affordable at %s (in %.1f h).'
                          ' Re-run then -- finished files are skipped.')
                         % (ctl['done'], rep['day'][0], LIMIT_DAY,
                            resume.strftime('%Y-%m-%d %H:%M'), wait / 3600.0))
                ctl['stop'] = True
                return
            if wait > 0:
                say(ctl, 'wait  %-24s %.0f s for budget' % (label, wait))
                time.sleep(wait)

        # The CSV supplies a finished URL; only _coords.txt rows need one built.
        url = resort.get('url') or build_url(resort, start, end, VARS, args.api_key)
        if args.host:
            url = retarget(url, args.host)
        attempt = 0
        while True:
            attempt += 1
            started = time.time()
            try:
                size = download(url, dest, timeout=args.timeout)
            except RateLimited as exc:
                # The server counted the request even though it refused it.
                with ctl['lock']:
                    record(state, unit)
                    save_state(state, args.state)
                if attempt > args.retries:
                    say(ctl, 'fail  %-24s still rate limited after %d attempts'
                             % (label, attempt))
                    bump(ctl, 'failed')
                    break
                bump(ctl, 'throttled')
                nap = min(exc.retry_after, args.max_wait)
                say(ctl, '429   %-24s server says wait %.0f s (attempt %d)'
                         % (label, nap, attempt))
                time.sleep(nap)
                continue
            except (RuntimeError, urllib.error.URLError, OSError) as exc:
                if attempt > args.retries:
                    say(ctl, 'fail  %-24s %s' % (label, exc))
                    bump(ctl, 'failed')
                    break
                nap = min(30.0 * attempt, args.max_wait)
                say(ctl, 'retry %-24s %s (in %.0f s)' % (label, exc, nap))
                time.sleep(nap)
                continue

            with ctl['lock']:
                record(state, unit)
                save_state(state, args.state)
            ok, detail = verify(dest, start, end, VARS, resort['elev'])
            if not ok:
                say(ctl, 'fail  %-24s downloaded but %s' % (label, detail))
                bump(ctl, 'failed')
                break
            say(ctl, 'ok    %-24s %.1f MB, %s, %.0f s'
                     % (label, size / 1e6, detail, time.time() - started))
            bump(ctl, 'done')
            break

        if not args.api_key and not args.host:
            time.sleep(args.pause)


def main(argv=None):
    p = argparse.ArgumentParser(
        description='Download Open-Meteo hourly archives, one file per resort.')
    p.add_argument('--only', nargs='+', metavar='NAME',
                   help='substring match; download just these resorts')
    p.add_argument('--start', default=START)
    p.add_argument('--end', default=END)
    p.add_argument('--coords', default=COORDS_PATH)
    p.add_argument('--csv', nargs='?', const=CSV_PATH, default=None,
                   help='drive from %s and send its URLs verbatim' % CSV_PATH)
    p.add_argument('--out-dir', default=OUT_DIR,
                   help='where the json lands (default %s)' % OUT_DIR)
    p.add_argument('--state', default=STATE_PATH)
    p.add_argument('--api-key', default=os.environ.get('OPEN_METEO_API_KEY'),
                   help='commercial key; also read from OPEN_METEO_API_KEY')
    p.add_argument('--force', action='store_true', help='re-download complete files')
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--local', dest='host', action='store_const', const=LOCAL_HOST,
                   default=None, help='use the self-hosted instance at %s' % LOCAL_HOST)
    p.add_argument('--host', dest='host',
                   help='send to this host:port instead of Open-Meteo')
    p.add_argument('--jobs', type=int, default=1, metavar='N',
                   help='fetch N resorts at once; needs --local or --api-key')
    p.add_argument('--geo-sort', action='store_true',
                   help='run geographic neighbours together (big win with --local)')
    p.add_argument('--trust-server', action='store_true',
                   help='skip the local budget gate; request and let 429 govern')
    p.add_argument('--retries', type=int, default=3)
    p.add_argument('--pause', type=float, default=2.0,
                   help='seconds between requests (default 2)')
    p.add_argument('--max-wait', type=float, default=1800.0,
                   help='longest in-run wait; past this, stop and say when to resume')
    p.add_argument('--timeout', type=float, default=600.0,
                   help='per-request timeout; 27 years takes the server a while')
    return run(p.parse_args(argv))


if __name__ == '__main__':
    sys.exit(main())
