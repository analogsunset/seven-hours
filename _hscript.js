/* ---------------------------------------------------------------------------
   All 27 winters ship with the page: NINETEEN characters per day for Dec 1 -
   Apr 30 -- tier, felt temperature and its daily range, air temperature and
   its range, sun fraction, opaque cloud, peak gust, the fail reason and mask,
   and the snow across three windows both modelled and measured.
   That is what keeps the trip window selectable in the browser.

   Seasons run Dec 1 for 151 days, or 152 when February has 29, so days are
   addressed by calendar date. Feb 29 is a real column that 20 of the 27
   winters do not have.
--------------------------------------------------------------------------- */
const A = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<=>?@[]^_{|}~'`";
const CODE = {}; for (let i = 0; i < A.length; i++) CODE[A[i]] = i;
const MS = 86400000;

/* ---- where a day comes from ---------------------------------------------
   Two builds feed this file, and nothing below this block knows which.

   The ARTIFACT build inlines the lot: one packed string per season, nineteen
   alphabet slots per day, decoded in place. It has no choice -- a published
   artifact is a single uncompressed file under 16 MB.

   The HOSTED build ships a one-character-per-day index up front (tier plus two
   bits) and fetches the other sixteen fields per resort as its card scrolls
   into view. Gzipped, that JSON is smaller than the packing it replaces.

   Ask for a day, get a plain object -- or null, in the hosted build, while its
   detail file is still in flight. Everything that ranks, filters or counts
   uses bitsAt() and never waits on the network; only the tooltip needs dayAt.
   --------------------------------------------------------------------------- */
const WEB = typeof WEBBUILD !== 'undefined' && WEBBUILD;
const IDXCH = '0123456789ABCDEF';
const DETAIL = new Map();              // slug -> columnar arrays, hosted only
const DI = {};                         // detail column name -> its index
if (WEB && META.detail) META.detail.forEach(function(k, i){ DI[k] = i; });

// Characters per packed day. h07_pack.py's DAYCH is the same number; it went
// 19 -> 20 when the modelled 72-hour window was added.
const DAYCH = 20;
const dayLen = (r, j) => (WEB ? r.s[j].length : r.s[j].length / DAYCH);

/* Tier, plus the two things a card counts but cannot read from the tier alone:
     bit 2  the wind took the day (gusts over half of it)
     bit 3  the week test the TIERS used passed -- measured where a gauge
            reported that day, modelled otherwise
   -1 means the record has no such day. */
function bitsAt(r, j, i){
  if (WEB){
    const ch = r.s[j][i];
    return ch === ' ' ? -1 : IDXCH.indexOf(ch);
  }
  const o = decode(r.s[j], i);
  if (!o) return -1;
  return o.tier | ((o.fail & 2) ? 4 : 0) | (o.week ? 8 : 0);
}

function dayAt(r, j, i){
  if (!WEB) return decode(r.s[j], i);
  const d = DETAIL.get(r.slug);
  if (!d || r.s[j][i] === ' ') return null;
  let p = i;
  for (let k = 0; k < j; k++) p += r.s[k].length;
  const at = k => d[DI[k]][p];
  const app = at('app'), temp = at('temp'), fail = at('fail'), opq = at('opq');
  const wkMeas = at('wkMeas'), swe = at('swe');
  // the sky band is derivable, so it is not shipped: flat light outranks the
  // six cover bands, exactly as meteo.vSkiDaySnow decides it
  const band = (fail & 4) ? 0
    : opq <= 5 ? 6 : opq <= 12.5 ? 5 : opq <= 37.5 ? 4
    : opq <= 62.5 ? 3 : opq <= 87.5 ? 2 : 1;
  return { tier: IDXCH.indexOf(r.s[j][i]) & 3,
           app: app, lo: app - at('appLo'), hi: app + at('appHi'),
           temp: temp, tlo: temp - at('tempLo'), thi: temp + at('tempHi'),
           opq: opq, gust: at('gust'), why: at('reason'), fail: fail, vis: band,
           // Whole inches on both sides now. The MEASURED trio is what the
           // gauges weighed; the mEq trio is the modelled snowfall converted
           // by SQL back to the scale a gauge would have reported it on, so
           // one tooltip serves a resort with a gauge and one without.
           meas: wkMeas,
           miss: at('miss'),
           new24: at('d24Meas'), newSnow: at('d72Meas'),
           mEq24: at('mEq24'), mEq72: at('mEq72'), mEq168: at('mEq168'),
           swe: swe === null ? null : swe / 10 };
}

/* One fetch per resort, the first time its card is drawn. 431 files of ~35 KB;
   a screenful is six of them. Failures are silent and retried on the next
   render -- a missing detail file costs a tooltip, not the page. */
const PENDING = new Set();
function needDetail(r){
  if (!WEB || DETAIL.has(r.slug) || PENDING.has(r.slug)) return;
  PENDING.add(r.slug);
  fetch('day/' + r.slug + '.json')
    .then(x => x.ok ? x.json() : Promise.reject(x.status))
    .then(function(d){
      DETAIL.set(r.slug, d);
      PENDING.delete(r.slug);
      // If the pointer has been sitting on one of this resort's cells, its tip
      // is still showing "loading" and nothing else will ever redraw it.
      if (tipCell && tipCell._at && tipCell._at.r.slug === r.slug
          && tip.classList.contains('on')) paintTip(tipCell);
    })
    .catch(function(){ PENDING.delete(r.slug); });
}

const MON = ['', 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const FAILS = ['Great','Rain on snow','Wind hold','Flat light','Too cold','Too warm','Cloudy and cold','No week snow','No fresh snow','Grey'];
const fmt = (n, d) => (n == null ? '\u2014' : n.toFixed(d == null ? 1 : d));
const grids = document.getElementById('grids');
const tip = document.getElementById('tip');

/* ---- failure modes ------------------------------------------------------- */
/* The fail mix, counted from the packed days rather than read from the
   payload's precomputed totals. Those totals cover the whole record, so they
   cannot answer "why did days go wrong in 2020-2025". Only the reason
   character is read -- one byte per day, no full decode -- which keeps a
   recount over every day of every selected winter cheap enough to run on
   each render. */
function failCounts(r){
  // Precomputed per season by the build, because the fail mix is season-level
  // and never window-level -- this used to rescan every packed day on every
  // render to arrive at the same answer.
  const out = new Array(FAILS.length).fill(0);
  for (let j = 0; j < r.s.length; j++){
    if (!seasonInRange(r, j)) continue;
    const f = r.fails[j];
    for (let k = 0; k < out.length && k < f.length; k++) out[k] += f[k];
  }
  return out;
}

/* The reason ladder splits in two, and drawing it as one list was a lie.
   FailReason names why a day is not GREAT, so its bottom rungs are days that
   were perfectly rideable and merely had no snow behind them. "No week snow"
   alone is 28.5% of all Dec-Apr days and every single one of them is Good --
   listing it under "how a day goes wrong" made the largest bar in the panel a
   day that went right. The Great bar stays on top as the baseline the two
   groups are read against. */
const MEH_WHY   = ['Rain on snow', 'Wind hold', 'Flat light',
                   'Too cold', 'Too warm', 'Cloudy and cold'];
const SHORT_WHY = ['No week snow', 'No fresh snow', 'Grey'];

function failPanel(list){
  const host = document.getElementById('fails');
  host.replaceChildren.apply(host, (list || DATA).map(function(r){
    const counts = failCounts(r);
    const total = counts.reduce((a, b) => a + b, 0);
    const pctOf = f => (total ? 100 * counts[FAILS.indexOf(f)] / total : 0);
    const bar = function(f, cls){
      const pct = pctOf(f);
      return '<div class="frow"><span>' + f + '</span>' +
             '<span class="ftrack"><span class="ffill' + (cls || '') + '" style="width:' +
             Math.min(100, pct) + '%"></span></span>' +
             '<span class="fval">' + pct.toFixed(0) + '%</span></div>';
    };
    // the group total counts every reason in it, including rows too small to draw
    const group = function(label, names){
      const sum = names.reduce((a, f) => a + pctOf(f), 0);
      return '<div class="fgrp">' + label + '<b>' + sum.toFixed(0) + '%</b></div>' +
             names.filter(f => pctOf(f) >= 0.5)
                  .map(f => bar(f, f === 'Wind hold' ? ' w' : '')).join('');
    };
    const el = document.createElement('div');
    el.className = 'fcard';
    el.innerHTML = '<h4>' + r.name.split(' - ')[0] + '</h4>' +
                   bar('Great', ' g') +
                   group('made it Meh', MEH_WHY) +
                   group('short of Great', SHORT_WHY);
    return el;
  }));
}

/* ---- trip window --------------------------------------------------------- */
let COLS = [], WINS = [], curSort = 'good';

// Which tier the Winters figure is measured at. Only the three tier buttons
// move it, so choosing a price sort leaves the card reading whatever tier you
// last asked about rather than silently resetting.
const TIER_OF = { good: 1, great: 2, epic: 3 };
let tierSel = 1;

// What "a winter that delivered" means, per tier. The bar drops as the tier
// rises because the tiers are not equally common: 75% of a week being Good is
// a realistic ask, 75% being Great has never once happened in 27 winters at
// any of these nine, and a single Epic day is the whole point of Epic.
const RULE = [
  { share: 0.75, label: 'Winters 75%+',  say: 'at least 75% of your trip days were Good or better' },
  { share: 0.50, label: 'Winters 50%+',  say: 'at least 50% of your trip days were Great or better' },
  { days:  1,    label: 'Winters w/ 1+', say: 'at least one of your trip days was Epic' }
];
// The three tier averages are taken over the whole scored window -- your dates
// PLUS the padding -- because the padding is there to widen the sample. The
// Winters figure beside them deliberately does not. Saying so in the tooltip is
// cheaper than making two numbers that look alike behave alike.
const STAT_TIP = {
  epic:  'Epic days per trip, averaged over every winter on record. '
       + 'Epic = a rideable powder day: 8°F or better, terrain you can see, no '
       + 'wind hold, no rain, a week of 5 inches or more behind it, and 4 inches or '
       + 'more in the last 24 hours. Very Cold days also need Partly Sunny or better. '
       + 'It is judged on the snow rather than on comfort, so an Epic day is not '
       + 'always a Good one.',
  great: 'Great days per trip, averaged over every winter on record. Epic days count '
       + 'toward it. Great = a Good day with a week of 5 inches or more behind it, plus '
       + 'either sun and Comfortable temperatures, 2 inches or more in the last 24 hours, '
       + 'or 5 inches or more over three days.',
  good:  'Good days per trip, averaged over every winter on record. Great and Epic days '
       + 'count toward it. Good = felt temperature 16-45F, no wind hold, terrain visible '
       + 'over more than half the day, no rain on snow, and if the sky is Mostly Cloudy '
       + 'or Cloudy then Comfortable or Warm as well. Good asks nothing about snow.'
};
// Spelled out with the real day counts for the current settings, because
// "scaled to the trip" is the sort of sentence that sounds fine and tells you
// nothing.
function tipTail(r){
  const k = r._.per.length;
  const win = Math.round(r._.days / k), trip = Math.round(r._.tripDays / k);
  if (win === trip)
    return ' Counted over the ' + trip + ' days of your trip in each of the ' + k + ' winters.';
  return ' Counted as a rate over the ' + win + ' days your window covers in each of the ' + k
       + ' winters -- your ' + trip + ' trip days plus the padding either side -- then scaled back '
       + 'to a ' + trip + '-day trip, so it can never exceed ' + trip + '.';
}

/* Padding means "days either side are exchangeable with your own". The tier
   averages already lean on that, so this does too: slide a trip-length window
   across the padded range and ask whether a TYPICAL placement of your trip
   would have delivered, not merely the exact dates. A winter counts when at
   least half the placements pass.
   With padding at exact there is only one placement, so this collapses to
   scoring your dates and nothing changes -- the same property the averages
   have. */
// The Winters figure leans on padding the same way the averages do, so say so
// in the same concrete terms.
function winterTail(r){
  const k = r._.per.length;
  const win = Math.round(r._.days / k), trip = Math.round(r._.tripDays / k);
  if (win === trip)
    return ' Judged on your ' + trip + ' dates exactly, in each of the ' + k + ' winters.';
  return ' A ' + trip + '-day trip is slid across the ' + win + ' days your window covers, and '
       + 'the winter counts when at least half those placements pass -- so it measures whether a '
       + 'trip around these dates typically delivered, not whether one exact slice got lucky.';
}

function delivered(p){
  const L = p.tripN;
  if (!L) return false;
  const r = RULE[tierSel - 1], t = p.tiers;
  let places = 0, ok = 0;
  for (let i = 0; i + L <= t.length; i++){
    let n = 0, hit = 0, gap = false;
    for (let j = i; j < i + L; j++){
      if (t[j] == null){ gap = true; break; }
      n++;
      if (t[j] >= tierSel) hit++;
    }
    if (gap || !n) continue;
    places++;
    if (r.days ? hit >= r.days : hit / n >= r.share) ok++;
  }
  return places > 0 && ok / places >= 0.5;
}

// Sorts that read a price off the resort rather than a score off the window,
// and run cheapest-first. A resort with no published price sorts last in
// either direction -- it is missing, not free.
const PRICE_SORT = { peak: 'peak', adv: 'adv' };

const SYM = { USD: '$', CAD: 'C$', EUR: '\u20ac', GBP: '\u00a3',
              CHF: 'CHF\u00a0', JPY: '\u00a5', AUD: 'A$', NZD: 'NZ$' };
function money(v, cur){
  if (v == null) return null;
  return (SYM[cur] || (cur ? cur + '\u00a0' : '')) + v.toLocaleString();
}

function ordOf(m, d){ return (m === 12 ? 0 : m) * 100 + d; }

function readWindow(){
  const a = document.getElementById('from').value, b = document.getElementById('to').value;
  const pad = +document.getElementById('pad').value;
  if (!a || !b) return null;
  let s = new Date(a + 'T00:00:00Z'), e = new Date(b + 'T00:00:00Z');
  if (e < s){ const t = s; s = e; e = t; }
  return { s: s, e: e, pad: pad };
}

// Each season's window is built in that season's own calendar, so padding four
// days past Feb 28 lands on Mar 3 in a leap winter and Mar 4 otherwise. COLS is
// the union across seasons (for lining the grid up); WINS keeps each season's
// own membership, because scoring off the union would count days a given
// winter never had.
function seasonDates(y, w){
  const sM = w.s.getUTCMonth() + 1, sD = w.s.getUTCDate();
  const eM = w.e.getUTCMonth() + 1, eD = w.e.getUTCDate();
  const a = Date.UTC(sM >= 12 ? y : y + 1, sM - 1, sD) - w.pad * MS;
  const b = Date.UTC(eM >= 12 ? y : y + 1, eM - 1, eD) + w.pad * MS;
  const tA = Date.UTC(sM >= 12 ? y : y + 1, sM - 1, sD);
  const tB = Date.UTC(eM >= 12 ? y : y + 1, eM - 1, eD);
  const out = [];
  for (let t = a; t <= b; t += MS){
    const dt = new Date(t);
    out.push({ m: dt.getUTCMonth() + 1, d: dt.getUTCDate(), trip: t >= tA && t <= tB });
  }
  return out;
}

function buildCols(w, y0, n){
  const seen = new Map(); WINS = [];
  for (let j = 0; j < n; j++){
    const set = new Set();
    for (const c of seasonDates(y0 + j, w)){
      const k = c.m + '-' + c.d;
      set.add(k);
      if (!seen.has(k)) seen.set(k, c); else if (c.trip) seen.get(k).trip = true;
    }
    WINS.push(set);
  }
  return Array.from(seen.values()).sort((a, b) => ordOf(a.m, a.d) - ordOf(b.m, b.d));
}

// index of a calendar date within a Dec 1 -> Apr 30 season string
function dayIndex(y, m, d, len){
  const cal = m >= 12 ? y : y + 1;
  const dt = new Date(Date.UTC(cal, m - 1, d));
  if (dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return -1;
  const i = Math.round((dt - Date.UTC(y, 11, 1)) / MS);
  return (i >= 0 && i < len) ? i : -1;
}

// The one reason each day landed in its tier, as SQL ranked them, paired with
// the phrasing the tooltip uses. Order must match FAILS in h07_pack.py.
// An empty description means the row would only restate what another row of
// the tooltip already says, so the reason is named and left at that.
const WHY = [
  ['Great',           ''],
  ['Rain on snow',    'rain fell on the pack'],
  ['Wind hold',       'gusts over 40 mph for more than half the day'],
  ['Flat light',      'cloud hid the terrain over half the day'],
  ['Too cold',        'under 16\u00b0F felt'],
  ['Too warm',        'over 45\u00b0F felt'],
  ['Cloudy and cold', 'chilly under heavy cloud'],
  ['No week snow',    'under 5 inches in the last week'],
  ['No fresh snow',   'the week was there, the morning was not'],
  ['Grey',            'snow and cold enough, but too much cloud']
];

// Six opaque-cloud bands plus flat light, darkest first so the index rises
// with the light. Opaque = the thicker of low and mid cloud; high cirrus is
// excluded, being the kind you can ski under quite happily.
const VIS = ['Flat light', 'Cloudy', 'Mostly cloudy', 'Partly sunny',
             'Mostly sunny', 'Sunny', 'Bluebird'];

// Bit flags for every Good-tier test a day failed, in the order SQL packs them.
// A Meh day often trips several at once -- about a third of them do -- and
// naming only the first hides the rest.
// Renumbered in the 2026-09 rewrite: the long-retired thin-base slot is finally
// reclaimed. Safe only because the whole payload regenerates from SQL on every
// build, so there are no archived days to relabel -- and _hverify.js checks
// every day of it against the SQL it came from.
const FAILBITS = [[1, 'rain on snow'], [2, 'wind hold'], [4, 'flat light'],
                  [8, 'too cold'], [16, 'too warm'], [32, 'cloudy and cold']];
const failList = m => FAILBITS.filter(b => m & b[0]).map(b => b[1]).join(', ');

// The same idea one tier up. FAILBITS says why a day is Meh; these say what a
// day that CLEARED its tier fell short of on the next one -- which the tooltip
// had no way to express, so a Good day sitting under a 4-inch morning looked
// arbitrary. Bits 1 and 2 are set only on Good days; bit 4 is set at whatever
// tier the day landed in, so the two rows are masked apart where they are
// rendered. SQL sets them in MissMask; nothing here re-derives a rule the
// page does not own.
const MISSBITS = [[1, 'under 5&Prime; in the last week'],
                  [2, 'nothing fresh, and not sunny and comfortable enough without it'],
                  [4, 'under 4&Prime; this morning']];
const missList = m => MISSBITS.filter(b => m & b[0]).map(b => b[1]).join(', ');

// How the felt temperature reads. The model's floor is the bottom of Chilly:
// 16F passes, 15F does not, so the band boundary and the rule are the same
// number rather than two numbers that have to be kept in step.
// The 8 is load-bearing, not cosmetic: Epic's floor IS the bottom of Very
// Cold, so this boundary and @EpicMinF in h05_skiday.sql are one number.
// It read 10 until 2026-09-19, when Epic stopped borrowing Good's floor.
const TBANDS = [[8, 'Bitter cold'], [16, 'Very cold'], [20, 'Chilly'],
                [33, 'Comfortable'], [46, 'Warm']];
function tband(f){
  for (let i = 0; i < TBANDS.length; i++) if (f < TBANDS[i][0]) return TBANDS[i][1];
  return 'Very warm';
}

function decode(s, i){
  const c = s.substr(i * DAYCH, DAYCH);
  if (c[0] === ' ') return null;
  // `snow` is a WEEK of snow as a multiple of this resort's 5-inch line, not
  // inches: modelled snowfall runs anywhere from a third to half again the
  // measured depth gain depending on the resort, so only a per-resort scale
  // compares. Both Great paths need it at 1.0 or over.
  // `meas` is the same week from the SNOTEL gauges within 35 km -- 60 km where
  // fewer than three are that close -- as a multiple
  // of a flat 5 inches; null where there are no gauges.
  // Exact degrees F. The mean is offset by 33 (window -33..58); the low and
  // high ride as offsets from it, which is what keeps warm April highs from
  // hitting the top of the alphabet.
  const app = CODE[c[1]] - 33;
  // slot 0 carries the tier in bits 0-1, the 5-inch week verdict in bit 2,
  // and what the day missed the next tier on in bits 3-5
  return { tier: CODE[c[0]] & 3, week: (CODE[c[0]] >> 2) & 1,
           miss: (CODE[c[0]] >> 3) & 7, app: app,
           sun: CODE[c[2]] / 90, gust: CODE[c[3]],
           // the modelled week, in measured-equivalent inches
           mEq168: CODE[c[4]],
           // whole inches, the same grid as new24 and newSnow below. It was a
           // multiple of 5 inches until 2026-09-19, which printed a week of
           // 7.9in as "7.8" beside a 72h of 7.5in printed as "8".
           meas: c[5] === ' ' ? null : CODE[c[5]], why: CODE[c[6]],
           vis: CODE[c[7]], lo: app - CODE[c[8]], hi: app + CODE[c[9]],
           newSnow: c[10] === ' ' ? null : CODE[c[10]],        // inches of new snow
           swe:     c[11] === ' ' ? null : CODE[c[11]] / 10,   // inches of water
           new24:   c[12] === ' ' ? null : CODE[c[12]],       // inches over 24h
           fail:    CODE[c[13]],                              // bit flags, see FAILBITS
           // AIR temperature. The mean rides as the wind-chill gap off the
           // felt mean (bias 20), the low and high as offsets from it -- the
           // same shape as the felt trio above.
           temp:    app + CODE[c[14]] - 20,
           tlo:     app + CODE[c[14]] - 20 - CODE[c[15]],
           thi:     app + CODE[c[14]] - 20 + CODE[c[16]],
           // opaque sky cover, to half a percent. The band in slot 7 is derived
           // from this same rounded value in SQL, so label and number agree.
           opq:     CODE[c[17]] * 2,
           // the modelled morning and the 72 hours behind it, both in
           // measured-equivalent inches. Slot 19 is new: the packed payload
           // carried no modelled 72-hour figure at all, though Great's third
           // path tests it.
           mEq24:   CODE[c[18]],
           mEq72:   CODE[c[19]] };
}

function score(r){
  const per = [];
  for (let j = 0; j < r.s.length; j++){
    if (!seasonInRange(r, j)) continue;
    const len = dayLen(r, j), y = r.y0 + j;
    let good = 0, great = 0, epic = 0, n = 0, hold = 0, week = 0;
    // the padded days are context, not the trip, so the hit rate below
    // counts only the days actually being travelled
    let tripN = 0, tripT = [0, 0, 0];
    const tiers = [];   // tier per column, null where the day is absent
    /* Cells carry the day's COORDINATES and its three bits, not the day itself.
       The hosted build has not fetched the detail yet when this runs, and the
       artifact build was building 58,000 tooltip strings nobody hovered. */
    const cells = COLS.map(function(c){
      if (!WINS[j].has(c.m + '-' + c.d)){ tiers.push(null); return null; }
      const i = dayIndex(y, c.m, c.d, len);
      if (i < 0){ tiers.push(null); return null; }
      const b = bitsAt(r, j, i);
      if (b < 0){ tiers.push(null); return null; }
      const tier = b & 3;
      tiers.push(tier);
      n++;
      if (c.trip){ tripN++; for (let t = 1; t <= 3; t++) if (tier >= t) tripT[t - 1]++; }
      // The tiers nest: every Epic day is also Great, every Great day is also
      // Good. So the counts are cumulative and sorting by "Good days" ranks on
      // everything worth riding, not just the days that topped out at Good.
      if (tier >= 1) good++;
      if (tier >= 2) great++;
      if (tier >= 3) epic++;
      if (b & 4) hold++;               // an actual hold, not merely a gusty hour
      if (b & 8) week++;               // cleared the 5-inch week the tiers test
      return { j: j, i: i, b: b };
    });
    per.push({ y: y, cells: cells, good: good, great: great, epic: epic, n: n, hold: hold,
               tripN: tripN, tripT: tripT, tiers: tiers, week: week });
  }
  const k = per.length;

  /* Every count on the card is expressed PER TRIP, whatever the padding.
     Padding is a smoothing device, not extra holiday: it widens the sample so
     the rate is estimated from more days, and the rate is then applied to the
     length of the trip you are actually taking. Reporting the raw window count
     as "per trip" made a 6-day trip show 8.1 Good days at +/-4d -- more good
     days than days. At zero padding the window IS the trip, so this reduces to
     a plain count and nothing changes. */
  const perTrip = sel => per.reduce((a, p) => a + (p.n ? sel(p) / p.n * p.tripN : 0), 0) / k;

  return { per: per, days: per.reduce((a, p) => a + p.n, 0),
           tripDays: per.reduce((a, p) => a + p.tripN, 0),
           good: perTrip(p => p.good),
           great: perTrip(p => p.great),
           epic: perTrip(p => p.epic),
           wEpic: per.filter(p => p.epic >= 1).length,
           hold: perTrip(p => p.hold),
           // One number, not the old modelled/measured pair: the bit counts the
           // week test the TIERS used, which is the gauge wherever one reported
           // and the model otherwise. The card said as much already; it just
           // had to pick between two counts to do it.
           week: perTrip(p => p.week),
           // Winters that delivered at the selected tier, by the rule above.
           // Measured over the trip itself, never the padding around it.
           wGood: per.filter(delivered).length };
}

/* The 27-winter grid: 405 cells per card, and by far the most expensive thing
   on the page. Built on demand rather than up front, because render() draws
   every card that passes the filters and at 431 resorts that is 174,000 cells
   -- measured at 13.7 SECONDS for a single re-sort. Deferred, the cards appear
   at once and their grids fill in as they reach the viewport. */
function buildPlot(plot, r){
  if (plot.dataset.built === COLS.length + 'x' + curSort) return;
  plot.dataset.built = COLS.length + 'x' + curSort;
  const g = document.createElement('div');
  g.className = 'grid';
  g.style.gridTemplateColumns = '20px repeat(' + COLS.length + ', 1fr)';
  g.setAttribute('role', 'img');
  g.setAttribute('aria-label', r.name + ': ' + r._.per.length +
    ' winters over the chosen window, ' +
    fmt(r._.epic, 1) + ' epic, ' + fmt(r._.great, 1) + ' great and ' +
    fmt(r._.good, 1) + ' good days per trip.');

  g.appendChild(document.createElement('div'));
  const fT = COLS.findIndex(c => c.trip), lT = COLS.map(c => c.trip).lastIndexOf(true);
  COLS.forEach(function(c, i){
    const e = document.createElement('div');
    e.className = 'dlab' + (c.trip ? ' trip' : '');
    if (i === 0 || i === COLS.length - 1 || i === fT || i === lT)
      e.innerHTML = MON[c.m] + '<br>' + c.d;
    g.appendChild(e);
  });
  if (fT >= 0){
    const pl = document.createElement('div'); pl.style.gridColumn = '1 / span ' + (fT + 1); g.appendChild(pl);
    const bd = document.createElement('div'); bd.className = 'tripband';
    bd.style.gridColumn = (fT + 2) + ' / span ' + (lT - fT + 1); bd.textContent = 'Your trip';
    g.appendChild(bd);
    if (lT < COLS.length - 1){
      const pr = document.createElement('div');
      pr.style.gridColumn = (lT + 3) + ' / span ' + (COLS.length - 1 - lT); g.appendChild(pr);
    }
  }

  r._.per.forEach(function(p){
    const yl = document.createElement('div');
    yl.className = 'ylab';
    yl.textContent = "'" + String(p.y + 1).slice(2);
    g.appendChild(yl);
    p.cells.forEach(function(cell, i){
      const c = document.createElement('div');
      if (!cell){ c.className = 'cell absent'; g.appendChild(c); return; }
      // The red edge marks a day the WIND took, which since the rule moved to
      // "gusts over half the lift day" is no longer the same thing as a single
      // 40 mph gust. Bit 2 of the fail mask is the model's own answer, and it
      // is set on every day regardless of tier.
      c.className = 'cell' + ((cell.b & 4) ? ' hold' : '');
      c.dataset.t = ['none', 'good', 'great', 'epic'][cell.b & 3];
      c.dataset.trip = COLS[i].trip ? 1 : 0;
      /* Coordinates, not content. This used to build the tooltip HTML for every
         cell on every render -- 58,000 strings for the handful anyone hovers --
         and the hosted build could not do it at all, because the detail file
         has not arrived when the grid is drawn. */
      c._at = { r: r, j: cell.j, i: cell.i, y: p.y, m: COLS[i].m, d: COLS[i].d };
      g.appendChild(c);
    });
  });
  plot.replaceChildren(g);
}

function card(r, rank){
  const el = document.createElement('article');
  el.className = 'card';
  el._r = r;                       // for the detail prefetch in render()
  el.innerHTML =
    '<div><h3><span class="rank">' + String(rank).padStart(2, '0') + '</span>' +
      r.name.split(' - ')[0] + '</h3></div>' +
    STATS_HTML(r) +
    /* .place is its own full-width row rather than sitting under the title.
       Beside the stats block it had only ~130px of a 388px card, so the
       state-and-prices line wrapped to three lines however wide the window
       got. Spanning the card it has ~358px, and the 274px it needs fits. */
    /* Three short rows instead of one long one: where it is, what it costs,
       where its snow came from. Region-state tops out at 238px and the price
       line at 188px, both inside the 358px a card gives -- so neither wraps
       nor scrolls, which one combined line could not manage at 433px. */
    '<div class="place">' +
      (r.region ? '<span class="reg">' + r.region + '</span>' : '') +
      '<span>' + r.state + '</span>' +
      /* Vertical drop belongs with where the mountain is, not with the season
         statistics underneath: it is the single number that says how big a
         hill this is, and it is what the 899ft cut was drawn against. At 339px
         the longest of these still clears the 358px a card gives. */
      (r.vert ? '<span class="sep">&middot;</span><span>vert ' +
                r.vert.toLocaleString() + '&prime;</span>' : '') +
    '</div>' +
    '<div class="price-row">' + priceHtml(r) + '</div>' +
    /* Snow provenance gets its own row. Sharing the line above, it was the
       piece that pushed region-state-and-prices into wrapping; and it is a
       different kind of fact -- where the number came from, not where the
       mountain is. Every card says which it is: silence would read as an
       oversight rather than as "modelled". */
    '<div class="prov-row">' +
      (r.snowSource === 'measured'
        ? '<span class="prov" title="Snow here is MEASURED, not modelled: ' + r.gauges +
          ' SNOTEL gauges within 35 km, nearest ' + r.nearestKm +
          ' km, decide which days count as fresh. ERA5 agreed with them ' + Math.round(r.kappa * 100) +
          '% beyond chance, and caught ' + Math.round(r.recall * 100) +
          '% of the days the gauges called fresh.">&#10003; SNOTEL &middot; ' +
          r.gauges + (r.gauges === 1 ? ' gauge' : ' gauges') + '</span>'
        : '<span class="noprov" title="No SNOTEL station stands within 35 km of this ' +
          'mountain (60 km where fewer than three are that close), so its snow is ERA5 ' +
          'reanalysis rather than a gauge reading. Every snow test falls back to modelled ' +
          'inches converted to this resort\'s own scale, so it can still reach Epic -- it ' +
          'is just judged by the model rather than a gauge.">no gauge in range &middot; snow modelled</span>') +
    '</div>';

  function STATS_HTML(r){
    return '<div class="stats">' +
      ['epic', 'great', 'good'].map(function(k){
        return '<div class="stat hastip ' + k + '" title="' + STAT_TIP[k] + tipTail(r) + '">' +
               '<div class="sv">' + fmt(r._[k], 1) + '</div>' +
               '<div class="sl">' + k.charAt(0).toUpperCase() + k.slice(1) + '</div></div>';
      }).join('') +
      '<div class="stat hastip" title="Of the ' + r._.per.length + ' winters on record, ' +
        r._.wGood + ' where ' + RULE[tierSel - 1].say +
        '.' + winterTail(r) + ' Follows whichever of Good, Great or Epic is selected above.">' +
        '<div class="sv">' + r._.wGood +
        '<span style="color:var(--muted);font-size:12px">/' + r._.per.length +
        '</span></div><div class="sl">' + RULE[tierSel - 1].label + '</div></div>' +
    '</div>';
  }

  const plot = document.createElement('div');
  plot.className = 'plot';
  plot._r = r;
  el.appendChild(plot);

  const t = document.createElement('div');
  t.className = 'terr';
  t.innerHTML =
    '<span>wind-hold days <b>' + fmt(r._.hold, 1) + '</b></span>' +

    '<span>days on a 5&Prime; week <b>' + fmt(r._.week, 1) + '</b>' +
      (r.snowSource === 'measured' ? '<span class="meas"> measured</span>' : '') + '</span>' +
    /* Base, with the rest of the elevation band on hover. Mid-mountain earns
       its place there rather than on the line: it is the height every
       temperature on this page was modelled at, so it is the number to quote
       beside a "feels like", and a reader checking a temperature is exactly
       the reader who will look. */
    /* The mountain itself: the elevation band, then how much of it there is.
       Mid-mountain rides on the base tooltip rather than the line -- it is the
       height every temperature here was modelled at, so it belongs next to the
       elevations, but it is a modelling detail and not a fact about the
       resort. */
    (r.baseFt != null
      ? '<span class="elev"' +
        (r.midFt != null
          ? ' title="Every temperature on this card was modelled at mid-mountain, ' +
            r.midFt.toLocaleString() + ' ft, not at the base."'
          : '') +
        '>base <b>' + r.baseFt.toLocaleString() + '&prime;</b></span>'
      : '') +
    (r.summitFt != null ? '<span>summit <b>' + r.summitFt.toLocaleString() + '&prime;</b></span>' : '') +

    (r.lifts != null ? '<span>lifts <b>' + r.lifts + '</b></span>' : '') +
    (r.runs  != null ? '<span>runs <b>' + r.runs + '</b></span>' : '') +
    (r.acres != null ? '<span>acres <b>' + r.acres.toLocaleString() + '</b></span>' : '') +
    (r.map ? '<span><a class="tmap" href="' + r.map + '" target="_blank" ' +
             'rel="noopener noreferrer">trail map &#8599;</a></span>' : '');
  el.appendChild(t);

  /* The terrain split. Shares of skiable acreage, easy -> advanced, on a
     sequential ramp rather than the green/blue/black of trail signs: those two
     hues already mean "good day" and "great day" on this very card. Every
     segment is labelled with its percentage, so the bar never depends on
     colour to be read -- required here, because the lightest step sits under
     3:1 against the card. */
  const tp = terrainOf(r);
  if (tp){
    const d = document.createElement('div');
    d.className = 'tsplit';
    const seg = (cls, v) => v > 0 ? '<i class="' + cls + '" style="flex:' + v + '"></i>' : '';
    /* Share AND size. The bar already carries the shape, so the number that
       adds something here is the absolute one: 20% of Alta is 392 acres and
       20% of a small hill is 60, and those are different mountains. Acreage
       is missing for 5 of the 230, which show the share alone rather than a
       zero that would read as "no easy terrain". */
    const key = (cls, label, v, ac) =>
      '<span>' +
        '<span class="lab"><i class="' + cls + '" style="background:var(--t-' +
          cls2tok(cls) + ')"></i>' + label + ' <b>' + Math.round(v * 100) + '%</b></span>' +
        (ac != null ? '<span class="ac">' + ac.toLocaleString() + ' ac</span>' : '') +
      '</span>';
    d.innerHTML =
      '<div class="terrbar" role="img" aria-label="Terrain: ' +
        Math.round(tp.g * 100) + '% easy, ' + Math.round(tp.b * 100) + '% intermediate, ' +
        Math.round(tp.k * 100) + '% advanced">' +
        seg('e', tp.g) + seg('m', tp.b) + seg('h', tp.k) +
      '</div>' +
      '<div class="terrkey">' +
        key('e', 'easy',         tp.g, r.greenAc) +
        key('m', 'intermediate', tp.b, r.blueAc) +
        key('h', 'advanced',     tp.k, r.blackAc) +
      '</div>';
    el.appendChild(d);
  }
  return el;
}

/* The price row always renders, even with nothing to put in it. Six of the
   154 publish no ticket price, and dropping the row for them would take a row
   out of the card above the winter grid -- starting their grid higher than
   their neighbours', which is the alignment bug all over again. Saying "no
   published price" costs one line and keeps every grid on the same baseline. */
function priceHtml(r){
  const parts = [];
  if (r.cur) parts.push(r.cur);
  if (r.peak != null) parts.push('peak ' + money(r.peak, r.cur));
  if (r.adv  != null) parts.push('adv ' + money(r.adv, r.cur));
  if (r.peak == null && r.adv == null)
    return '<span class="noprice">no published price</span>';
  return parts.map(p => '<span>' + p + '</span>').join('<span class="sep">&middot;</span>');
}

function cls2tok(c){ return c === 'e' ? 'easy' : c === 'm' ? 'mid' : 'hard'; }

/* Normalised shares. The source percentages are independent columns and do not
   always total exactly 1 -- they run 0.98 to 1.02 on rounding, and one resort
   sums to 0.7 -- so they are rescaled to the total actually present rather than
   drawn as if the shortfall were a fourth kind of terrain. */
function terrainOf(r){
  const g = r.greenPct, b = r.bluePct, k = r.blackPct;
  if (g == null || b == null || k == null) return null;
  const t = g + b + k;
  if (!(t > 0)) return null;
  return { g: g / t, b: b / t, k: k / t };
}

/* ---- which mountains ----------------------------------------------------
   Four filters, ANDed. Region and state cascade: choosing a region rebuilds
   the state list from what is actually in it, so the controls can never offer
   a combination that returns nothing. Scoring runs on the filtered set rather
   than all 230, so narrowing the list also makes the page faster.
   -------------------------------------------------------------------------- */
const fRegions = document.getElementById('fregions');
const fState  = document.getElementById('fstate');
const fVert   = document.getElementById('fvert');
const fTerr   = document.getElementById('fterr');
const fY1     = document.getElementById('fy1');
const fY2     = document.getElementById('fy2');

/* Winters are named by the year they END in, matching the row labels on every
   grid: the 1999 season is the winter of '00. Restricting the range restricts
   EVERYTHING measured per winter -- the per-trip rates, the winters-delivered
   count and its denominator, the days-observed figure, and the fail mix --
   because all of them are computed from the same per-season loop rather than
   from anything precomputed across the whole record. */
const Y_FIRST = Math.min.apply(null, DATA.map(r => r.y0)) + 1;
const Y_LAST  = Math.max.apply(null, DATA.map(r => r.y0 + r.s.length - 1)) + 1;
(function fillYears(){
  for (let y = Y_FIRST; y <= Y_LAST; y++){
    const a = document.createElement('option'); a.value = y; a.textContent = y;
    const b = document.createElement('option'); b.value = y; b.textContent = y;
    fY1.appendChild(a); fY2.appendChild(b);
  }
  fY1.value = Y_FIRST; fY2.value = Y_LAST;
})();

// season index j of resort r covers the winter ending in r.y0 + j + 1
function seasonInRange(r, j){
  const endYear = r.y0 + j + 1;
  return endYear >= +fY1.value && endYear <= +fY2.value;
}
function yearsNarrowed(){ return +fY1.value !== Y_FIRST || +fY2.value !== Y_LAST; }
const fName   = document.getElementById('fname');
const fClear  = document.getElementById('fclear');
const fCount  = document.getElementById('fcount');

function fillOptions(sel, values, allLabel){
  const keep = sel.value;
  sel.replaceChildren();
  const all = document.createElement('option');
  all.value = ''; all.textContent = allLabel;
  sel.appendChild(all);
  values.forEach(function(v){
    const o = document.createElement('option');
    o.value = v; o.textContent = v;
    sel.appendChild(o);
  });
  // keep the current choice if the new list still offers it
  sel.value = values.indexOf(keep) >= 0 ? keep : '';
}

const uniq = xs => Array.from(new Set(xs.filter(Boolean))).sort();

/* Region is a MULTI-select: none chosen means all, and any number can be
   combined, because "the Rockies or the Sierra" is a real way to plan a trip
   and a single-choice dropdown cannot express it. The chips carry each
   region's count so the size of a set is visible before choosing it. */
const picked = new Set();

uniq(DATA.map(r => r.region)).forEach(function(reg){
  const n = DATA.filter(r => r.region === reg).length;
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'chip';
  b.dataset.region = reg;
  b.setAttribute('aria-pressed', 'false');
  b.innerHTML = reg + '<span class="n">' + n + '</span>';
  fRegions.appendChild(b);
});

fillOptions(fState, uniq(DATA.map(r => r.state)), 'All states');

function syncStates(){
  // the states on offer are the union across every picked region
  const pool = picked.size ? DATA.filter(r => picked.has(r.region)) : DATA;
  fillOptions(fState, uniq(pool.map(r => r.state)), 'All states');
}

function passes(r){
  // A resort with nothing inside the chosen winters is not shown at all:
  // scoring it would divide by zero winters and print NaN per trip. Every
  // resort currently carries the same 27, but a partial fetch would not.
  if (!r.s.some(function(_, j){ return seasonInRange(r, j); })) return false;
  if (picked.size && !picked.has(r.region)) return false;
  if (fState.value  && r.state  !== fState.value)  return false;
  const mv = +fVert.value;
  if (mv && !(r.vert >= mv)) return false;
  /* Terrain thresholds come from the actual distribution, not round numbers:
     the median mountain here is 20% easy / 39% intermediate / 40% advanced, so
     30%+ easy, 50%+ intermediate and 50%+ advanced each pick out a genuinely
     unusual shape rather than half the list. Judged on normalised shares, so a
     resort whose columns sum to 0.98 is not quietly excluded. */
  if (fTerr.value){
    const tp = terrainOf(r);
    if (!tp) return false;
    if (fTerr.value === 'green' && !(tp.g >= 0.30)) return false;
    if (fTerr.value === 'blue'  && !(tp.b >= 0.50)) return false;
    if (fTerr.value === 'black' && !(tp.k >= 0.50)) return false;
  }
  const q = fName.value.trim().toLowerCase();
  // match the name people see, so "steamboat" finds "Steamboat - CO"
  if (q && r.name.toLowerCase().indexOf(q) < 0) return false;
  return true;
}

function filtersActive(){
  return !!(picked.size || fState.value || +fVert.value || fTerr.value ||
            fName.value.trim() || yearsNarrowed());
}

function render(){
  const w = readWindow(), warn = document.getElementById('warn');
  if (!w){ warn.textContent = 'Pick both dates.'; return; }
  COLS = buildCols(w, DATA[0].y0, DATA[0].s.length);
  if (COLS.length > 60){ warn.textContent = 'Window is ' + COLS.length + ' days \u2014 narrow it.'; return; }
  warn.textContent = '';

  const shown = DATA.filter(passes);
  fClear.hidden = !filtersActive();
  fCount.textContent = shown.length === DATA.length
    ? DATA.length + ' mountains'
    : shown.length + ' of ' + DATA.length + ' mountains';

  if (!shown.length){
    grids.replaceChildren(Object.assign(document.createElement('div'), {
      className: 'empty',
      textContent: 'No mountain matches those filters. Widen one of them.'
    }));
    document.getElementById('winlab').textContent = '';
    return;
  }

  shown.forEach(function(r){ r._ = score(r); });
  const pk = PRICE_SORT[curSort];
  const rows = shown.slice().sort(function(a, b){
    if (pk){
      const av = a[pk], bv = b[pk];
      if (av == null && bv == null) return b._.great - a._.great;
      if (av == null) return 1;
      if (bv == null) return -1;
      return av - bv || b._.great - a._.great;
    }
    return b._[curSort] - a._[curSort] || b._.good - a._.good;
  });
  grids.replaceChildren.apply(grids, rows.map((r, i) => card(r, i + 1)));

  /* Hosted build only: pull a resort's detail as its card nears the viewport,
     so the tooltip is rarely the thing waiting on the network. ~35 KB each,
     about six to a screen, and 400px of margin means it is usually already
     there by the time the pointer arrives. Losing the race costs a tooltip
     that says "loading", not a broken card. */
  if (render.io) render.io.disconnect();
  else render.io = new IntersectionObserver(function(entries){
    entries.forEach(function(e){
      if (!e.isIntersecting) return;
      const r = e.target._r;
      if (!r) return;
      needDetail(r);                       // hosted build; a no-op in the artifact
      const plot = e.target.querySelector('.plot');
      if (plot) buildPlot(plot, r);
    });
  }, { rootMargin: '1200px' });   // ~3 cards of lead time; a detail file is
                                  // 36 KB, so buying the head start is cheap
  const cards = grids.querySelectorAll('.card');
  cards.forEach(c => render.io.observe(c));
  /* The observer is the whole rendering path, which makes it a single point of
     failure: where IntersectionObserver does not fire -- an emulated or
     zero-height viewport, a headless capture, a browser that disagrees about
     what counts as visible -- every card would show its stats above an empty
     grid, with nothing to recover it. So the first screenful is drawn outright.
     Twelve cards is ~4,900 cells against the 174,555 that made an eager render
     take 13.7 seconds, so it costs nothing and guarantees the page is never
     blank where someone is actually looking. */
  for (let i = 0; i < Math.min(12, cards.length); i++){
    const plot = cards[i].querySelector('.plot');
    if (plot && cards[i]._r) buildPlot(plot, cards[i]._r);
    if (cards[i]._r) needDetail(cards[i]._r);
  }

  /* The identity line must not wrap, so on a card too narrow to hold it the
     row scrolls instead. Scrolled content with a hidden scrollbar just looks
     cut off, so the ones that actually overflow get a fade at the right edge
     to say there is more. Measured after layout, because only the browser
     knows what fitted. */
  grids.querySelectorAll('.card .place').forEach(function(pl){
    pl.classList.toggle('is-cut', pl.scrollWidth > pl.clientWidth + 1);
  });

  /* The fail mix answers "why do days go wrong HERE, in THESE winters", so it
     follows both filters rather than standing for the whole record. */
  failPanel(rows);
  document.getElementById('winlab').textContent =
    MON[w.s.getUTCMonth() + 1] + ' ' + w.s.getUTCDate() + ' \u2013 ' +
    MON[w.e.getUTCMonth() + 1] + ' ' + w.e.getUTCDate() +
    (w.pad ? ', \u00b1' + w.pad + 'd' : '') + ' \u00b7 ' + rows[0]._.days + ' days observed each';
  // "replayed N times" is the number of winters actually being replayed
  const hw = document.querySelector('[data-meta="winters"]');
  if (hw) hw.textContent = rows[0]._.per.length;
}

let timer = null;
const queue = () => { clearTimeout(timer); timer = setTimeout(render, 120); };
['from', 'to', 'pad'].forEach(id => document.getElementById(id).addEventListener('change', queue));

/* Region rebuilds the state list before re-rendering, so the two can never
   disagree. The search box listens on 'input' rather than 'change' so it
   filters as you type; the same 120 ms debounce keeps that cheap. */
/* One listener on the group rather than one per chip: the set is built from
   the data, so delegation keeps the wiring independent of how many there are. */
fRegions.addEventListener('click', function(e){
  const b = e.target.closest('button.chip');
  if (!b) return;
  const reg = b.dataset.region;
  if (picked.has(reg)) picked.delete(reg); else picked.add(reg);
  b.setAttribute('aria-pressed', picked.has(reg) ? 'true' : 'false');
  syncStates();
  queue();
});
/* Keep the range the right way round: choosing a last winter before the first
   would silently show nothing, so the other end follows rather than arguing. */
fY1.addEventListener('change', function(){ if (+fY2.value < +fY1.value) fY2.value = fY1.value; queue(); });
fY2.addEventListener('change', function(){ if (+fY1.value > +fY2.value) fY1.value = fY2.value; queue(); });
[fState, fVert, fTerr].forEach(el => el.addEventListener('change', queue));
fName.addEventListener('input', queue);
fClear.addEventListener('click', function(){
  picked.clear();
  fRegions.querySelectorAll('button.chip')
          .forEach(b => b.setAttribute('aria-pressed', 'false'));
  fState.value = ''; fVert.value = '0'; fTerr.value = ''; fName.value = '';
  fY1.value = Y_FIRST; fY2.value = Y_LAST;
  syncStates();
  render();
  fName.focus();
});
document.querySelectorAll('button.sort').forEach(function(b){
  b.addEventListener('click', function(){
    document.querySelectorAll('button.sort').forEach(x => x.setAttribute('aria-pressed', 'false'));
    b.setAttribute('aria-pressed', 'true');
    curSort = b.dataset.k;
    if (TIER_OF[curSort]) tierSel = TIER_OF[curSort];
    render();
  });
});

/* The three snow windows, in inches, for a resort with gauges and for one
   without alike. 292 of the 431 resorts here have no SNOTEL station in range
   -- 69.6% of all days -- and until 2026-09-19 those resorts got a different
   tooltip: two rows instead of four, written in multiples of their own
   thresholds rather than in inches, and carrying no 72-hour figure at all
   even though Great's third path tests that window.
   The modelled numbers are not measurements and the rows say so, but they are
   now on the same SCALE as a measurement, which is what makes a modelled
   resort comparable with a gauged one instead of merely self-consistent.
   SQL does the conversion (h14_export.sql); nothing here re-derives it. */
function snowRows(o){
  const row = (k, v) => '<span>' + k + ':</span><span>' + v + '</span>';
  const gauged = o.meas !== null;
  const tag = gauged ? '' : ' &mdash; modelled';
  const inches = v => (v == null ? '?' : v + '&Prime;');
  const wk  = gauged ? o.meas    : o.mEq168;
  const d72 = gauged ? o.newSnow : o.mEq72;
  const d24 = gauged ? o.new24   : o.mEq24;
  // Epic's line was invisible on both sides before: the morning row named the
  // 2-inch line and stopped there, so a 4-inch morning that failed Epic on the
  // SKY looked no different from one that failed on the snow.
  const cut24 = d24 == null ? '' : d24 >= 4 ? ' (clears 4&Prime;)'
                                 : d24 >= 2 ? ' (clears 2&Prime;)' : '';
  return row('Snow, week', inches(wk) + (wk >= 5 ? ' (clears 5&Prime;)' : '') + tag) +
         row('Snow, 72h',  inches(d72) + (d72 >= 5 ? ' (clears 5&Prime;)' : '') + tag) +
         row('Snow, 24h',  inches(d24) + cut24 + tag) +
         // Only worth printing where there is something to compare against.
         (gauged ? row('Model said', o.mEq168 + '&Prime; for the week ' +
             ((o.mEq168 >= 5) === (o.meas >= 5) ? '(agrees)'
              : (o.mEq168 >= 5 ? '(called the week, gauges did not)'
                               : '(missed it, gauges say yes)'))) : '');
}

/* Built on hover, from whatever has arrived. In the hosted build the detail
   file may still be in flight, in which case the tier is known from the index
   and the rest says so rather than lying or showing nothing. */
function tipHtml(a){
  const head = '<b>' + a.r.name.split(' - ')[0] + ' &middot; ' + MON[a.m] + ' ' +
               a.d + ' ' + (a.y + 1) + '</b>';
  const row = (k, v) => '<span>' + k + ':</span><span>' + v + '</span>';
  const o = dayAt(a.r, a.j, a.i);
  if (!o){
    needDetail(a.r);
    const b = bitsAt(a.r, a.j, a.i);
    if (b < 0) return '';
    return head + '<div class="tg">' + row('Day type', ['Meh','Good','Great','Epic'][b & 3]) +
           row('Detail', 'loading&hellip;') + '</div>';
  }
  const why = WHY[o.why] || WHY[0];
  const tier = ['Meh', 'Good', 'Great', 'Epic'][o.tier];
  return head + '<div class="tg">' +
    // The tier alone. Why a day landed there is the next row's job for a
    // Meh day, and for the others the numbers below say it better than a
    // clause appended to the label.
    row('Day type', tier) +
    (o.tier === 0 && o.fail ? row('Failed on', failList(o.fail)) : '') +
    // and what the day fell short of on the tier above.
    // The EPIC row is NOT gated on tier, because Epic is not the top of a
    // ladder: a Meh day can clear everything Epic asks for except the morning
    // -- 56,131 of them do -- and until 2026-09-20 the page said only why they
    // were Meh. Whistler on 2018-02-24 read 'too cold' under a 2% sky with an
    // 8-inch week and 2 inches fresh, two inches short of the top tier.
    // It IS suppressed on Good days, where 'Missed Great on' already names the
    // snow and a second row would only restate it.
    (o.tier === 1 && (o.miss & 3) ? row('Missed Great on', missList(o.miss & 3)) : '') +
    (o.tier !== 1 && (o.miss & 4) ? row('Missed Epic on',  missList(o.miss & 4)) : '') +
    row('Feels', tband(o.app) + ', ' + o.app + '&deg;F (' +
                 o.lo + '&ndash;' + o.hi + '&deg;F)') +
    // The same reading off the air thermometer. The bands are the felt ones,
    // so this row says what it was, not whether it passed.
    row('Temp', tband(o.temp) + ', ' + o.temp + '&deg;F (' +
                o.tlo + '&ndash;' + o.thi + '&deg;F)') +
    row('Sky', VIS[o.vis] + ', ' + Math.round(o.opq) + '% opaque cloud') +
    row('Peak gust', Math.round(o.gust) + ' mph' + ((o.fail & 2) ? ' (wind hold)' : '')) +
    // The week first, because both Great paths hang on it, then the morning,
    // which is what separates Great from Epic.
    snowRows(o) +
    '</div>';
}

/* The cell the tooltip is currently describing. Kept because the hosted build
   can paint a tip BEFORE its resort's detail file lands: pointerover fires once,
   and without this the tip sits on "loading" for as long as the pointer rests
   there, however long ago the fetch finished. needDetail() repaints through it. */
let tipCell = null;

function paintTip(t){
  const html = tipHtml(t._at);
  if (!html){ tip.classList.remove('on'); return; }
  tip.innerHTML = html; tip.classList.add('on');
  const r = t.getBoundingClientRect();
  const w = tip.offsetWidth;
  let x = r.left + r.width / 2 - w / 2, y = r.top - tip.offsetHeight - 9;
  x = Math.max(8, Math.min(x, window.innerWidth - w - 8));
  if (y < 8) y = r.bottom + 9;
  tip.style.left = x + 'px'; tip.style.top = y + 'px';
}

function showTip(e){
  const t = e.target.closest ? e.target.closest('.cell') : null;
  if (!t || !t._at){ tipCell = null; tip.classList.remove('on'); return; }
  tipCell = t;
  paintTip(t);
}
grids.addEventListener('pointerover', showTip);
grids.addEventListener('pointerout', () => tip.classList.remove('on'));

failPanel();
render();

/* ---------------------------------------------------------------------------
   Everything the page says about ITSELF, written from META rather than typed
   into the HTML. The shell used to read "9 resorts - 27 winters - 2.13 million
   hours"; that was true the day it was written and wrong from the next build
   onward, which is not a state a page shipping its own data should be able to
   reach. Each <span data-meta="key"> below is filled from the build facts
   h14_export.sql measured.

   Findings from the nine-resort calibration study are deliberately NOT in here.
   Those are results of a finished experiment, not a description of this build,
   and rewriting them per build would make them claim something they never
   showed. They stay fixed in the prose, labelled as that sample's numbers.
   --------------------------------------------------------------------------- */
const METAFMT = {
  resorts:     () => META.resorts,
  refResorts:  () => META.refResorts,
  winters:     () => META.winters,
  years:       () => META.firstYear + '\u2013' + META.lastYear,
  snotelReach: () => META.snotelReach,
  badged:      () => META.badged,
  // "2.13 million" / "473 thousand" / "8,400" -- scaled so the eyebrow stays
  // readable whether two resorts are loaded or all 431
  hours: () => {
    const h = META.hours;
    if (h >= 1e6) return (h / 1e6).toFixed(2).replace(/\.?0+$/, '') + ' million';
    if (h >= 1e4) return Math.round(h / 1e3) + ' thousand';
    return h.toLocaleString();
  },
  // a six-day window replayed across every winter on record
  obs6: () => 6 * META.winters,
  baseMeasuredPct: () => META.baseMeasuredPct + '%',
  flatLightPct:    () => META.flatLightPct + '%',
  // one decimal always: 2.0 must not print as "2 days a season"
  epicRange: () => (META.epicMin === META.epicMax
    ? META.epicMin.toFixed(1) + ' days a season'
    : META.epicMin.toFixed(1) + ' to ' + META.epicMax.toFixed(1) + ' days a season'),
  // "All 9 resorts here have" vs "6 of 9 resorts here have"
  gaugeCoverage: () => (META.measured === META.resorts
    ? 'All ' + META.resorts + ' resorts here have'
    : META.measured + ' of the ' + META.resorts + ' resorts here have'),
  // Noun included, so a one-resort build does not read "1 resorts". Cheap
  // insurance: the eyebrow is the first thing on the page.
  resortCount: () => META.resorts + (META.resorts === 1 ? ' resort' : ' resorts'),
  winterCount: () => META.winters + (META.winters === 1 ? ' winter' : ' winters'),
};

/* The coverage caveat is a whole sentence rather than a number, because which
   sentence is true depends on whether the reference file has been fully
   fetched. Leaving the "not all of them yet" wording in place after a complete
   build would have it read "431 resorts, not 431". */
const cov = document.getElementById('coverageNote');
if (cov){
  const tail = ' Where the source file is missing acreage or terrain mix for a resort, its '
             + 'green figures are blank.';
  /* Three states, and telling them apart matters: a deliberate editorial cut
     must not read as missing data, and a part-finished fetch must not read as
     a finished one. */
  if (META.minVert && META.resorts >= META.eligible){
    cov.innerHTML = '<b>' + META.resorts + ' mountains, not all ' + META.refResorts + '.</b> '
      + 'The reference file holds ' + META.refResorts + ', and this page covers every one with '
      + 'at least <b>' + META.minVert + ' feet of vertical</b> &mdash; the rest are real ski '
      + 'areas, but not ones you plan a trip around. The cut sits a foot under Mount Bohemia '
      + 'rather than at a round 900 so that mountain stays in. Everything below it is still '
      + 'modelled and still in the database; it is not on this page.' + tail;
  } else if (META.resorts >= META.refResorts){
    cov.innerHTML = '<b>All ' + META.refResorts + ' resorts.</b> Every row in the reference file '
      + 'has had its hourly record fetched and loaded.' + tail;
  } else {
    cov.innerHTML = '<b>' + META.resorts + ' resorts, not ' + META.refResorts + '.</b> The '
      + 'reference file holds ' + META.refResorts + ' and every row carries a ready hourly API '
      + 'call, but only ' + META.loaded + ' have been fetched so far. Everything here scales to '
      + 'the rest unchanged.' + tail;
  }
}

document.querySelectorAll('[data-meta]').forEach(function(el){
  const f = METAFMT[el.getAttribute('data-meta')];
  if (f) el.textContent = f();
  else el.textContent = '?';   // loud, not silent, if a key is ever renamed
});
