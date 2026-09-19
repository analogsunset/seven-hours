"""Push the built page to a gh-pages branch, as a single orphan commit.

WHY ORPHAN. web/ is 81 MB across 433 files and every build rewrites all of them,
so an ordinary branch would accumulate ~81 MB of new blobs per deploy. An orphan
commit force-pushed each time has no parent, so the branch is always exactly one
snapshot and the repo stays the size of one build.

The trade is that gh-pages has no history. That is the right trade here: it is
output, reproducible from the database in under two minutes, and nothing about
last week's copy is worth 81 MB.

GitHub Pages serves .json and .js gzipped automatically, which is what the
587 KB first-paint figure assumes. Nothing else to configure.

    python deploy_pages.py            # build, stage, and show the push command
    python deploy_pages.py --push     # ...and actually force-push it
"""
import io, os, shutil, subprocess, sys

REPO = os.environ.get('SEVEN_HOURS_REPO', r'D:\TFS\seven-hours')
HERE = os.path.dirname(os.path.abspath(__file__))
STAGE = os.path.join(REPO, '.pages-build')


def run(args, cwd, check=True):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and p.returncode:
        raise SystemExit('%s failed:\n%s%s' % (' '.join(args), p.stdout, p.stderr))
    return p.stdout.strip()


def main():
    web = os.path.join(HERE, 'web')
    page = os.path.join(HERE, 'seven_hours.html')
    if not os.path.isdir(web):
        raise SystemExit('no web/ -- run:  python run_pipeline.py --web')
    if not os.path.isdir(os.path.join(REPO, '.git')):
        raise SystemExit('no repo at %s -- run publish.py first' % REPO)

    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE)
    shutil.copytree(web, STAGE)
    # the single-file artifact build rides along, so the same URL can offer it
    if os.path.exists(page):
        shutil.copy2(page, os.path.join(STAGE, 'seven_hours.html'))
    # Pages runs Jekyll by default, which would ignore files beginning with _
    # and try to render the rest. It has nothing to do here.
    io.open(os.path.join(STAGE, '.nojekyll'), 'w').write('')

    n = sum(len(f) for _, _, f in os.walk(STAGE))
    mb = sum(os.path.getsize(os.path.join(r, f))
             for r, _, fs in os.walk(STAGE) for f in fs) / 1048576.0
    print('staged %d files, %.1f MB, at %s' % (n, mb, STAGE))

    if '--push' not in sys.argv:
        print('\nNot pushed. To deploy:\n')
        print('    python deploy_pages.py --push')
        print('\nThen enable Pages on the gh-pages branch in the repo settings.')
        return

    # a worktree keeps the main checkout untouched while the orphan is built
    wt = os.path.join(REPO, '.pages-wt')
    run(['git', 'worktree', 'remove', '--force', '.pages-wt'], REPO, check=False)
    if os.path.isdir(wt):
        shutil.rmtree(wt, ignore_errors=True)
    run(['git', 'worktree', 'add', '--detach', '.pages-wt'], REPO)
    run(['git', 'checkout', '--orphan', 'gh-pages'], wt)
    run(['git', 'rm', '-rf', '--quiet', '.'], wt, check=False)
    for name in os.listdir(STAGE):
        s = os.path.join(STAGE, name)
        d = os.path.join(wt, name)
        (shutil.copytree if os.path.isdir(s) else shutil.copy2)(s, d)
    run(['git', 'add', '-A'], wt)
    run(['git', 'commit', '-m', 'Deploy Seven Hours'], wt)
    run(['git', 'push', '-f', 'origin', 'gh-pages'], wt)
    run(['git', 'worktree', 'remove', '--force', '.pages-wt'], REPO, check=False)
    print('\npushed to gh-pages. Enable Pages on that branch if you have not already.')


if __name__ == '__main__':
    main()
