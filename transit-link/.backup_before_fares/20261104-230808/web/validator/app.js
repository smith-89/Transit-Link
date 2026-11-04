/* Validator (gate scanner). Scans rider QR passes, queues every tap on the device (IndexedDB)
   and syncs the queue to POST /taps/sync whenever a connection exists.
   The gate decision never waits for the network: a readable, unexpired pass is accepted and
   queued. The SERVER decides charge / decline / reject when the batch arrives.
   The device key comes from the sign-in session, so there is no setup screen. */
var session = Session.require('validator');
var STORE = 'taps';
var simulateOffline = false;
var syncing = false;
var stream = null;
var lastText = '';
var lastAt = 0;
var recent = []; // latest sync results, newest first

/* ---------- IndexedDB queue ---------- */
var dbp = new Promise(function (resolve, reject) {
  var req = indexedDB.open('tl-validator', 1);
  req.onupgradeneeded = function () { req.result.createObjectStore(STORE, { keyPath: 'tap_id' }); };
  req.onsuccess = function () { resolve(req.result); };
  req.onerror = function () { reject(req.error); };
});
function putTap(tap) {
  return dbp.then(function (db) {
    return new Promise(function (res, rej) {
      var tx = db.transaction(STORE, 'readwrite');
      tx.objectStore(STORE).put(tap);
      tx.oncomplete = function () { res(); };
      tx.onerror = function () { rej(tx.error); };
    });
  });
}
function allTaps() {
  return dbp.then(function (db) {
    return new Promise(function (res, rej) {
      var req = db.transaction(STORE, 'readonly').objectStore(STORE).getAll();
      req.onsuccess = function () { res(req.result); };
      req.onerror = function () { rej(req.error); };
    });
  });
}
function deleteTaps(ids) {
  return dbp.then(function (db) {
    return new Promise(function (res, rej) {
      var tx = db.transaction(STORE, 'readwrite');
      ids.forEach(function (id) { tx.objectStore(STORE).delete(id); });
      tx.oncomplete = function () { res(); };
      tx.onerror = function () { rej(tx.error); };
    });
  });
}

/* ---------- helpers ---------- */
function newId() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  return 'tap-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
}

/* Read the pass payload WITHOUT verifying the signature (the server verifies it). */
function readPass(text) {
  var parts = text.trim().split('.');
  if (parts.length !== 3) return null;
  try {
    var b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    var p = JSON.parse(atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4)));
    return p && p.typ === 'pass' && p.exp ? p : null;
  } catch (_) { return null; }
}

function lamp(kind, title, sub) {
  $('lamp').className = 'lamp' + (kind ? ' ' + kind : '');
  $('lamp-title').textContent = title;
  $('lamp-sub').textContent = sub || '';
}

function beep(ok) {
  try {
    var ctx = new (window.AudioContext || window.webkitAudioContext)();
    var o = ctx.createOscillator();
    o.frequency.value = ok ? 880 : 220;
    o.connect(ctx.destination);
    o.start();
    o.stop(ctx.currentTime + (ok ? 0.12 : 0.3));
  } catch (_) { /* sound is optional */ }
  if (navigator.vibrate) navigator.vibrate(ok ? 60 : [80, 60, 80]);
}

function isOnline() { return navigator.onLine && !simulateOffline; }

async function refreshStatus() {
  var pill = $('net-pill');
  pill.textContent = isOnline() ? 'Online' : 'Offline';
  pill.className = 'pill' + (isOnline() ? '' : ' off');
  var n = (await allTaps()).length;
  $('queue-pill').textContent = n + ' waiting';
}

/* ---------- accepting a scan ---------- */
async function onScan(text) {
  var now = Date.now();
  if (text === lastText && now - lastAt < 4000) return; // same code still in view
  lastText = text;
  lastAt = now;

  var pass = readPass(text);
  if (!pass) {
    lamp('stop', 'Not a Transit Link pass', 'Ask the rider to open their app.');
    return beep(false);
  }
  if (now / 1000 > pass.exp + 30) {
    lamp('warn', 'Pass expired', 'Ask the rider to wait for the code to refresh.');
    return beep(false);
  }
  await putTap({ tap_id: newId(), pass_token: text.trim(), tapped_at: new Date().toISOString() });
  lamp('go', 'Go ahead', isOnline() ? 'Pass read. Sending to the server.' : 'Pass read. Saved on this device, will sync when online.');
  beep(true);
  await refreshStatus();
  syncNow();
}

async function onManual() {
  var text = $('manual').value.trim();
  if (text) { await onScan(text); $('manual').value = ''; }
}

/* ---------- camera ---------- */
async function startCamera() {
  if (typeof jsQR === 'undefined') {
    return say($('cam-msg'), 'The scanner library did not load. Connect once to download it, or paste a pass below.', 'err');
  }
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
  } catch (err) {
    return say($('cam-msg'), 'Camera blocked or unavailable. Allow camera access (the page must be on HTTPS or localhost), or paste a pass below.', 'err');
  }
  say($('cam-msg'), '');
  var video = $('video');
  video.srcObject = stream;
  await video.play();
  $('cam-btn').lastChild.textContent = ' Stop camera';
  tick();
}

function stopCamera() {
  if (stream) stream.getTracks().forEach(function (t) { t.stop(); });
  stream = null;
  $('cam-btn').lastChild.textContent = ' Start camera';
}

function tick() {
  if (!stream) return;
  var video = $('video');
  if (video.readyState === video.HAVE_ENOUGH_DATA && video.videoWidth) {
    var scale = Math.min(1, 640 / video.videoWidth);
    var canvas = $('canvas');
    canvas.width = Math.round(video.videoWidth * scale);
    canvas.height = Math.round(video.videoHeight * scale);
    var ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    var img = ctx.getImageData(0, 0, canvas.width, canvas.height);
    var code = jsQR(img.data, img.width, img.height, { inversionAttempts: 'dontInvert' });
    if (code && code.data) onScan(code.data);
  }
  setTimeout(function () { requestAnimationFrame(tick); }, 120);
}

/* ---------- sync ---------- */
var REASONS = {
  insufficient_funds: 'Balance too low',
  replayed_pass: 'Pass already used',
  stale_pass: 'Pass was not valid at that time',
  invalid_pass: 'Not a valid pass',
  unknown_rider: 'Unknown rider',
};

function renderLog() {
  var ul = $('log');
  ul.innerHTML = '';
  recent.slice(0, 6).forEach(function (r) {
    var ok = r.status === 'charged';
    var li = document.createElement('li');
    li.className = 'txn';
    var amt = document.createElement('div');
    amt.className = 'amt';
    amt.innerHTML = ok ? '<small>KES</small>' + kes(r.fare) : '<span style="font-size:.6em">' + (r.status === 'declined' ? 'Declined' : 'Rejected') + '</span>';
    var what = document.createElement('div');
    what.className = 'what';
    var dot = document.createElement('i');
    dot.className = 'dot' + (ok ? ' in' : '');
    var text = document.createElement('span');
    text.textContent = ok ? 'Charged · tap ' + r.tap_id.slice(0, 8) : (REASONS[r.reason] || r.reason);
    what.append(dot, text);
    var side = document.createElement('div');
    side.className = 'side';
    var b = document.createElement('span');
    b.className = 'icon-btn dark sm';
    b.innerHTML = icon(ok ? 'check' : 'alert', 18);
    side.appendChild(b);
    li.append(amt, what, side);
    ul.appendChild(li);
  });
  show($('log-empty'), recent.length === 0);
}

async function syncNow() {
  if (syncing || !isOnline()) return;
  var queued = (await allTaps()).sort(function (a, b) { return a.tapped_at.localeCompare(b.tapped_at); }).slice(0, 200);
  if (!queued.length) return;
  syncing = true;
  try {
    var res = await api('/taps/sync', { method: 'POST', body: { taps: queued }, headers: { 'X-Validator-Key': session.key } });
    await deleteTaps(res.results.map(function (r) { return r.tap_id; }));
    res.results.forEach(function (r) { recent.unshift(r); });
    renderLog();
    var bad = res.results.find(function (r) { return r.status !== 'charged' && !r.duplicate; });
    if (bad) lamp(bad.status === 'declined' ? 'warn' : 'stop', bad.status === 'declined' ? 'Declined after sync' : 'Rejected after sync', REASONS[bad.reason] || bad.reason);
    else lamp('go', 'Synced', res.results.length + ' tap(s) processed.');
  } catch (err) {
    if (err.status === 401) { lamp('stop', 'Device not recognised', 'Sign out and sign in again.'); }
    /* network errors: keep the queue and retry later */
  } finally {
    syncing = false;
    refreshStatus();
  }
}

/* ---------- start ---------- */
function showConfig(cfg) {
  $('station').textContent = cfg.station;
  $('operator').textContent = cfg.operator + ' · ' + cfg.validator;
  $('fare').innerHTML = '<small>KES</small>' + kes(cfg.fare);
}

function start() {
  mountIcons();
  showConfig(session.cfg); // cached at sign-in, so the screen works with no connection
  $('cam-btn').onclick = function () { return stream ? stopCamera() : startCamera(); };
  $('sync-btn').onclick = syncNow;
  $('manual-btn').onclick = onManual;
  $('offline-sw').onchange = function (e) { simulateOffline = e.target.checked; refreshStatus(); if (isOnline()) syncNow(); };
  $('signout').onclick = async function () {
    var waiting = (await allTaps()).length;
    if (waiting && !confirm(waiting + ' taps have not synced yet. They stay on this device but cannot sync until you sign in again. Sign out anyway?')) return;
    stopCamera();
    Session.signOut();
  };
  window.addEventListener('online', function () { refreshStatus(); syncNow(); });
  window.addEventListener('offline', refreshStatus);
  setInterval(function () { refreshStatus(); syncNow(); }, 10000);
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(function () {});
  refreshStatus();
  syncNow();
  // refresh the cached station and fare whenever we are online
  api('/validator/config', { headers: { 'X-Validator-Key': session.key } }).then(function (cfg) {
    session.cfg = cfg;
    Session.set(session);
    showConfig(cfg);
  }).catch(function (err) {
    if (err.status === 401) { Session.clear(); go('/login/'); }
  });
}

if (session) start();
