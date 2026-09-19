"""Run the whole hourly pipeline end to end, on a chosen subset of resorts.

    python run_pipeline.py "Showdown - MT" "Steamboat - CO"     # two resorts
    python run_pipeline.py --all                                # every json file
    python run_pipeline.py --all --skip-reset                   # keep the schema
    python run_pipeline.py --all --force                        # ignore the memory guard
    python run_pipeline.py --export-only                        # re-export + rebuild the page only
    python run_pipeline.py --web                                # hosted build: all 431, JSON, no packing

The arguments are FILE STEMS -- the hourly filename without its
_YYYYMMDD-YYYYMMDD.json range -- and they are passed straight through to
h02_shred.py. Everything downstream follows the data: ref.Resort always holds
all 431, but ResortBenchmark, SkiDay and the export only ever cover resorts
that actually have hours loaded, so a two-resort smoke test exercises exactly
the code the full build runs rather than a parallel copy of it.

WHY h20 RUNS TWICE. meteo.SnotelBenchmark scores ERA5 against the gauges, so it
reads meteo.SkiDay; meteo.usp_BuildSkiDay reads meteo.SnotelConsensus, which
h20 builds. The dependency is a genuine cycle. The first pass builds the
consensus and leaves the benchmark empty (h20 guards on SkiDay's existence),
h05 builds the model against the consensus, and the second pass fills in the
kappa and recall the resort cards print. SkiDay itself never reads the
benchmark, so it does not need a third pass.

SNOTEL is NOT re-fetched. _snotel_all.txt and _snotel_map_all.txt are 404
stations of daily record from the NRCS API and have nothing to do with the
Open-Meteo change; h19_snotel_all.py rebuilds them if they are ever lost.
"""
import io, os, re, subprocess, sys, time

SERVER, DB = 'NESO2', 'SKI_RESORT'
HERE = os.path.dirname(os.path.abspath(__file__))


def sh(label, argv, **kw):
    t = time.time()
    print('\n=== %s ===' % label, flush=True)
    p = subprocess.run(argv, cwd=HERE, **kw)
    if p.returncode:
        raise SystemExit('%s FAILED (exit %d)' % (label, p.returncode))
    print('--- %s ok, %.1fs' % (label, time.time() - t), flush=True)
    return p


# -l 30: fail the login after 30s rather than hanging forever. SQL Server on
# this box shares memory with a WSL2 VM, and when that VM balloons the instance
# gets paged out and stops answering logins while still reporting Running. An
# indefinite hang there looks exactly like a slow query; a login timeout says
# what actually happened.
SQLCMD = ['sqlcmd', '-E', '-S', SERVER, '-d', DB, '-b', '-l', '30']


def sql(script):
    """sqlcmd -b so any error aborts the run instead of scrolling past."""
    sh(script, SQLCMD + ['-i', os.path.join('sql', script)])


def sql_export(script, outfiles, all_resorts=0):
    """Run each query batch in an export script into its own file.

    h14_export.sql is three SELECTs -- the day rows, the resort cards and the
    one-row build facts the page's own prose is written from -- and sqlcmd
    would run them into one stream. Split on GO, keep the SET preamble
    in front of each, and capture them separately. -h -1 drops headers, -W
    trims padding and -w 8000 stops the long trail-map URLs from wrapping,
    which is what h07_pack.py's field-count check would otherwise trip over.

    all_resorts picks the coverage: 0 is the artifact's cut (>=899 ft, seven
    western regions, 154 resorts), 1 is everything in ref.Resort. It rides in as
    an sqlcmd -v INTEGER rather than the lists themselves, because sqlcmd 16
    refuses a -v value containing a space and every region name has one.
    """
    src = io.open(os.path.join(HERE, 'sql', script), encoding='utf-8').read()
    batches = [b for b in re.split(r'(?im)^\s*GO\s*$', src) if b.strip()]
    pre = [b for b in batches if 'SELECT' not in b.upper()]
    qs = [b for b in batches if 'SELECT' in b.upper()]
    if len(qs) != len(outfiles):
        raise SystemExit('%s has %d queries, expected %d' % (script, len(qs), len(outfiles)))
    for q, out in zip(qs, outfiles):
        tmp = os.path.join(HERE, '_export_batch.sql')
        io.open(tmp, 'w', encoding='utf-8', newline='\n').write('\n'.join(pre) + '\n' + q)
        sh('%s -> %s' % (script, out),
           SQLCMD + ['-h', '-1', '-W', '-w', '8000',
                     '-v', 'AllResorts=%d' % all_resorts, '-i', tmp, '-o', out])
        os.remove(tmp)
        n = sum(1 for _ in io.open(os.path.join(HERE, out), encoding='utf-8'))
        print('    %s: %d rows' % (out, n))


# A rebuild is destructive from its very first step: h00_reset drops every
# table before anything is rebuilt. So a run that dies halfway does not leave
# the old database intact -- it leaves a gutted one. That happened: SQL Server
# on this box shares 31.5 GB with a WSL2 VM hosting the local Open-Meteo
# instance, the VM ballooned to 14 GB, and the reset died on error 802
# (insufficient buffer pool memory) with the schema already half dropped.
#
# So the environment is checked BEFORE anything irreversible happens, not
# after. Refusing to start costs a rerun; stopping halfway costs the database.
MIN_FREE_MB = 1536


def preflight(destructive, force=False):
    print('\n=== preflight ===', flush=True)
    q = ("SET NOCOUNT ON; SELECT CONVERT(varchar(20), available_physical_memory_kb / 1024)"
         " + '|' + CONVERT(varchar(20), total_physical_memory_kb / 1024)"
         " + '|' + system_memory_state_desc FROM sys.dm_os_sys_memory;")
    p = subprocess.run(SQLCMD + ['-h', '-1', '-W', '-Q', q],
                       cwd=HERE, capture_output=True, text=True)
    if p.returncode or '|' not in p.stdout:
        raise SystemExit('cannot reach %s.%s -- is the service running?\n%s'
                         % (SERVER, DB, (p.stdout + p.stderr).strip()[:400]))
    free, total, state = [x.strip() for x in p.stdout.strip().splitlines()[0].split('|')]
    free, total = int(free), int(total)
    print('   %s reachable | RAM free %d MB of %d MB | %s' % (SERVER, free, total, state))
    if destructive and free < MIN_FREE_MB and not force:
        raise SystemExit(
            'REFUSING TO START: only %d MB free, need %d MB.\n'
            'This run begins by dropping every table, so starting now risks leaving the\n'
            'database half built. Free memory first (on this box the usual cause is the\n'
            'WSL2 VM behind h01_fetch.py --local holding ~14 GB; \'wsl --shutdown\' reclaims\n'
            'it, but that stops any fetch in flight), or pass --skip-reset to rebuild the\n'
            'model in place without dropping anything.\n'
            'Pass --force to override this and start anyway.' % (free, MIN_FREE_MB))
    elif destructive:
        print('   %s' % ('headroom OK for a destructive rebuild' if free >= MIN_FREE_MB
                         else '--force given: starting despite only %d MB free' % free), flush=True)


def main():
    args = sys.argv[1:]
    stems = [a for a in args if not a.startswith('-')]
    if not stems and not {'--all', '--export-only', '--web'} & set(args):
        raise SystemExit(__doc__)

    t0 = time.time()

    # The hosted build. Same model, same export SQL, different coverage and a
    # different shape on the way out: all 431 resorts, and JSON rather than the
    # packed alphabet, because the alphabet only ever paid for itself inside an
    # artifact's uncompressed single file. Gzipped, columnar JSON is ~10%
    # SMALLER than the packing it replaces.
    #
    # It writes to its own _*_all.txt files and never touches the artifact
    # build's inputs, so `--export-only` keeps producing the same self-contained
    # seven_hours.html it always did.
    if '--web' in args:
        preflight(destructive=False)
        sql_export('h14_export.sql',
                   ['_skidays_all.txt', '_resorts_all.txt', '_meta_all.txt'],
                   all_resorts=1)
        sh('h07_build.py', [sys.executable, 'h07_build.py'])
        # Same job _hverify.js does for the artifact: compare every shipped
        # value back to the SQL it came from, by name. It streams, because
        # 1.76M rows held as objects exhausts Node's default heap.
        sh('_wverify.js', ['node', '_wverify.js'])
        sh('h15_web.py', [sys.executable, 'h15_web.py'])
        print('\nweb build complete in %.1f min' % ((time.time() - t0) / 60))
        return

    # Page-only iteration. The model is 85 minutes to rebuild and does not
    # change when the page's markup does, so re-exporting from the database
    # already loaded is the loop for anything downstream of h05 -- filters,
    # prose, packing. Everything upstream is skipped.
    if '--export-only' in args:
        preflight(destructive=False)
        sql_export('h14_export.sql', ['_skidays.txt', '_resorts.txt', '_meta.txt'])
        sh('h07_pack.py', [sys.executable, 'h07_pack.py'])
        sh('_hverify.js', ['node', '_hverify.js'])
        sh('h15_build.py', [sys.executable, 'h15_build.py'])
        print('\nexport-only complete in %.1f min' % ((time.time() - t0) / 60))
        return

    preflight(destructive='--skip-reset' not in args, force='--force' in args)
    if '--skip-reset' not in args:
        sql('h00_reset.sql')
        sql('h01_schema.sql')
    sql('h03_reference.sql')

    sh('h02_shred.py', [sys.executable, 'h02_shred.py'] + stems)
    sql('h04_load_hourly.sql')

    sql('h20_snotel_all.sql')     # pass 1: consensus, benchmark left empty
    sql('h05_skiday.sql')         # the model
    sql('h20_snotel_all.sql')     # pass 2: score the model against the gauges

    sql_export('h14_export.sql', ['_skidays.txt', '_resorts.txt', '_meta.txt'])
    sh('h07_pack.py', [sys.executable, 'h07_pack.py'])
    # Decode the packed payload with the page's OWN decode() and compare every
    # field back to the SQL it came from. This is the check that catches the
    # two failures this pipeline has actually shipped: positional drift between
    # the packer and the page (which silently zeroed the snow bars), and a
    # rounding rule in one that does not match the other.
    sh('_hverify.js', ['node', '_hverify.js'])
    sh('h15_build.py', [sys.executable, 'h15_build.py'])

    print('\npipeline complete in %.1f min' % ((time.time() - t0) / 60))


if __name__ == '__main__':
    main()
