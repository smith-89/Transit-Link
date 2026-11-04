/* Shared helpers: API wrapper, formatting, DOM shortcuts and the login session.
   Plain script, no build step. Uses `var` and `function` only so every page can share it. */
var API = '/api';
var TZ = 'Africa/Nairobi';

function go(url) { location.assign(url); }

async function api(path, opts) {
  opts = opts || {};
  var h = Object.assign({}, opts.headers || {});
  if (opts.body !== undefined) h['Content-Type'] = 'application/json';
  if (opts.token) h['Authorization'] = 'Bearer ' + opts.token;
  var res = await fetch(API + path, {
    method: opts.method || 'GET',
    headers: h,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  var data = null;
  try { data = await res.json(); } catch (_) { /* empty body */ }
  if (!res.ok) {
    var detail = data && data.detail;
    if (Array.isArray(detail)) detail = detail.map(function (d) { return (d.msg || '').replace(/^Value error, /, ''); }).join(' ');
    var err = new Error(detail || 'Something went wrong (' + res.status + ').');
    err.status = res.status;
    throw err;
  }
  return data;
}

function kes(n) { return (n < 0 ? '-' : '') + Math.abs(n).toLocaleString('en-KE'); }
function dayKey(iso) { return new Date(iso).toLocaleDateString('en-CA', { timeZone: TZ }); }
function dayShort(iso) { return new Date(iso).toLocaleDateString('en-GB', { weekday: 'short', timeZone: TZ }); }
function whenShort(iso) {
  var today = dayKey(new Date().toISOString());
  if (dayKey(iso) === today) return 'Today';
  return new Date(iso).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: TZ });
}
function whenFull(iso) {
  return new Date(iso).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: TZ });
}
function $(id) { return document.getElementById(id); }
function show(el, on) { el.classList.toggle('hidden', !on); }
function say(el, text, kind) {
  el.textContent = text || '';
  el.className = 'note' + (kind ? ' ' + kind : '');
  show(el, !!text);
}

/* One session for everyone. The role is decided at sign-in, never chosen by the user. */
var Session = {
  key: 'tl_session',
  get: function () { try { return JSON.parse(localStorage.getItem('tl_session') || 'null'); } catch (_) { return null; } },
  set: function (s) { localStorage.setItem('tl_session', JSON.stringify(s)); },
  clear: function () { localStorage.removeItem('tl_session'); },
  home: function (role) { return { rider: '/rider/', operator: '/operator/', validator: '/validator/' }[role] || '/login/'; },
  /* Call at the top of a protected page. Sends visitors to the right place if the role is wrong. */
  require: function (role) {
    var s = Session.get();
    if (!s) { go('/login/'); return null; }
    if (s.role !== role) { go(Session.home(s.role)); return null; }
    return s;
  },
  signOut: function () { Session.clear(); go('/'); },
};
