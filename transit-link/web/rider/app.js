/* Rider app. Calls: GET /wallet, GET /pass, POST /topups, GET /topups/{id},
   POST /dev/mpesa/confirm/{checkout_request_id} (demo mode only).
   Phones show one view at a time with the pill nav; desktop shows every view at once. */
var PASS_REFRESH = 60;     // seconds between new QR codes
var session = Session.require('rider');
var token = session && session.token;
var wallet = null;
var tab = 'spent';
var selDay = null; // null = pick the busiest day
var qr = null;
var passLeft = PASS_REFRESH;
var pollTimer = null;
var currentTopup = null;

function isDesktop() { return window.matchMedia('(min-width: 1000px)').matches; }

/* ---------- navigation ---------- */
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

/* ---------- wallet ---------- */
function weekData(history) {
  var days = [];
  var now = Date.now();
  for (var i = 6; i >= 0; i--) {
    var iso = new Date(now - i * 86400000).toISOString();
    days.push({ key: dayKey(iso), label: dayShort(iso), spent: 0, added: 0 });
  }
  var idx = {};
  days.forEach(function (d, i) { idx[d.key] = i; });
  history.forEach(function (h) {
    var k = dayKey(h.at);
    if (!(k in idx)) return;
    var d = days[idx[k]];
    if (h.kind === 'refund') d.spent -= h.amount;   // a fare refund reduces what you spent
    else if (h.amount < 0) d.spent += -h.amount;
    else d.added += h.amount;
  });
  return days;
}

function txnItem(h) {
  var inn = h.amount > 0;
  var li = document.createElement('li');
  li.className = 'txn';
  var amt = document.createElement('div');
  amt.className = 'amt';
  amt.innerHTML = '<small>KES</small>' + kes(Math.abs(h.amount));
  var what = document.createElement('div');
  what.className = 'what';
  var dot = document.createElement('i');
  dot.className = 'dot' + (inn ? ' in' : '');
  var text = document.createElement('span');
  text.textContent = h.label;
  var sr = document.createElement('span');
  sr.className = 'sr-only';
  sr.textContent = inn ? ' (added)' : ' (spent)';
  what.append(dot, text, sr);
  var side = document.createElement('div');
  side.className = 'side';
  var b = document.createElement('span');
  b.className = 'icon-btn dark sm';
  b.innerHTML = icon(inn ? 'plus' : 'up', 18);
  var when = document.createElement('div');
  when.className = 'when';
  when.textContent = whenShort(h.at);
  side.append(b, when);
  li.append(amt, what, side);
  return li;
}

function fillList(ul, emptyEl, items) {
  ul.innerHTML = '';
  items.forEach(function (h) { ul.appendChild(txnItem(h)); });
  show(emptyEl, items.length === 0);
}

function renderChart() {
  var days = weekData(wallet.history);
  var values = days.map(function (d) { return d[tab]; });
  var total = values.reduce(function (a, b) { return a + b; }, 0);
  if (selDay === null) selDay = values.lastIndexOf(Math.max.apply(null, values));
  $('chart-total').innerHTML = '<small>KES</small>' + (tab === 'added' && total ? '+' : '') + kes(total);
  barChart($('chart'), {
    labels: days.map(function (d) { return d.label; }),
    values: values,
    selected: selDay,
    fmt: function (v) { return 'KES ' + kes(v); },
    onSelect: function (i) { selDay = i; renderChart(); },
  });
  var net = days.reduce(function (a, d) { return a + d.added - d.spent; }, 0);
  var any = days.some(function (d) { return d.added || d.spent; });
  $('delta').textContent = any ? (net > 0 ? '+' : (net < 0 ? '-' : '')) + 'KES ' + kes(Math.abs(net)) + ' this week' : 'No activity this week';
}

function render() {
  var w = wallet;
  $('balance').textContent = kes(w.balance);
  $('greeting').textContent = 'Hi, ' + w.name.split(' ')[0];
  $('pass-name').textContent = w.name;
  $('sheet-name').textContent = w.name;
  $('sheet-phone').textContent = '+' + w.phone.replace(/^(\d{3})(\d{3})(\d{3})(\d{3})$/, '$1 $2 $3 $4');
  if (w.balance < 0) say($('neg-note'), 'Your balance is KES ' + kes(Math.abs(w.balance)) + ' below zero. Top up to keep riding.', 'err');
  else say($('neg-note'), '');
  renderChart();
  fillList($('recent'), $('recent-empty'), w.history.slice(0, 3));
  fillList($('all'), $('all-empty'), w.history);
  $('count').textContent = w.history.length ? 'Latest ' + w.history.length : '';
}

async function loadWallet() {
  try {
    wallet = await api('/wallet', { token: token });
  } catch (err) {
    if (err.status === 401 || err.status === 403) return Session.signOut();
    say($('neg-note'), "Can't reach the server. Showing your last known balance.", 'err');
    return;
  }
  render();
}

/* ---------- QR pass: a signed code that is replaced every minute ---------- */
function paintTimer() {
  var m = Math.floor(passLeft / 60), s = passLeft % 60;
  $('pass-timer').textContent = m + ':' + String(s).padStart(2, '0');
  $('pass-meter').style.width = Math.max(0, Math.min(100, (passLeft / PASS_REFRESH) * 100)) + '%';
}

async function refreshPass() {
  try {
    var p = await api('/pass', { token: token });
    if (typeof QRCode === 'undefined') {
      $('pass-note').textContent = "The QR library didn't load. Check your connection and reload.";
      return;
    }
    if (!qr) qr = new QRCode($('qr'), { text: p.token, width: 210, height: 210, correctLevel: QRCode.CorrectLevel.M });
    else { qr.clear(); qr.makeCode(p.token); }
    passLeft = PASS_REFRESH;
    $('pass-note').textContent = 'Hold this code up to the scanner.';
  } catch (err) {
    if (err.status === 401 || err.status === 403) return Session.signOut();
    passLeft = 15;
    $('pass-note').textContent = "You're offline. Reconnect to get a fresh code.";
  }
  paintTimer();
}

setInterval(function () {
  if (!token || document.hidden) return;
  passLeft -= 1;
  if (passLeft <= 0) { passLeft = PASS_REFRESH; refreshPass(); }
  paintTimer();
}, 1000);

/* ---------- top-up ---------- */
function setAmount(v) {
  $('amount').value = v;
  document.querySelectorAll('[data-amt]').forEach(function (c) { c.setAttribute('aria-pressed', c.getAttribute('data-amt') === String(v) ? 'true' : 'false'); });
}

async function onTopup(e) {
  e.preventDefault();
  var btn = $('topup-btn');
  btn.disabled = true;
  show($('confirm-btn'), false);
  try {
    var body = { amount: parseInt($('amount').value.replace(/,/g, ''), 10) };
    if (isNaN(body.amount)) throw new Error('Enter an amount in shillings.');
    if ($('topup-phone').value.trim()) body.phone = $('topup-phone').value;
    currentTopup = await api('/topups', { method: 'POST', body: body, token: token });
    if (currentTopup.mode === 'mock') {
      say($('topup-msg'), 'Demo mode: no real M-Pesa prompt is sent. Tap "Approve on phone" to simulate entering your PIN.');
      show($('confirm-btn'), true);
    } else {
      say($('topup-msg'), 'Check your phone and enter your M-Pesa PIN.');
      pollTopup();
    }
  } catch (err) {
    say($('topup-msg'), err.message, 'err');
  } finally {
    btn.disabled = false;
  }
}

async function onConfirm() {
  try {
    finishTopup(await api('/dev/mpesa/confirm/' + currentTopup.checkout_request_id, { method: 'POST', token: token }));
  } catch (err) { say($('topup-msg'), err.message, 'err'); }
}

function pollTopup() {
  clearInterval(pollTimer);
  var tries = 0;
  pollTimer = setInterval(async function () {
    tries += 1;
    try {
      var res = await api('/topups/' + currentTopup.id, { token: token });
      if (res.status !== 'pending') finishTopup(res);
    } catch (_) { /* keep trying */ }
    if (tries > 30) { clearInterval(pollTimer); say($('topup-msg'), 'Still waiting. If you paid, your balance will update shortly.'); }
  }, 2000);
}

async function finishTopup(res) {
  clearInterval(pollTimer);
  show($('confirm-btn'), false);
  if (res.status === 'success') {
    say($('topup-msg'), 'Added KES ' + kes(res.amount) + '. M-Pesa receipt ' + res.receipt + '.', 'ok');
    await loadWallet();
  } else {
    say($('topup-msg'), 'The top-up did not go through' + (res.message ? ': ' + res.message : '.') + ' You were not charged.', 'err');
  }
}

/* ---------- start ---------- */
function start() {
  mountIcons();
  document.querySelectorAll('[data-view]').forEach(function (b) { b.onclick = function () { setView(b.getAttribute('data-view')); }; });
  document.querySelectorAll('[data-go]').forEach(function (b) { b.onclick = function () { setView(b.getAttribute('data-go')); }; });
  document.querySelectorAll('[data-tab]').forEach(function (c) {
    c.onclick = function () {
      tab = c.getAttribute('data-tab');
      selDay = null;
      document.querySelectorAll('[data-tab]').forEach(function (x) { x.setAttribute('aria-pressed', x === c ? 'true' : 'false'); });
      if (wallet) renderChart();
    };
  });
  document.querySelectorAll('[data-amt]').forEach(function (c) { c.onclick = function () { setAmount(c.getAttribute('data-amt')); }; });
  $('amount').oninput = function () { setAmount($('amount').value); };
  $('topup-form').onsubmit = onTopup;
  $('confirm-btn').onclick = onConfirm;
  $('pass-shortcut').onclick = function () { setView('pass'); };
  $('refresh').onclick = function () { loadWallet(); refreshPass(); };
  $('menu-btn').onclick = function () { openMenu(true); };
  $('sheet-close').onclick = function () { openMenu(false); };
  $('sheet-back').onclick = function (e) { if (e.target === $('sheet-back')) openMenu(false); };
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') openMenu(false); });
  $('signout').onclick = Session.signOut;
  loadWallet();
  refreshPass();
}

if (session) start();
