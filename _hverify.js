// End-to-end check: decode the packed payload the page ships with, using the
// page's OWN decode(), and compare every field back to the SQL export it came
// from. This is what catches positional drift between h07_pack.py and
// _hscript.js -- the failure mode that silently zeroed the snow bars once.
const fs = require('fs');
const DATA = JSON.parse(fs.readFileSync('_hviz.json', 'utf8'));
const src = fs.readFileSync('_hscript.js', 'utf8');

// pull the alphabet and decode() straight out of the page script, so this
// checks the shipped code rather than a copy of it
// Take the alphabet and CODE lines VERBATIM. The 92-character alphabet holds
// ';' and '`' among its symbols, so anything that parses that expression
// rather than lifting the whole line truncates it at the first semicolon.
const lines = src.split('\n');
const aLine = lines.find(function(l){ return l.trim().indexOf('const A =') === 0; });
const cLine = lines.find(function(l){ return l.trim().indexOf('const CODE') === 0; });
const dStart = src.indexOf('function decode(s, i){');
const dEnd   = src.indexOf('\n}', dStart) + 2;
const decodeSrc = src.slice(dStart, dEnd);
const decode = new Function('return (function(){' + aLine + '\n' + cLine + '\n' +
                            decodeSrc + '\nreturn decode;})()')();
if (decode(' '.repeat(19), 0) !== null) throw new Error('decode() did not lift cleanly');

const COLS = ['name','date','season','good','great','epic','covered','fresh','app','sun','gust',
  'hold','flat','snow72','base','reason','measRel','vis','appLo','appHi','newSnow72','swe72',
  'newSnow24','failMask','temp','tempLo','tempHi',
  'opq','snow24','snow168','newSnow168','isWeek'];
const FAILS = ['Great','Rain on snow','Wind hold','Flat light','Too cold','Too warm',
               'Cloudy and cold','No week snow','No fresh snow','Grey'];
const VIS = ['Flat light','Cloudy','Mostly cloudy','Partly sunny',
             'Mostly sunny','Sunny','Bluebird'];

const sql = new Map();
for (const line of fs.readFileSync('_skidays.txt','utf8').split('\n')){
  const q = line.replace(/\r$/,'').split('|').map(function(s){ return s.trim(); });
  if (q.length !== COLS.length) continue;
  const o = {}; COLS.forEach(function(c,i){ o[c] = q[i]; });
  sql.set(o.name + '|' + o.date, o);
}
const weekCut = new Map(DATA.map(function(r){ return [r.name, r.weekCut]; }));
const cut24   = new Map(DATA.map(function(r){ return [r.name, r.cut24]; }));

function r0(x){ return x >= 0 ? Math.floor(x + 0.5) : -Math.floor(-x + 0.5); }
function clampApp(v){ return Math.max(-33, Math.min(58, r0(v))); }

const bad = []; let checked = 0, matched = 0;
for (const r of DATA){
  for (let j = 0; j < r.s.length; j++){
    const s = r.s[j], y = r.y0 + j, len = s.length / 19;
    for (let i = 0; i < len; i++){
      const d = decode(s, i);
      if (!d) continue;
      const dt = new Date(Date.UTC(y, 11, 1) + i * 86400000);
      const key = r.name + '|' + dt.toISOString().slice(0,10).replace(/-/g,'');
      const q = sql.get(key);
      if (!q){ bad.push(key + ': page has a day SQL does not'); continue; }
      matched++;
      const app = clampApp(+q.app);
      const chk = [
        ['tier', d.tier, (+q.epic ? 3 : (+q.great ? 2 : (+q.good ? 1 : 0)))],
        ['week', d.week, +q.isWeek],
        ['app',  d.app,  app],
        ['sun',  Math.round(d.sun * 90), Math.round(+q.sun * 90)],
        ['gust', d.gust, Math.round(Math.min(90, +q.gust))],
        ['why',  d.why,  FAILS.indexOf(q.reason)],
        ['vis',  d.vis,  VIS.indexOf(q.vis)],
        ['fail', d.fail, Math.min(63, +q.failMask)],
        ['lo',   d.lo,   app - Math.max(0, Math.min(91, r0(+q.app) - r0(+q.appLo)))],
        ['hi',   d.hi,   app + Math.max(0, Math.min(91, r0(+q.appHi) - r0(+q.app)))],
        // air temperature: the mean as a gap off the felt mean, the low and
        // high as offsets from that -- rebuilt here the way the packer built it
        ['temp', d.temp, app + Math.max(0, Math.min(91, r0(+q.temp) - r0(+q.app) + 20)) - 20],
        ['tlo',  d.tlo,  app + Math.max(0, Math.min(91, r0(+q.temp) - r0(+q.app) + 20)) - 20
                             - Math.max(0, Math.min(91, r0(+q.temp) - r0(+q.tempLo)))],
        ['thi',  d.thi,  app + Math.max(0, Math.min(91, r0(+q.temp) - r0(+q.app) + 20)) - 20
                             + Math.max(0, Math.min(91, r0(+q.tempHi) - r0(+q.temp)))],
        ['new24',   d.new24,   q.newSnow24 === '' ? null : Math.min(91, r0(+q.newSnow24))],
        ['newSnow', d.newSnow, q.newSnow72 === '' ? null : Math.min(91, r0(+q.newSnow72))],
        ['swe',     d.swe === null ? null : Math.round(d.swe * 10),
                    q.swe72 === '' ? null : Math.min(91, r0(+q.swe72 * 10))],
        // the week, modelled as a multiple of this resort's own 5-inch line
        ['snow', Math.round(d.snow * 30),
                 Math.round(Math.min(3, weekCut.get(r.name) ? +q.snow168 / weekCut.get(r.name) : 0) * 30)],
        // the same week, measured, against a flat 5 inches
        ['meas', d.meas === null ? null : Math.round(d.meas * 30),
                 q.newSnow168 === '' ? null : Math.round(Math.min(3, +q.newSnow168 / 5) * 30)],
        // opaque sky cover, and the morning against the 2-inch line
        ['opq',  d.opq, Math.max(0, Math.min(91, r0(+q.opq / 2))) * 2],
        ['s24',  Math.round(d.s24 * 30),
                 Math.round(Math.min(3, cut24.get(r.name) ? +q.snow24 / cut24.get(r.name) : 0) * 30)],
      ];
      for (const c of chk){
        checked++;
        if (c[1] !== c[2]) bad.push(key + ' ' + c[0] + ': page=' + c[1] + ' sql=' + c[2]);
      }
    }
  }
}
console.log('resorts:', DATA.length);
console.log('days decoded and matched to SQL:', matched, 'of', sql.size, 'SQL rows');
console.log('field comparisons:', checked);
console.log('MISMATCHES:', bad.length);
const byField = {};
bad.forEach(function(b){ const m = b.match(/ (\w+): page=/); const f = m ? m[1] : 'other'; byField[f] = (byField[f]||0)+1; });
Object.keys(byField).sort().forEach(function(f){ console.log('   ', f, byField[f]); });
bad.slice(0, 6).forEach(function(b){ console.log('   eg', b); });
if (bad.length) process.exit(1);
