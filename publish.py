"""Mirror this project's SOURCE into a standalone git repo, ready for GitHub.

WHY A SEPARATE REPO. This directory lives inside D:\\TFS\\JTDEV, a private
monorepo of twenty-odd unrelated projects whose history contains blobs of
2,009 MB, 384 MB, 247 MB and 100 MB. GitHub hard-rejects any file over 100 MB,
so that history cannot be pushed at all -- not with a .gitignore, not without
rewriting it. And pushing it would publish nineteen other projects.

The part worth publishing is under a megabyte. So this copies the source into a
clean repo with no history to strip, and nothing generated: no intermediates, no
15 GiB of Open-Meteo JSON, no build output. Run it again after any change and it
re-mirrors, so the published copy never drifts from this one.

    python publish.py            # mirror + commit
    python publish.py --dry-run  # say what would change, touch nothing
"""
import io, os, shutil, subprocess, sys, filecmp

DEST = os.environ.get('SEVEN_HOURS_REPO', r'D:\TFS\seven-hours')
HERE = os.path.dirname(os.path.abspath(__file__))

# Everything that is SOURCE. Anything not listed is generated, an intermediate,
# or dead -- see REBUILD.md section 13.
FILES = [
    # the pipeline, in the order run_pipeline.py runs it
    'run_pipeline.py',
    'sql/h00_reset.sql', 'sql/h01_schema.sql', 'sql/h03_reference.sql',
    'h02_shred.py', 'sql/h04_load_hourly.sql',
    'sql/h20_snotel_all.sql', 'sql/h05_skiday.sql', 'sql/h14_export.sql',
    'h07_pack.py', '_hverify.js', 'h15_build.py',          # artifact build
    'h07_build.py', '_wverify.js', 'h15_web.py',           # hosted build
    '_hscript.js', '_hshell.html',                         # the page itself
    # fetchers. Not part of a rebuild -- the data is on disk -- but the only
    # way to regenerate it if it is ever lost.
    'h01_fetch.py', 'h19_snotel_all.py',
    # the calibration studies. They do not run in the pipeline; they are the
    # evidence behind the constants that do. REBUILD.md section 11.
    'h08_snotel.py', 'h16_calib.py',
    'sql/h06_trip.sql', 'sql/h09_snotel.sql', 'sql/h10_freshcheck.sql',
    'sql/h11_freshmatrix.sql', 'sql/h12_freshdepth.sql', 'sql/h13_snowsource.sql',
    'sql/h17_calibrate.sql', 'sql/h18_consensus.sql',
    # reference data and documentation
    'ski_resort_stats_2026.csv', 'weather_codes.txt', 'fail_rules.txt',
    'REBUILD.md', 'README.md',
    # the publish machinery travels with the repo so it stays reproducible
    'publish.py', 'deploy_pages.py',
]

GITIGNORE = """# Build output. Both builds regenerate all of this from the database; the
# hosted payload alone is 81 MB across 433 files and every build rewrites every
# one of them, so committing it here would add that much to history per build.
# It goes to the gh-pages branch instead -- see deploy_pages.py.
seven_hours.html
web/
_hviz.json
_hmeta.json

# Pipeline intermediates. _hourly.txt reached 14 GB; GitHub's hard limit is 100 MB.
_*.txt
_export_batch.sql

# Source data, far too large to version: 431 files, ~15 GiB.
json/

# Snapshots and backups
*.bak*
*.pre27-*
*.orig

__pycache__/
*.pyc
.claude/
.DS_Store

# deploy_pages.py stages the built site here before pushing it to gh-pages.
# It lives inside the repo so the worktree can reach it, and it is 91 MB.
.pages-build/
.pages-wt/
"""


def run(args, cwd=DEST, check=True):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and p.returncode:
        raise SystemExit('%s failed:\n%s%s' % (' '.join(args), p.stdout, p.stderr))
    return p.stdout.strip()


def main():
    dry = '--dry-run' in sys.argv

    missing = [f for f in FILES if not os.path.exists(os.path.join(HERE, f))]
    if missing:
        raise SystemExit('source files missing, refusing to publish a partial repo:\n  '
                         + '\n  '.join(missing))

    changed, added = [], []
    for f in FILES:
        src, dst = os.path.join(HERE, f), os.path.join(DEST, f.replace('/', os.sep))
        if not os.path.exists(dst):
            added.append(f)
        elif not filecmp.cmp(src, dst, shallow=False):
            changed.append(f)
        if not dry:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)

    # anything in the mirror that is no longer source
    stale = []
    if os.path.isdir(DEST):
        keep = {f.replace('/', os.sep) for f in FILES} | {'.gitignore', 'README.md'}
        for root, dirs, names in os.walk(DEST):
            dirs[:] = [d for d in dirs
                       if d not in ('.git', 'web', '__pycache__',
                                    '.pages-build', '.pages-wt')]
            for n in names:
                rel = os.path.relpath(os.path.join(root, n), DEST)
                if rel not in keep and not rel.startswith('.git'):
                    stale.append(rel)
                    if not dry:
                        os.remove(os.path.join(DEST, rel))

    print('%-10s %d' % ('added', len(added)))
    print('%-10s %d' % ('changed', len(changed)))
    print('%-10s %d' % ('removed', len(stale)))
    for f in (added + changed + stale)[:20]:
        print('   ', f)
    if dry:
        print('\n--dry-run: nothing written')
        return

    gi = os.path.join(DEST, '.gitignore')
    if not os.path.exists(gi) or io.open(gi, encoding='utf-8').read() != GITIGNORE:
        io.open(gi, 'w', encoding='utf-8', newline='\n').write(GITIGNORE)

    if not os.path.isdir(os.path.join(DEST, '.git')):
        run(['git', 'init', '-b', 'main'])
        print('\ninitialised a new repo at', DEST)

    run(['git', 'add', '-A'])
    if not run(['git', 'status', '--porcelain']):
        print('\nnothing to commit -- the published copy already matches this one')
        return
    print('\nstaged. Commit and push with:\n')
    print('    cd %s' % DEST)
    print('    git commit -m "Seven Hours: ski-day model and page"')
    print('    gh repo create seven-hours --public --source=. --push')
    print('\n(or create the repo in the browser and:')
    print('    git remote add origin https://github.com/<you>/seven-hours.git')
    print('    git push -u origin main)')


if __name__ == '__main__':
    main()
