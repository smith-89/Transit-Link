/* Operator dashboard. Calls: GET /operator/summary, /operator/flags, /operator/payouts,
   POST /operator/payouts/run. Phones: one view at a time with the pill nav. Desktop: everything at once. */
var session = Session.require('operator');
var token = session && session.token;
var data = null;
var tab = 'revenue';
var selDay = null; // null = pick the busiest day
var timer = null;

var REASON_TEXT = {
  double_tap: 'Charged twice at one point within 2 minutes',
  impossible_travel: 'Two different points within 5 minutes',
  rapid_burst: '4 or more trips in one hour',
  model_outlier: 'Unusual pattern (anomaly model)',
  missed_tap_out: 'Never tapped out: charged the maximum fare',
  exit_without_entry: 'Exit scan with no matching boarding scan',
};

function isDesktop() { return window.matchMedia('(min-width: 1000px)').matches; }

function setView(name) {
  if (isDesktop()) {
    var el = $('v-' + name);
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return;
  }
  document.querySelectorAll('.view').forEach(function (v) { v.classList.toggle('active', v.id === 'v-' + name); });
  document.querySelectorAll('.pillnav button').forEach(function (b) {
    if (b.getAttribute('data-view') === name) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
  });
  window.scrollTo({ top: 0 });
}

function openMenu(on) {
  show($('sheet-back'), on);
  if (on) $('sheet-close').focus(); else $('menu-btn').focus();
}

function li(left, right, extra) {
  var el = document.createElement('li');
  el.append(left, right);
  if (extra) el.appendChild(extra);
  return el;
}

function div(cls, html) {
  var d = document.createElement('div');
  if (cls) d.className = cls;
  if (html !== undefined) d.innerHTML = html;
  return d;
}

function esc(s) { var d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

function renderChart() {
  var days = data.summary.daily;
  var values = days.map(function (d) { return d[tab]; });
  var total = values.reduce(function (a, b) { return a + b; }, 0);
  if (selDay === null) selDay = values.lastIndexOf(Math.max.apply(null, values));
  $('chart-total').innerHTML = (tab === 'revenue' ? '<small>KES</small>' : '') + kes(total);
  barChart($('chart'), {
    labels: days.map(function (d) { return dayShort(d.date + 'T12:00:00Z'); }),
    values: values,
    selected: selDay,
    fmt: function (v) { return (tab === 'revenue' ? 'KES ' : '') + kes(v) + (tab === 'trips' ? ' trips' : ''); },
    onSelect: function (i) { selDay = i; renderChart(); },
  });
}

function render() {
  var s = data.summary;
  $('op-name').textContent = s.operator;
  $('sheet-name').textContent = s.operator;
  $('rev').textContent = kes(s.today.revenue);
  $('rev-delta').textContent = s.today.trips + ' trips · ' + s.today.riders + ' riders';
  $('t-unpaid').textContent = kes(s.unpaid_revenue);
  $('t-riders').textContent = kes(s.today.riders);
  $('t-declined').textContent = kes(s.today.declined);
  $('t-open').textContent = kes(s.open_journeys);
  renderChart();

  // demand by hour, with the busiest hours solid
  barChart($('hourly'), {
    labels: s.hourly_profile.map(function (_, h) { return String(h); }),
    values: s.hourly_profile,
    highlight: s.forecast_peak_hours,
    fmt: function (v) { return v + ' trips on a typical day'; },
    compact: true, labelEvery: 3,
  });
  $('peaks').textContent = s.forecast_peak_hours.length
    ? 'Expect the busiest hours around ' + s.forecast_peak_hours.map(function (h) { return String(h).padStart(2, '0') + ':00'; }).join(', ') + ' (Nairobi time, solid bars).'
    : 'Not enough trips yet to show a pattern.';

  // boarding points
  var ul = $('stations');
  ul.innerHTML = '';
  var top = Math.max.apply(null, [1].concat(s.by_station.map(function (r) { return r.trips; })));
  s.by_station.forEach(function (r) {
    var meter = div('meter thin on-dark');
    meter.innerHTML = '<i style="width:' + Math.round((r.trips / top) * 100) + '%"></i>';
    ul.appendChild(li(div('', '<div style="font-size:1.1rem">' + esc(r.station) + '</div><div class="muted small">KES ' + kes(r.revenue) + '</div>'), div('big', kes(r.trips) + ' <span class="muted small">trips</span>'), meter));
  });
  show($('stations-empty'), s.by_station.length === 0);

  // flags
  var fl = $('flags');
  fl.innerHTML = '';
  data.flags.slice(0, 40).forEach(function (f) {
    var tags = f.reasons.map(function (r) { return '<span class="tag">' + esc(REASON_TEXT[r] || r) + '</span>'; }).join('');
    var left = div('', tags + '<div class="flag-meta">Rider #' + f.rider_id + ' · ' + esc(f.station) + ' · ' + whenFull(f.tapped_at) + '</div>');
    var right = div('muted small', f.score !== null ? 'score ' + f.score : '');
    fl.appendChild(li(left, right));
  });
  show($('flags-empty'), data.flags.length === 0);

  // payouts
  var pl = $('payouts');
  pl.innerHTML = '';
  data.payouts.forEach(function (p) {
    pl.appendChild(li(div('', '<div style="font-size:1.1rem">' + whenFull(p.created_at) + '</div><div class="muted small">' + p.trips + ' trips · fee KES ' + kes(p.fee) + '</div>'), div('big', '<small class="muted" style="font-size:.5em">KES</small> ' + kes(p.net))));
  });
  show($('payouts-empty'), data.payouts.length === 0);
}

async function load() {
  var r;
  try {
    r = await Promise.all([
      api('/operator/summary', { token: token }),
      api('/operator/flags', { token: token }),
      api('/operator/payouts', { token: token }),
    ]);
  } catch (err) {
    if (err.status === 401 || err.status === 403) Session.signOut();
    return; // offline or server error: keep what is on screen and retry on the next refresh
  }
  data = { summary: r[0], flags: r[1].flags, payouts: r[2].payouts };
  render();
}

function payoutMsg(text, kind) { say($('payout-msg'), text, kind); say($('payout-msg2'), text, kind); }

async function runPayout() {
  document.querySelectorAll('.payout-btn').forEach(function (b) { b.disabled = true; });
  try {
    var p = await api('/operator/payouts/run', { method: 'POST', token: token });
    payoutMsg('Simulated payout of KES ' + kes(p.net) + ' for ' + p.trips + ' trips (fee KES ' + kes(p.fee) + '). No real money moved.', 'ok');
    load();
  } catch (err) {
    payoutMsg(err.message, 'err');
  } finally {
    document.querySelectorAll('.payout-btn').forEach(function (b) { b.disabled = false; });
  }
}

function start() {
  mountIcons();
  document.querySelectorAll('[data-view]').forEach(function (b) { b.onclick = function () { setView(b.getAttribute('data-view')); }; });
  document.querySelectorAll('[data-go]').forEach(function (b) { b.onclick = function () { setView(b.getAttribute('data-go')); }; });
  document.querySelectorAll('[data-tab]').forEach(function (c) {
    c.onclick = function () {
      tab = c.getAttribute('data-tab');
      selDay = null;
      document.querySelectorAll('[data-tab]').forEach(function (x) { x.setAttribute('aria-pressed', x === c ? 'true' : 'false'); });
      if (data) renderChart();
    };
  });
  document.querySelectorAll('.payout-btn').forEach(function (b) { b.onclick = runPayout; });
  $('refresh').onclick = load;
  $('menu-btn').onclick = function () { openMenu(true); };
  $('sheet-close').onclick = function () { openMenu(false); };
  $('sheet-back').onclick = function (e) { if (e.target === $('sheet-back')) openMenu(false); };
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') openMenu(false); });
  $('signout').onclick = Session.signOut;
  load();
  timer = setInterval(function () { if (!document.hidden) load(); }, 15000);
}

if (session) start();
