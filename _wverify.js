// Does the hosted payload say what the database says?
//
// The artifact build's _hverify.js exists to catch POSITIONAL drift: four files
// had to agree on the order of 19 alphabet slots, and twice they quietly did
// not. The hosted build ships named JSON, so that failure mode is gone -- but a
// columnar file can still have two columns transposed, and the index derives
// three bits from fields it does not itself carry. So this checks the same
// thing by a different route: every value against the SQL export it came from,
// BY NAME.
//
// It STREAMS. _skidays_all.txt is 1.76 million rows for 431 resorts, and
// holding them as objects exhausts Node's default heap. The export is
// ORDER BY ResortName, ObsDate, so rows arrive grouped: accumulate one resort,
// verify it, discard it. Memory stays flat whatever the resort count.
const fs = require('fs');
const path = require('path');
const readline = require('readline');

const DAY_COLS = ['name','date','season','good','great','epic','covered','fresh',
  'app','sun','gust','hold','flat','snow72','base','reason','measRel','vis',
  'appLo','appHi','newSnow72','swe72','newSnow24','failMask','temp','tempLo',
  'tempHi','opq','snow24','snow168','newSnow168','isWeek','miss',
  'eq24','eq72','eq168'];
const C = {}; DAY_COLS.forEach((k, i) => { C[k] = i; });

const idx = JSON.parse(fs.readFileSync(path.join('web', 'index.json'), 'utf8'));
const FAILS = idx.meta.fails, DETAIL = idx.meta.detail;
const IDXCH = '0123456789ABCDEF';
const r0 = x => (x >= 0 ? Math.floor(x + 0.5) : -Math.floor(-x + 0.5));
const num = v => (v === '' || v === 'NULL' ? null : +v);

const byName = new Map(idx.resorts.map(r => [r.name, r]));
const bad = [];
let checked = 0, dayCount = 0, resortsSeen = 0;

function verifyResort(name, rows) {
  const r = byName.get(name);
  if (!r) { bad.push(name + ': in SQL but not in the index'); return; }
  resortsSeen++;

  const det = JSON.parse(fs.readFileSync(path.join('web', 'day', r.slug + '.json'), 'utf8'));
  const col = {}; DETAIL.forEach((k, i) => { col[k] = det[i]; });
  const cells = r.s.reduce((a, s) => a + s.length, 0);
  if (det.length !== DETAIL.length)
    bad.push(name + ': detail has ' + det.length + ' columns, expected ' + DETAIL.length);
  for (const k of DETAIL)
    if (col[k].length !== cells)
      bad.push(name + ' column ' + k + ': ' + col[k].length + ' values, grid has ' + cells);
  if (bad.length) return;

  const byDate = new Map(rows.map(q => [q[C.date], q]));
  let p = 0;
  for (let j = 0; j < r.s.length; j++) {
    const y = r.y0 + j, s = r.s[j], d0 = Date.UTC(y, 11, 1);
    for (let i = 0; i < s.length; i++, p++) {
      const key = new Date(d0 + i * 86400000).toISOString().slice(0, 10).replace(/-/g, '');
      const q = byDate.get(key);
      if (s[i] === ' ') { if (q) bad.push(name + '|' + key + ': index blank, SQL has it'); continue; }
      if (!q) { bad.push(name + '|' + key + ': index has a day SQL does not'); continue; }
      dayCount++;

      const v = IDXCH.indexOf(s[i]);
      const app = r0(+q[C.app]), tmp = +q[C.temp];
      const n168 = num(q[C.newSnow168]), n72 = num(q[C.newSnow72]),
            n24 = num(q[C.newSnow24]), swe = num(q[C.swe72]);

      const chk = [
        ['tier',  v & 3, (+q[C.epic] ? 3 : (+q[C.great] ? 2 : (+q[C.good] ? 1 : 0)))],
        ['held',  (v >> 2) & 1, ((+q[C.failMask] & 2) ? 1 : 0)],
        // against SQL's own verdict. This line used to recompute it from
        // modelled snow -- the same mistake the builder was making -- so the
        // check confirmed the bug instead of catching it.
        ['week',  (v >> 3) & 1, +q[C.isWeek]],
        ['app',      col.app[p],      app],
        ['appLo',    col.appLo[p],    Math.max(0, Math.min(91, app - r0(+q[C.appLo])))],
        ['appHi',    col.appHi[p],    Math.max(0, Math.min(91, r0(+q[C.appHi]) - app))],
        ['temp',     col.temp[p],     r0(tmp)],
        ['tempLo',   col.tempLo[p],   Math.max(0, Math.min(91, r0(tmp) - r0(+q[C.tempLo])))],
        ['tempHi',   col.tempHi[p],   Math.max(0, Math.min(91, r0(+q[C.tempHi]) - r0(tmp)))],
        ['opq',      col.opq[p],      r0(+q[C.opq] / 2) * 2],
        ['gust',     col.gust[p],     r0(Math.min(90, +q[C.gust]))],
        ['reason',   col.reason[p],   FAILS.indexOf(q[C.reason])],
        ['fail',     col.fail[p],     +q[C.failMask]],
        ['miss',     col.miss[p],     +q[C.miss]],
        // Modelled snow, converted by SQL to measured-equivalent inches.
        // Checked against the EXPORT's own conversion, not against a ratio
        // recomputed here from the cut -- the page must not own that scale
        // and neither must this.
        ['mEq168',   col.mEq168[p],   Math.min(91, r0(+q[C.eq168]))],
        ['mEq72',    col.mEq72[p],    Math.min(91, r0(+q[C.eq72]))],
        ['mEq24',    col.mEq24[p],    Math.min(91, r0(+q[C.eq24]))],
        // whole inches now; see h07_build.py for what the old multiple of
        // the 5-inch line did to the tooltip on 35,477 days.
        ['wkMeas',   col.wkMeas[p],   n168 === null ? null : Math.min(91, r0(n168))],
        ['d24Meas',  col.d24Meas[p],  n24 === null ? null : Math.min(91, r0(n24))],
        ['d72Meas',  col.d72Meas[p],  n72 === null ? null : Math.min(91, r0(n72))],
        ['swe',      col.swe[p],      swe === null ? null : Math.min(91, r0(swe * 10))]
      ];
      for (const c of chk) {
        checked++;
        if (c[1] !== c[2] && bad.length < 12)
          bad.push(name + '|' + key + ' ' + c[0] + ': web=' + c[1] + ' sql=' + c[2]);
      }
    }
  }
}

(async function main() {
  console.log('resorts in index :', idx.resorts.length);

  const rl = readline.createInterface({
    input: fs.createReadStream('_skidays_all.txt', { encoding: 'utf8' }),
    crlfDelay: Infinity
  });
  let cur = null, rows = [], sqlRows = 0;
  for await (const line of rl) {
    const q = line.split('|');
    if (q.length !== DAY_COLS.length) continue;
    for (let i = 0; i < q.length; i++) q[i] = q[i].trim();
    sqlRows++;
    if (q[0] !== cur) {
      if (cur !== null) verifyResort(cur, rows);
      cur = q[0]; rows = [];
      if (bad.length >= 12) break;
    }
    rows.push(q);
  }
  if (cur !== null && bad.length < 12) verifyResort(cur, rows);

  console.log('SQL day rows     :', sqlRows.toLocaleString());
  console.log('resorts verified :', resortsSeen);
  console.log('days checked     :', dayCount.toLocaleString());
  console.log('field comparisons:', checked.toLocaleString());
  console.log('MISMATCHES:', bad.length);
  bad.slice(0, 12).forEach(b => console.log('   ', b));
  if (bad.length) process.exit(1);

  // ---- parity with the artifact build, on the 154 resorts it covers --------
  // Counted from BOTH builds' own exports rather than against numbers typed in
  // here, which go stale the moment the model changes -- as they just did.
  //
  // BOTH SIDES COUNT THE TIER ORDINAL, not the three flags. This block used to
  // read `if (+q[C.good]) tiers.good++`, comparing a count of IsGood against a
  // count of tier >= 1 -- two different questions that gave the same answer only
  // while the tiers nested. Under the 2026-09-19 rules they do not: Epic is a
  // verdict about the snow rather than the top rung, and 7,291 Epic days sit
  // outside Good. The two counts then differ by exactly that population (5,319
  // of them within these 154 resorts) and this check failed on a difference that
  // was never in the payload. The ordinal is the right thing to compare: it is
  // what both builds ship, and what the page colours and counts cells by.
  const tiers = { good: 0, great: 0, epic: 0 };
  const subset = new Set();
  for (const line of fs.readFileSync('_skidays.txt', 'utf8').split('\n')) {
    const q = line.split('|');
    if (q.length !== DAY_COLS.length) continue;
    subset.add(q[0].trim());
    const t = +q[C.epic] ? 3 : (+q[C.great] ? 2 : (+q[C.good] ? 1 : 0));
    if (t >= 1) tiers.good++;
    if (t >= 2) tiers.great++;
    if (t >= 3) tiers.epic++;
  }
  let g = 0, gr = 0, ep = 0;
  for (const r of idx.resorts) {
    if (!subset.has(r.name)) continue;
    for (const s of r.s) for (const ch of s) {
      if (ch === ' ') continue;
      const t = IDXCH.indexOf(ch) & 3;
      if (t >= 1) g++;
      if (t >= 2) gr++;
      if (t >= 3) ep++;
    }
  }
  console.log('\nparity with the artifact build over its ' + subset.size + ' resorts:');
  const cmp = [['tier1+', g, tiers.good], ['tier2+', gr, tiers.great], ['tier3', ep, tiers.epic]];
  for (const [n, a, b] of cmp)
    console.log('  ' + n.padEnd(8) + 'hosted ' + a.toLocaleString().padStart(9) +
                '   artifact ' + b.toLocaleString().padStart(9) +
                (a === b ? '   match' : '   *** DIFFER ***'));
  if (cmp.some(([, a, b]) => a !== b)) { console.log('PARITY FAILED'); process.exit(1); }
  console.log('parity OK');
})();
