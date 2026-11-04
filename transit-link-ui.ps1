<#
.SYNOPSIS
    Transit Link UI bundle - the new front end only (landing page, single sign-in, rider app,
    validator and operator dashboard). The backend is not touched.

.DESCRIPTION
    Writes the contents of web\ plus docs\UI.md into an existing Transit Link project, replacing the
    old front-end files. Every file is stored below as readable text, so you can also open this script
    and read the UI code in order (docs/UI.md first, then web/shared/*, then each page).

.PARAMETER Target
    The Transit Link project folder (the one that contains app\ and web\). Default: .\transit-link

.EXAMPLE
    .\transit-link-ui.ps1 -Target .\transit-link
    cd transit-link ; uvicorn app.main:app --reload     # then open http://localhost:8000

.NOTES
    Needs PowerShell 5.1 or newer. Works with the API from the first Transit Link bundle, unchanged.
#>
param([string]$Target = "transit-link")

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$root = if ([System.IO.Path]::IsPathRooted($Target)) { $Target } else { Join-Path (Get-Location).Path $Target }
$root = [System.IO.Path]::GetFullPath($root)

if (-not (Test-Path (Join-Path $root "app\main.py"))) {
    Write-Host "Warning: '$root' does not look like a Transit Link project (app\main.py not found)." -ForegroundColor Yellow
    Write-Host "The UI files will still be written there. Use -Target to point at your project folder." -ForegroundColor Yellow
}

function Write-BundleFile([string]$RelPath, [string]$Content) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $RelPath))
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content + "`n", $utf8)
    Write-Host "  wrote $RelPath"
}

Write-Host "Writing the new UI into $root" -ForegroundColor Cyan
$script:count = 0

# The old stylesheet is replaced by shared/theme.css and shared/site.css.
$old = Join-Path $root "web\shared\style.css"
if (Test-Path $old) { Remove-Item $old -Force; Write-Host "  removed web/shared/style.css (replaced)" }

# ---------------------------------------------------------------------------
# docs/UI.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/UI.md' @'
# User interface guide

The front end is plain HTML, CSS and JavaScript in `web/`. There is no build step and no framework.
FastAPI serves the folder, so `/` is the landing page and the app screens sit beside it.

## Pages

| URL | Purpose | Files |
| --- | --- | --- |
| `/` | Landing page | `web/index.html`, `shared/site.css` |
| `/login/` | One sign-in and sign-up form for everyone | `web/login/index.html`, `app.js` |
| `/rider/` | Wallet, QR pass, M-Pesa top-up, activity | `web/rider/` |
| `/operator/` | Revenue, demand, suspicious trips, payouts | `web/operator/` |
| `/validator/` | Gate scanner with offline queue | `web/validator/` (also `sw.js`) |
| shared | Theme, API helper and session, icons and chart | `web/shared/theme.css`, `api.js`, `ui.js` |

## Sign-in routing (nothing about account types is shown on the form)

The form has two fields, "Account" and "Passcode". What is typed decides the destination.

| Typed in Account | Passcode | Tried against | Lands on |
| --- | --- | --- | --- |
| A phone number | PIN | `POST /auth/login` | `/rider/` |
| Anything else | Password | `POST /auth/operator/login` | `/operator/` |
| Anything else, or the operator step failed | (empty) | `GET /validator/config` with the value as the device key | `/validator/` |

- Every failed attempt shows the same message, so the screen never reveals which kinds of account exist.
- "Create an account" is for riders only (`POST /auth/register`).
- The result is stored as one `tl_session` in `localStorage`: `{role, token | key, name}`.
- Each protected page calls `Session.require('<role>')` first. Signed-out visitors go to `/login/`; someone
  with the wrong role is sent to their own screen.

Demo logins for the team (they are deliberately not shown anywhere in the UI):

| Who | Account | Passcode |
| --- | --- | --- |
| Rider | 0712 345 678 | 1234 |
| Rider with history | 0700 000 000 | 0000 |
| Operator | rail | demo1234 |
| Operator (feeder) | sacco | demo1234 |
| Gate device | demo-validator-key-1 | (leave empty) |

A device key works like a password: anyone who has it can sign in as that device. Issue real keys per
device and rotate them if a device is lost.

## Design system

Taken from the supplied reference: dark green backdrop, lime `#DCFFAD`, white `#FFFFFF`, sage `#7B9575`,
ink `#1C2120`, SF Pro Display (falls back to the system font on devices without it), hatched fills,
a floating pill navigation and round icon buttons. All tokens are CSS variables at the top of
`shared/theme.css`.

| Piece | Where |
| --- | --- |
| Buttons (`btn-white`, `btn-lime`, `btn-black`, `btn-ghost`, `icon-btn`) | `theme.css` |
| Cards (`card-white`, `card-lime`, `card-glass`, `card-dark`), tiles | `theme.css` |
| Hatched bar chart with one solid bar and a white tooltip | `ui.js` `barChart()`, bar styles in `theme.css` |
| Hatched progress meter (QR countdown, boarding points) | `.meter` in `theme.css` |
| Icons and the seven-point brand star | `ui.js` (`icon()`, `star()`, `mountIcons()`) |

## Responsive behaviour

- Phones: one view at a time, switched with the floating pill nav (`.view.active`).
- From 1000px wide: the pill nav hides and every view shows at once as a two-column dashboard.
  Round action buttons then scroll to the matching section instead of switching views.
- The layout has been checked for horizontal overflow at 320, 390, 768 and 1280px wide.

## Notes and limits

- The QR pass uses `qrcodejs` and the scanner uses `jsQR`, both loaded from the jsDelivr CDN with pinned versions.
  Open the validator once online so its service worker can cache the scanner for offline use.
- The rider chart is built from the latest 30 wallet entries returned by `GET /wallet`, so very busy
  accounts may show a partial week.
- The camera needs HTTPS or `localhost`.
- Absolute paths such as `/login/` assume the app is served from the site root.
- Sessions are kept in `localStorage` and there is no login throttling yet (see `docs/DEPLOY.md`).
'@
$script:count++

# ---------------------------------------------------------------------------
# web/shared/api.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/shared/api.js' @'
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
'@
$script:count++

# ---------------------------------------------------------------------------
# web/shared/site.css
# ---------------------------------------------------------------------------
Write-BundleFile 'web/shared/site.css' @'
/* Landing page and sign-in page styles (the app screens use theme.css only). */
.brand { display: inline-flex; align-items: center; gap: 10px; font-weight: 600; font-size: 1.15rem; letter-spacing: -.02em; text-decoration: none; color: #fff; }
.brand .mark { color: var(--lime); display: grid; }

/* ---------- landing ---------- */
.lp { position: relative; z-index: 1; overflow-x: clip; }
.lp-nav { display: flex; align-items: center; justify-content: space-between; gap: 16px; max-width: 1180px; margin: 0 auto; padding: 18px 20px; }
.lp-links { display: none; gap: 30px; }
.lp-links a { text-decoration: none; color: var(--muted); font-size: 1rem; }
.lp-links a:hover { color: #fff; }
.lp-actions { display: flex; gap: 10px; align-items: center; }
.lp-actions .btn-lime { display: none; }

.hero { position: relative; max-width: 1180px; margin: 0 auto; padding: 30px 20px 48px; display: grid; gap: 44px; }
.hero h1 { font-size: clamp(3rem, 11vw, 5.8rem); font-weight: 300; letter-spacing: -.05em; line-height: 1; }
.hero h1 b { font-weight: 600; color: var(--lime); }
.hero .lead { margin-top: 22px; max-width: 32ch; font-size: clamp(1.1rem, 3.6vw, 1.3rem); color: var(--muted); }
.hero .ctas { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 30px; }
.hero .bg-star { position: absolute; right: -60px; top: -20px; width: 380px; color: rgba(255, 255, 255, .05); pointer-events: none; }

.device-wrap { position: relative; display: grid; place-items: center; }
.device {
  position: relative; width: min(340px, 100%); padding: 18px 16px 18px; border-radius: 46px; border: 1px solid rgba(255, 255, 255, .22);
  background: linear-gradient(180deg, #5b7657 0%, #4a6247 100%); box-shadow: 0 30px 80px rgba(0, 0, 0, .45);
}
.device .notch { width: 96px; height: 26px; margin: 0 auto 14px; border-radius: 999px; background: #0c0f0e; }
.device .dev-top { display: flex; justify-content: space-between; margin-bottom: 14px; }
.device .display { font-size: 3.3rem; }
.device .dev-actions { display: flex; gap: 8px; margin: 14px 0; }
.device .dev-actions .icon-btn.lg { width: 50px; height: 50px; border-radius: 18px; }
.device .dev-actions .btn { flex: 1; height: 50px; font-size: 1.5rem; }
.device .card-lime { padding: 16px; border-radius: 26px; }
.device .bars { height: 130px; padding-top: 30px; }
.device .dev-nav { display: flex; justify-content: center; gap: 6px; margin-top: 14px; }
.device .dev-nav span { width: 38px; height: 38px; border-radius: 50%; display: grid; place-items: center; background: rgba(255, 255, 255, .14); }
.device .dev-nav span.on { background: #000; }
.badge-preview { position: absolute; left: 50%; bottom: -14px; transform: translateX(-50%); }

.section { max-width: 1180px; margin: 0 auto; padding: 56px 20px; }
.section > h2 { font-size: clamp(2.1rem, 6.4vw, 3.4rem); font-weight: 300; letter-spacing: -.04em; line-height: 1.05; max-width: 18ch; }
.section > .sub { margin-top: 14px; color: var(--muted); font-size: 1.1rem; max-width: 46ch; }
.steps, .who { display: grid; gap: 14px; margin-top: 30px; }
.step { padding: 24px; border-radius: var(--r-xl); background: var(--glass); border: 1px solid var(--line); }
.step .n { font-size: 3.4rem; font-weight: 300; letter-spacing: -.05em; line-height: 1; color: var(--lime); }
.step h3 { margin-top: 18px; font-size: 1.4rem; font-weight: 500; letter-spacing: -.02em; }
.step p { margin-top: 8px; color: var(--muted); }
.who .card { min-height: 220px; display: flex; flex-direction: column; justify-content: space-between; gap: 22px; }
.who h3 { font-size: 1.6rem; font-weight: 500; letter-spacing: -.03em; }
.who p { margin-top: 8px; opacity: .8; }
.band { margin-top: 30px; padding: 28px; border-radius: var(--r-xl); background: var(--glass); border: 1px solid var(--line); display: grid; gap: 26px; }
.band h2 { font-size: clamp(1.8rem, 5vw, 2.6rem); font-weight: 300; letter-spacing: -.035em; line-height: 1.08; }
.facts { display: grid; gap: 14px; }
.fact { display: grid; grid-template-columns: auto 1fr; gap: 14px; align-items: center; }
.fact .icon-btn { background: var(--ink); color: var(--lime); }
.cta { text-align: center; padding: clamp(32px, 7vw, 64px) 22px; border-radius: 36px; background: var(--lime); color: var(--ink); }
.cta h2 { font-size: clamp(2.2rem, 7vw, 3.8rem); font-weight: 300; letter-spacing: -.045em; line-height: 1.05; margin: 0 auto; max-width: 16ch; }
.cta .btn { margin-top: 26px; }
.foot { max-width: 1180px; margin: 0 auto; padding: 34px 20px 48px; display: flex; flex-wrap: wrap; justify-content: space-between; gap: 10px; color: var(--muted); font-size: .9rem; }

@media (min-width: 700px) {
  .steps, .who { grid-template-columns: repeat(3, 1fr); }
  .lp-actions .btn-lime { display: inline-flex; }
  .facts { grid-template-columns: repeat(3, 1fr); }
}
@media (min-width: 900px) {
  .hero { grid-template-columns: 1.15fr .85fr; align-items: center; padding-top: 64px; padding-bottom: 80px; }
  .lp-links { display: flex; }
  .band { grid-template-columns: .9fr 1.1fr; align-items: center; padding: 40px; }
  .facts { grid-template-columns: 1fr; }
}

/* ---------- sign in ---------- */
.auth { position: relative; z-index: 1; min-height: 100vh; display: grid; }
.auth-side { display: none; }
.auth-main { display: flex; flex-direction: column; justify-content: center; gap: 26px; width: 100%; max-width: 480px; margin: 0 auto; padding: 22px 18px 40px; }
.auth-card { padding: 28px 24px; border-radius: 34px; }
.auth-card h1 { font-size: 2.1rem; font-weight: 500; letter-spacing: -.035em; line-height: 1.1; }
.auth-card .intro { margin: 8px 0 24px; }
.auth-card .switch { margin-top: 20px; text-align: center; font-size: .96rem; }
.auth-card .switch a { color: var(--black); font-weight: 600; text-underline-offset: 3px; }
.auth-top { display: flex; justify-content: space-between; align-items: center; }
@media (min-width: 900px) {
  .auth { grid-template-columns: 1.1fr .9fr; }
  .auth-side { display: flex; flex-direction: column; justify-content: space-between; padding: 44px 56px; position: relative; overflow: hidden; }
  .auth-side h2 { font-size: clamp(3rem, 5vw, 4.6rem); font-weight: 300; letter-spacing: -.05em; line-height: 1.02; max-width: 12ch; }
  .auth-side h2 b { font-weight: 600; color: var(--lime); }
  .auth-side .bg-star { position: absolute; right: 56px; bottom: -150px; width: 420px; color: rgba(255, 255, 255, .06); }
  .auth-main { padding: 44px; max-width: 560px; }
  .auth-top .brand { display: none; }
}
'@
$script:count++

# ---------------------------------------------------------------------------
# web/shared/theme.css
# ---------------------------------------------------------------------------
Write-BundleFile 'web/shared/theme.css' @'
/* Transit Link UI theme.
   Palette, type and shapes follow the supplied design reference:
   lime #DCFFAD, white #FFFFFF, sage #7B9575, ink #1C2120, SF Pro Display, hatched fills, pill nav. */
:root {
  --lime: #dcffad;
  --white: #ffffff;
  --sage: #7b9575;
  --ink: #1c2120;
  --black: #000000;
  --forest: #2b3d2a;
  --moss: #4a6247;
  --text: #ffffff;
  --muted: rgba(255, 255, 255, 0.78);
  --line: rgba(255, 255, 255, 0.2);
  --glass: rgba(255, 255, 255, 0.13);
  --glass-strong: rgba(255, 255, 255, 0.24);
  --go: #7dbb3e;
  --stop: #e4572e;
  --font: "SF Pro Display", "SF Pro Text", -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --r-xl: 30px;
  --r-lg: 24px;
  --r-md: 16px;
}
* { box-sizing: border-box; }
html { background: var(--ink); min-height: 100%; -webkit-text-size-adjust: 100%; }
body {
  margin: 0; min-height: 100vh; color: var(--text); font-family: var(--font); font-size: 16px; line-height: 1.5;
  background:
    radial-gradient(130% 55% at 50% 108%, rgba(123, 149, 117, 0.95), rgba(123, 149, 117, 0) 70%),
    linear-gradient(180deg, var(--ink) 0%, var(--forest) 42%, var(--moss) 100%);
  background-repeat: no-repeat;
}
/* faint stars, like the reference backdrop */
body::before {
  content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 0; opacity: .65;
  background-image:
    radial-gradient(1.4px 1.4px at 8% 14%, rgba(255,255,255,.55), transparent),
    radial-gradient(1px 1px at 22% 62%, rgba(255,255,255,.4), transparent),
    radial-gradient(1.6px 1.6px at 36% 9%, rgba(255,255,255,.5), transparent),
    radial-gradient(1px 1px at 51% 33%, rgba(255,255,255,.35), transparent),
    radial-gradient(1.4px 1.4px at 66% 78%, rgba(255,255,255,.4), transparent),
    radial-gradient(1px 1px at 81% 21%, rgba(255,255,255,.5), transparent),
    radial-gradient(1.6px 1.6px at 93% 55%, rgba(255,255,255,.35), transparent),
    radial-gradient(1px 1px at 14% 88%, rgba(255,255,255,.3), transparent),
    radial-gradient(1.2px 1.2px at 72% 6%, rgba(255,255,255,.45), transparent);
}
h1, h2, h3, p { margin: 0; }
a { color: inherit; }
button, input, select { font: inherit; }
:focus-visible { outline: 3px solid var(--lime); outline-offset: 3px; }
.card-white :focus-visible, .card-lime :focus-visible { outline-color: var(--ink); }
.hidden { display: none !important; }
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
svg { display: block; }

/* ---------- layout ---------- */
.page { position: relative; z-index: 1; max-width: 560px; margin: 0 auto; padding: 14px 18px 132px; }
.appbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 6px 0 20px; }
.appbar .mid { display: none; }
.stack > * + * { margin-top: 14px; }
.stack-lg > * + * { margin-top: 22px; }
.row { display: flex; align-items: center; gap: 12px; }
.row.wrap { flex-wrap: wrap; }
.spread { justify-content: space-between; }
.grow { flex: 1 1 0; min-width: 0; }

/* ---------- type ---------- */
.label { color: var(--muted); font-size: 1.08rem; font-weight: 400; letter-spacing: -.01em; }
.display { font-weight: 300; letter-spacing: -.04em; line-height: 1; font-variant-numeric: tabular-nums; }
.display.xl { font-size: clamp(3.4rem, 15vw, 5.6rem); }
.display.lg { font-size: clamp(2.6rem, 11vw, 3.6rem); }
.display.md { font-size: 2.4rem; }
.display small { font-size: .38em; font-weight: 400; letter-spacing: 0; margin-right: .3em; opacity: .75; }
.muted { color: var(--muted); }
.small { font-size: .88rem; }
.tnum { font-variant-numeric: tabular-nums; }
.card-white .muted, .card-lime .muted { color: rgba(28, 33, 32, .66); }

/* ---------- buttons ---------- */
.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 10px; height: 52px; padding: 0 26px;
  border: 0; border-radius: 999px; font-weight: 600; font-size: 1rem; letter-spacing: -.01em; cursor: pointer;
  text-decoration: none; transition: transform .15s ease, filter .15s ease; white-space: nowrap;
}
.btn:hover { filter: brightness(1.04); }
.btn:active { transform: scale(.98); }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn-white { background: var(--white); color: var(--black); }
.btn-lime { background: var(--lime); color: var(--ink); }
.btn-black { background: var(--black); color: var(--white); }
.btn-ghost { background: var(--glass); color: var(--white); border: 1px solid var(--line); }
.btn-block { width: 100%; }
.btn-sm { height: 44px; padding: 0 20px; font-size: .95rem; }
.icon-btn {
  display: inline-grid; place-items: center; width: 50px; height: 50px; flex: none; border: 0; border-radius: 50%;
  background: var(--glass); color: var(--white); cursor: pointer; text-decoration: none; transition: background .15s;
}
.icon-btn:hover { background: var(--glass-strong); }
.icon-btn.dark { background: var(--ink); }
.icon-btn.sm { width: 42px; height: 42px; }
.icon-btn.lg { width: 58px; height: 58px; border-radius: 22px; }

/* ---------- cards ---------- */
.card { border-radius: var(--r-xl); padding: 22px; }
.card-white { background: var(--white); color: var(--black); }
.card-lime { background: var(--lime); color: var(--ink); }
.card-glass { background: var(--glass); border: 1px solid var(--line); }
.card-dark { background: var(--ink); color: var(--white); }
.card-stop { background: var(--stop); color: #fff; }

/* ---------- forms ---------- */
.field label { display: block; margin: 0 0 8px 4px; font-size: .9rem; color: var(--muted); }
.card-white .field label, .card-lime .field label { color: rgba(28, 33, 32, .7); }
.input {
  width: 100%; height: 56px; padding: 0 18px; color: var(--white); background: var(--glass);
  border: 1px solid var(--line); border-radius: var(--r-md); outline: none; font-size: 1.02rem;
}
.input::placeholder { color: rgba(255, 255, 255, .5); }
.input:focus { border-color: var(--lime); }
.card-white .input, .card-lime .input { color: var(--black); background: #f1f4ee; border-color: #dde4d6; }
.card-white .input::placeholder { color: rgba(28, 33, 32, .45); }
.card-white .input:focus { border-color: var(--ink); }
textarea.input { height: auto; min-height: 96px; padding: 14px 18px; resize: vertical; font-family: ui-monospace, Menlo, Consolas, monospace; font-size: .8rem; }
.input-wrap { position: relative; }
.input-wrap .input { padding-right: 58px; }
.input-wrap .reveal { position: absolute; right: 6px; top: 6px; width: 44px; height: 44px; border: 0; border-radius: 50%; background: transparent; color: inherit; cursor: pointer; display: grid; place-items: center; opacity: .7; }

.note { padding: 12px 16px; border-radius: var(--r-md); font-size: .94rem; background: var(--glass); border: 1px solid var(--line); }
.card-white .note, .card-lime .note { background: #f1f4ee; border-color: #dde4d6; color: var(--ink); }
.note.err { border-color: var(--stop); color: #ffd9cd; }
.card-white .note.err, .card-lime .note.err { color: #a8340f; background: #fff0ea; }
.note.ok { border-color: var(--go); }
.card-white .note.ok { color: #2b5a12; background: #eef9e0; }

/* ---------- chips, pills ---------- */
.chips { display: flex; gap: 8px; flex-wrap: wrap; }
.chip {
  height: 40px; padding: 0 18px; border: 0; border-radius: 999px; background: rgba(255, 255, 255, .78); color: var(--ink);
  font-weight: 500; font-size: .95rem; cursor: pointer;
}
.chip[aria-pressed="true"] { background: var(--ink); color: #fff; }
.card-white .chip { background: #eef2ea; }
.card-white .chip[aria-pressed="true"] { background: var(--ink); color: #fff; }
.delta { display: inline-flex; align-items: center; height: 30px; padding: 0 12px; border-radius: 999px; background: var(--glass); border: 1px solid var(--line); font-size: .9rem; white-space: nowrap; }
.pill { display: inline-flex; align-items: center; gap: 6px; height: 30px; padding: 0 12px; border-radius: 999px; font-size: .84rem; font-weight: 600; background: var(--glass); border: 1px solid var(--line); white-space: nowrap; }
.pill::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--lime); }
.pill.off::before { background: var(--stop); }
.tag { display: inline-block; margin: 0 6px 6px 0; padding: 3px 12px; border-radius: 999px; font-size: .82rem; font-weight: 500; background: var(--ink); color: var(--lime); }

/* ---------- floating pill nav (mobile) ---------- */
.pillnav {
  position: fixed; left: 50%; bottom: calc(14px + env(safe-area-inset-bottom)); transform: translateX(-50%); z-index: 30;
  display: flex; gap: 8px; padding: 8px; border-radius: 999px; background: rgba(28, 33, 32, .55);
  -webkit-backdrop-filter: blur(16px); backdrop-filter: blur(16px); border: 1px solid var(--line);
}
.pillnav button { width: 54px; height: 54px; border: 0; border-radius: 50%; background: rgba(255, 255, 255, .12); color: #fff; cursor: pointer; display: grid; place-items: center; transition: background .15s; }
.pillnav button[aria-current="page"] { background: var(--black); }

/* ---------- hatched fills ---------- */
.hatch { background-image: repeating-linear-gradient(135deg, currentColor 0 1px, transparent 1px 7px); }
.meter { position: relative; height: 56px; border-radius: 20px; overflow: hidden; color: #b4bdb0; background-image: repeating-linear-gradient(135deg, currentColor 0 1px, transparent 1px 7px); }
.meter > i { position: absolute; inset: 0 auto 0 0; width: 0; background: var(--black); border-radius: 20px; transition: width 1s linear; }
.meter.thin { height: 14px; border-radius: 8px; }
.meter.thin > i { border-radius: 8px; }
.meter.on-dark { color: rgba(255,255,255,.35); }
.meter.on-dark > i { background: var(--lime); }

/* ---------- bar charts (hatched bars, one solid highlight, white tooltip) ---------- */
.bars { display: flex; align-items: stretch; gap: clamp(6px, 2.2vw, 16px); height: 200px; padding-top: 34px; }
.bars.compact { gap: 3px; height: 180px; }
.bar { flex: 1 1 0; min-width: 0; display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 0; border: 0; background: none; color: inherit; cursor: pointer; font-size: .72rem; }
.bar-track { position: relative; flex: 1; width: 100%; display: flex; align-items: flex-end; }
.bar-fill { width: 100%; min-height: 6px; border-radius: 12px; color: rgba(28, 33, 32, .55); background-image: repeating-linear-gradient(135deg, currentColor 0 1px, transparent 1px 6px); transition: height .4s ease; }
.bars.compact .bar-fill { border-radius: 6px; }
.bar.on .bar-fill { background: var(--ink); background-image: none; }
.bar-label { height: 1em; line-height: 1; opacity: .75; white-space: nowrap; }
.bar.on .bar-label { opacity: 1; font-weight: 700; }
.tip { position: absolute; left: 50%; transform: translateX(-50%); padding: 7px 14px; border-radius: 999px; background: var(--white); color: var(--black); font-weight: 600; font-size: .82rem; white-space: nowrap; box-shadow: 0 4px 14px rgba(0, 0, 0, .18); pointer-events: none; }
.tip.first { left: 0; transform: none; }
.tip.last { left: auto; right: 0; transform: none; }
.card-white .bar-fill { color: rgba(28, 33, 32, .35); }

/* ---------- transaction rows (Expenses History style) ---------- */
.txns { list-style: none; margin: 0; padding: 0; }
.txn { display: grid; grid-template-columns: 1fr auto; gap: 4px 12px; padding: 18px 0; border-top: 1px solid var(--line); }
.txn:first-child { border-top: 0; padding-top: 6px; }
.txn .amt { font-size: clamp(2.2rem, 9vw, 3rem); font-weight: 300; letter-spacing: -.035em; line-height: 1.05; font-variant-numeric: tabular-nums; }
.txn .amt small { font-size: .4em; font-weight: 400; margin-right: .3em; opacity: .75; letter-spacing: 0; }
.txn .what { display: flex; align-items: center; gap: 10px; font-size: 1.08rem; min-width: 0; }
.txn .what span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dot { width: 14px; height: 14px; border-radius: 50%; flex: none; background: var(--black); border: 1px solid var(--line); }
.dot.in { background: var(--lime); border-color: var(--lime); }
.txn .side { display: flex; flex-direction: column; align-items: flex-end; justify-content: space-between; gap: 6px; }
.txn .when { font-size: 1.02rem; color: var(--muted); text-align: right; }
.empty { padding: 26px 8px; text-align: center; color: var(--muted); }

/* ---------- tiles ---------- */
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
.tile { position: relative; min-height: 132px; padding: 16px; border-radius: 26px; display: flex; flex-direction: column; justify-content: space-between; }
.tile .icon-btn { position: absolute; top: 14px; right: 14px; }
.tile .k { font-size: 1.02rem; padding-right: 54px; }
.tile .v { font-size: 2.2rem; font-weight: 300; letter-spacing: -.035em; font-variant-numeric: tabular-nums; line-height: 1; }
.tile.glass { background: var(--glass); border: 1px solid var(--line); }
.tile.lime { background: var(--lime); color: var(--ink); }
.tile.white { background: var(--white); color: var(--black); }

/* ---------- menu sheet ---------- */
.sheet-back { position: fixed; inset: 0; z-index: 50; background: rgba(0, 0, 0, .5); display: flex; align-items: flex-end; justify-content: center; }
.sheet { width: min(480px, 100%); padding: 22px 22px calc(22px + env(safe-area-inset-bottom)); border-radius: 30px 30px 0 0; background: var(--white); color: var(--black); }
@media (min-width: 700px) { .sheet-back { align-items: flex-start; justify-content: flex-start; } .sheet { margin: 78px 0 0 max(24px, calc((100vw - 1180px) / 2)); border-radius: 26px; width: 340px; } }

/* ---------- validator lamp ---------- */
.lamp { border-radius: var(--r-xl); padding: 26px 22px; text-align: center; background: var(--glass); border: 1px solid var(--line); transition: background .2s; }
.lamp h1 { font-size: clamp(1.7rem, 7vw, 2.3rem); font-weight: 500; letter-spacing: -.03em; }
.lamp.go { background: var(--lime); color: var(--ink); border-color: var(--lime); }
.lamp.warn { background: var(--white); color: var(--black); border-color: var(--white); }
.lamp.stop { background: var(--stop); color: #fff; border-color: var(--stop); }
.lamp.go .muted, .lamp.warn .muted { color: rgba(28, 33, 32, .7); }
.lamp.stop .muted { color: rgba(255, 255, 255, .9); }
.viewfinder { position: relative; border-radius: var(--r-xl); overflow: hidden; background: #000; aspect-ratio: 4 / 3; }
.viewfinder video { width: 100%; height: 100%; object-fit: cover; }
.viewfinder::after { content: ""; position: absolute; inset: 14%; border: 2px solid rgba(220, 255, 173, .85); border-radius: 22px; pointer-events: none; }

/* ---------- list rows (stations, payouts) ---------- */
.rows { list-style: none; margin: 0; padding: 0; }
.rows li { display: grid; grid-template-columns: 1fr auto; gap: 4px 14px; padding: 14px 0; border-top: 1px solid var(--line); }
.rows li:first-child { border-top: 0; }
.card-white .rows li { border-color: #e6ebe1; }
.rows .big { font-size: 1.6rem; font-weight: 300; letter-spacing: -.03em; font-variant-numeric: tabular-nums; text-align: right; }
.rows .meter { grid-column: 1 / -1; }

/* ---------- views: one at a time on phones, all at once on desktop ---------- */
.view:not(.active) { display: none; }
.only-desktop { display: none !important; }
@media (min-width: 1000px) {
  .page.wide { max-width: 1180px; padding-bottom: 56px; }
  .pillnav { display: none; }
  .view:not(.active) { display: block; }
  .only-mobile { display: none !important; }
  .only-desktop { display: initial !important; }
  .appbar .mid { display: flex; }
}
@media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }

/* grid placement for transaction rows */
.txn .amt { grid-column: 1; grid-row: 1; }
.txn .what { grid-column: 1; grid-row: 2; }
.txn .side { grid-column: 2; grid-row: 1 / span 2; }
'@
$script:count++

# ---------------------------------------------------------------------------
# web/shared/ui.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/shared/ui.js' @'
/* Icons, the brand star and a small hatched bar chart. Plain script, no dependencies. */
var ICONS = {
  home: '<path d="M4 11.5 12 4l8 7.5"/><path d="M6.5 10v9h11v-9"/>',
  qr: '<rect x="4" y="4" width="6" height="6" rx="1.2"/><rect x="14" y="4" width="6" height="6" rx="1.2"/><rect x="4" y="14" width="6" height="6" rx="1.2"/><path d="M14 14h2.5v2.5H14zM19 14h1M14 19.5h1M17.5 18h2.5v2"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  receipt: '<path d="M6 3.5h12V21l-3-2-3 2-3-2-3 2z"/><path d="M9 8.5h6M9 12.5h6"/>',
  dots: '<circle cx="8" cy="8" r="1.5" fill="currentColor" stroke="none"/><circle cx="16" cy="8" r="1.5" fill="currentColor" stroke="none"/><circle cx="8" cy="16" r="1.5" fill="currentColor" stroke="none"/><circle cx="16" cy="16" r="1.5" fill="currentColor" stroke="none"/>',
  logout: '<path d="M10 4H6.5A2.5 2.5 0 0 0 4 6.5v11A2.5 2.5 0 0 0 6.5 20H10"/><path d="m15 8 4 4-4 4M19 12H9"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 5v6h-6"/>',
  up: '<path d="M7 17 17 7M8.5 7H17v8.5"/>',
  share: '<path d="M12 15V4M8 8l4-4 4 4"/><path d="M5 13v6h14v-6"/>',
  shield: '<path d="M12 3 5 6v5.5c0 4.3 3 7.8 7 9.5 4-1.7 7-5.2 7-9.5V6z"/><path d="m9.5 12 2 2 3.5-4"/>',
  cash: '<rect x="3" y="6.5" width="18" height="11" rx="2.5"/><circle cx="12" cy="12" r="2.6"/><path d="M6.5 9.5v.01M17.5 14.5v.01"/>',
  chart: '<path d="M5 20v-8M12 20V4M19 20v-5"/>',
  grid: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/>',
  alert: '<path d="M12 4 3.5 19.5h17z"/><path d="M12 10v4.5M12 17v.01"/>',
  user: '<circle cx="12" cy="8" r="3.6"/><path d="M5 20c1-4 4-6 7-6s6 2 7 6"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  scan: '<path d="M4 8V6.5A2.5 2.5 0 0 1 6.5 4H8M16 4h1.5A2.5 2.5 0 0 1 20 6.5V8M20 16v1.5a2.5 2.5 0 0 1-2.5 2.5H16M8 20H6.5A2.5 2.5 0 0 1 4 17.5V16"/><path d="M4 12h16"/>',
  train: '<rect x="5" y="3.5" width="14" height="13" rx="3.5"/><path d="M5 11h14M8.5 20.5l2-4M15.5 20.5l-2-4"/><path d="M9 14v.01M15 14v.01"/>',
  wifi: '<path d="M3 9.5a14 14 0 0 1 18 0M6 13a9.5 9.5 0 0 1 12 0M9.2 16.4a5 5 0 0 1 5.6 0"/><path d="M12 19.5v.01"/>',
  arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
};

function icon(name, size) {
  size = size || 22;
  return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICONS[name] || '') + '</svg>';
}

/* The seven-point star from the brand reference. */
function star(size, color) {
  return '<svg viewBox="0 0 100 100" width="' + size + '" height="' + size + '" aria-hidden="true"><polygon fill="' + (color || 'currentColor') + '" points="50,3 60.8,27.5 86.7,20.7 74.4,44.4 95.8,60.5 69.5,65.6 70.4,92.3 50,75 29.6,92.3 30.5,65.6 4.2,60.5 25.6,44.4 13.3,20.7 39.2,27.5"/></svg>';
}

/* Fill every <span data-icon="name"> or <span data-star> on the page. */
function mountIcons(root) {
  (root || document).querySelectorAll('[data-icon]').forEach(function (el) {
    el.innerHTML = icon(el.getAttribute('data-icon'), parseInt(el.getAttribute('data-size') || '22', 10));
  });
  (root || document).querySelectorAll('[data-star]').forEach(function (el) {
    el.innerHTML = star(parseInt(el.getAttribute('data-star') || '28', 10));
  });
}

/* Hatched bar chart. o = { labels, values, selected, highlight, fmt, onSelect, compact, labelEvery }
   One bar can be selected (solid, with a white tooltip); `highlight` solidifies several bars. */
function barChart(el, o) {
  var max = Math.max.apply(null, [1].concat(o.values));
  var fmt = o.fmt || function (v) { return String(v); };
  var every = o.labelEvery || 1;
  el.className = 'bars' + (o.compact ? ' compact' : '');
  el.innerHTML = '';
  o.values.forEach(function (v, i) {
    var on = i === o.selected || (o.highlight && o.highlight.indexOf(i) !== -1);
    var pct = Math.round((v / max) * 100);
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'bar' + (on ? ' on' : '');
    b.setAttribute('aria-label', o.labels[i] + ': ' + fmt(v));
    var track = document.createElement('div');
    track.className = 'bar-track';
    var fill = document.createElement('div');
    fill.className = 'bar-fill';
    fill.style.height = pct + '%';
    track.appendChild(fill);
    if (i === o.selected) {
      var tip = document.createElement('span');
      tip.className = 'tip' + (i === 0 ? ' first' : (i === o.values.length - 1 ? ' last' : ''));
      tip.style.bottom = 'calc(' + pct + '% + 8px)';
      tip.textContent = fmt(v);
      track.appendChild(tip);
    }
    var label = document.createElement('div');
    label.className = 'bar-label';
    label.textContent = i % every === 0 ? o.labels[i] : '';
    b.append(track, label);
    if (o.onSelect) b.onclick = function () { o.onSelect(i); };
    el.appendChild(b);
  });
}
'@
$script:count++

# ---------------------------------------------------------------------------
# web/index.html
# ---------------------------------------------------------------------------
Write-BundleFile 'web/index.html' @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Transit Link · One account for every ride</title>
  <meta name="description" content="Top up with M-Pesa, show a QR pass and ride rail and matatus on a single balance.">
  <meta name="theme-color" content="#1c2120">
  <link rel="stylesheet" href="shared/theme.css">
  <link rel="stylesheet" href="shared/site.css">
</head>
<body>
  <div class="lp">
    <header class="lp-nav">
      <a class="brand" href="/"><span class="mark" data-star="30"></span>Transit Link</a>
      <nav class="lp-links" aria-label="Sections">
        <a href="#how">How it works</a>
        <a href="#who">Who it's for</a>
        <a href="#offline">Offline-ready</a>
      </nav>
      <div class="lp-actions">
        <a id="nav-signin" class="btn btn-white btn-sm" href="/login/">Sign in</a>
        <a id="nav-start" class="btn btn-lime btn-sm" href="/login/?mode=signup">Get started</a>
      </div>
    </header>

    <main>
      <section class="hero">
        <span class="bg-star" data-star="380"></span>
        <div>
          <h1>One account for <b>every ride.</b></h1>
          <p class="lead">Top up with M-Pesa, show a QR code, and travel on rail and matatus with a single balance. It keeps working when the network doesn't.</p>
          <div class="ctas">
            <a id="hero-start" class="btn btn-lime" href="/login/?mode=signup">Get started <span data-icon="arrow" data-size="20"></span></a>
            <a class="btn btn-ghost" href="#how">See how it works</a>
          </div>
        </div>

        <div class="device-wrap" aria-hidden="true">
          <div class="device">
            <div class="notch"></div>
            <div class="dev-top"><span class="icon-btn sm" data-icon="dots" data-size="20"></span><span class="icon-btn sm" data-icon="qr" data-size="20"></span></div>
            <div class="label">Wallet (KES)</div>
            <div class="row" style="margin-top:6px;align-items:flex-end;gap:12px"><div class="display">360</div><span class="delta" style="margin-bottom:6px">+8.5% this week</span></div>
            <div class="dev-actions">
              <span class="icon-btn lg" data-icon="qr" data-size="22"></span>
              <span class="icon-btn lg" data-icon="receipt" data-size="22"></span>
              <span class="btn btn-white">+</span>
            </div>
            <div class="card card-lime">
              <div class="chips"><span class="chip" aria-pressed="true">Spent</span><span class="chip" aria-pressed="false">Added</span></div>
              <div class="small" style="margin-top:12px;opacity:.7">This week</div>
              <div class="display md" style="margin-top:4px">KES 150</div>
              <div id="mock-chart"></div>
            </div>
            <div class="dev-nav"><span data-icon="home" data-size="18"></span><span class="on" data-icon="qr" data-size="18"></span><span data-icon="plus" data-size="18"></span><span data-icon="receipt" data-size="18"></span></div>
          </div>
        </div>
      </section>

      <section id="how" class="section">
        <h2>Pay once. Ride everywhere.</h2>
        <p class="sub">Three steps, no cash, no separate card for every operator.</p>
        <div class="steps">
          <article class="step"><div class="n">01</div><h3>Top up with M-Pesa</h3><p>Send money to your Transit Link balance from your phone. It shows up in seconds.</p></article>
          <article class="step"><div class="n">02</div><h3>Show your pass</h3><p>Your QR code refreshes every minute, so a screenshot is no use to anyone else.</p></article>
          <article class="step"><div class="n">03</div><h3>Ride on</h3><p>The gate scans you in. Your fare is taken once, and your history stays in the app.</p></article>
        </div>
      </section>

      <section id="who" class="section">
        <h2>Built for the whole route.</h2>
        <div class="who">
          <article class="card card-white"><span class="icon-btn dark" data-icon="user"></span><div><h3>Riders</h3><p>One balance, one pass, a clear record of every trip.</p></div></article>
          <article class="card card-lime"><span class="icon-btn dark" data-icon="chart"></span><div><h3>Operators</h3><p>Live revenue, busy hours and suspicious trips in one dashboard.</p></div></article>
          <article class="card card-dark"><span class="icon-btn" data-icon="scan"></span><div><h3>Gate teams</h3><p>Fast scanning that carries on even when the connection drops.</p></div></article>
        </div>
      </section>

      <section id="offline" class="section">
        <div class="band">
          <h2>Works when the network doesn't.</h2>
          <div class="facts">
            <div class="fact"><span class="icon-btn" data-icon="wifi"></span><div><strong>Offline scanning</strong><div class="muted small">Taps are saved on the device and sent when it reconnects.</div></div></div>
            <div class="fact"><span class="icon-btn" data-icon="shield"></span><div><strong>Charged once</strong><div class="muted small">The same tap, sent twice, never costs you twice.</div></div></div>
            <div class="fact"><span class="icon-btn" data-icon="clock"></span><div><strong>Fresh passes</strong><div class="muted small">Codes expire within minutes to keep your account safe.</div></div></div>
          </div>
        </div>
      </section>

      <section class="section" style="padding-top:20px">
        <div class="cta">
          <h2>Ready for your next ride?</h2>
          <a id="cta-start" class="btn btn-black" href="/login/?mode=signup">Create your account <span data-icon="arrow" data-size="20"></span></a>
        </div>
      </section>
    </main>

    <footer class="foot"><span>Transit Link · MVP showcase</span><span>Demo data only. No real money moves.</span></footer>
  </div>

  <script src="shared/api.js"></script>
  <script src="shared/ui.js"></script>
  <script>
    mountIcons();
    barChart(document.getElementById('mock-chart'), {
      labels: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
      values: [50, 100, 0, 100, 50, 0, 50],
      selected: 3, fmt: function (v) { return 'KES ' + v; }, compact: false,
    });
    // Signed-in visitors get a shortcut straight back to their own screen.
    var s = Session.get();
    if (s) {
      var home = Session.home(s.role);
      var a = document.getElementById('nav-signin');
      a.textContent = 'Open app'; a.href = home;
      ['nav-start', 'hero-start', 'cta-start'].forEach(function (id) {
        var el = document.getElementById(id);
        if (id === 'nav-start') { el.style.display = 'none'; return; }
        el.href = home;
        el.firstChild.textContent = id === 'cta-start' ? 'Open your app ' : 'Open your app ';
      });
    }
  </script>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/login/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/login/app.js' @'
/* One sign-in form for everyone. What you type decides where you land:
     a phone number + PIN        -> rider app
     a username + password       -> operator dashboard
     a device ID (no passcode)   -> validator
   The screen never says which kind of account exists, and failures use one generic message. */
mountIcons();

var existing = Session.get();
if (existing) go(Session.home(existing.role));

var mode = new URLSearchParams(location.search).get('mode') === 'signup' ? 'signup' : 'signin';
var PHONE_LIKE = /^\+?[\d\s-]{9,15}$/;
var GENERIC = "We couldn't find an account with those details. Check them and try again.";

function render() {
  var up = mode === 'signup';
  document.title = (up ? 'Create account' : 'Sign in') + ' · Transit Link';
  $('title').textContent = up ? 'Create your account' : 'Welcome back';
  $('intro').textContent = up ? 'Use your M-Pesa number to get started.' : 'Sign in to continue.';
  show($('f-name'), up);
  $('ident-label').textContent = up ? 'Phone number' : 'Account';
  $('ident').placeholder = up ? '07XX XXX XXX' : 'Phone number or ID';
  $('ident').setAttribute('inputmode', up ? 'tel' : 'text');
  $('secret-label').textContent = up ? 'Choose a PIN (4 to 8 digits)' : 'Passcode';
  $('secret').placeholder = up ? 'Digits only' : 'Enter your passcode';
  $('secret').autocomplete = up ? 'new-password' : 'current-password';
  $('submit').textContent = up ? 'Create account' : 'Sign in';
  $('switch-text').textContent = up ? 'Already have an account?' : 'New here?';
  $('switch').textContent = up ? 'Sign in' : 'Create an account';
  $('switch').href = up ? '?mode=signin' : '?mode=signup';
  say($('msg'), '');
}

$('switch').onclick = function (e) {
  e.preventDefault();
  mode = mode === 'signup' ? 'signin' : 'signup';
  history.replaceState(null, '', '?mode=' + mode);
  render();
};

$('reveal').onclick = function () {
  var input = $('secret');
  var hidden = input.type === 'password';
  input.type = hidden ? 'text' : 'password';
  $('reveal').setAttribute('aria-label', hidden ? 'Hide passcode' : 'Show passcode');
};

async function signIn(ident, secret) {
  if (PHONE_LIKE.test(ident)) {
    if (!secret) throw new Error('Enter your passcode.');
    var r = await api('/auth/login', { method: 'POST', body: { phone: ident, pin: secret } });
    return { role: 'rider', token: r.token, name: r.name };
  }
  if (secret) {
    try {
      var o = await api('/auth/operator/login', { method: 'POST', body: { username: ident, password: secret } });
      return { role: 'operator', token: o.token, name: o.name };
    } catch (e) { if (e.status !== 401) throw e; }
  }
  var cfg = await api('/validator/config', { headers: { 'X-Validator-Key': ident } });
  return { role: 'validator', key: ident, cfg: cfg, name: cfg.station };
}

$('form').onsubmit = async function (e) {
  e.preventDefault();
  var ident = $('ident').value.trim();
  var secret = $('secret').value;
  if (!ident) return say($('msg'), mode === 'signup' ? 'Enter your phone number.' : 'Enter your phone number or ID.', 'err');
  var btn = $('submit');
  btn.disabled = true;
  try {
    var session;
    if (mode === 'signup') {
      var name = $('name').value.trim();
      if (name.length < 2) throw new Error('Enter your full name.');
      var r = await api('/auth/register', { method: 'POST', body: { phone: ident, name: name, pin: secret } });
      session = { role: 'rider', token: r.token, name: r.name };
    } else {
      session = await signIn(ident, secret);
    }
    Session.set(session);
    go(Session.home(session.role));
  } catch (err) {
    say($('msg'), err.status === 401 ? GENERIC : err.message, 'err');
    btn.disabled = false;
  }
};

render();
'@
$script:count++

# ---------------------------------------------------------------------------
# web/login/index.html
# ---------------------------------------------------------------------------
Write-BundleFile 'web/login/index.html' @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Sign in · Transit Link</title>
  <meta name="theme-color" content="#1c2120">
  <link rel="stylesheet" href="../shared/theme.css">
  <link rel="stylesheet" href="../shared/site.css">
</head>
<body>
  <div class="auth">
    <aside class="auth-side">
      <a class="brand" href="/"><span class="mark" data-star="30"></span>Transit Link</a>
      <h2>Your route, <b>one account.</b></h2>
      <p class="muted">Pay with M-Pesa, ride with a code.</p>
      <span class="bg-star" data-star="460"></span>
    </aside>

    <main class="auth-main">
      <div class="auth-top">
        <a class="brand" href="/"><span class="mark" data-star="28"></span>Transit Link</a>
        <a class="btn btn-ghost btn-sm" href="/">Back</a>
      </div>

      <section class="card card-white auth-card" aria-labelledby="title">
        <h1 id="title">Welcome back</h1>
        <p class="muted intro" id="intro">Sign in to continue.</p>

        <form id="form" class="stack" novalidate>
          <div class="field hidden" id="f-name">
            <label for="name">Full name</label>
            <input class="input" id="name" autocomplete="name" placeholder="Your name">
          </div>
          <div class="field">
            <label for="ident" id="ident-label">Account</label>
            <input class="input" id="ident" autocomplete="username" autocapitalize="none" autocorrect="off" spellcheck="false" placeholder="Phone number or ID">
          </div>
          <div class="field">
            <label for="secret" id="secret-label">Passcode</label>
            <div class="input-wrap">
              <input class="input" id="secret" type="password" autocomplete="current-password" placeholder="Enter your passcode">
              <button class="reveal" id="reveal" type="button" aria-label="Show passcode"><span data-icon="eye" data-size="20"></span></button>
            </div>
          </div>
          <button class="btn btn-black btn-block" id="submit" type="submit">Sign in</button>
          <div id="msg" class="note hidden" role="alert"></div>
        </form>

        <p class="switch muted"><span id="switch-text">New here?</span> <a id="switch" href="?mode=signup">Create an account</a></p>
      </section>
    </main>
  </div>

  <script src="../shared/api.js"></script>
  <script src="../shared/ui.js"></script>
  <script src="app.js"></script>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/operator/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/operator/app.js' @'
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
'@
$script:count++

# ---------------------------------------------------------------------------
# web/operator/index.html
# ---------------------------------------------------------------------------
Write-BundleFile 'web/operator/index.html' @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Operator · Transit Link</title>
  <meta name="theme-color" content="#1c2120">
  <link rel="stylesheet" href="../shared/theme.css">
  <style>
    .ogrid { display: block; }
    .ogrid .col > * + * { margin-top: 18px; }
    .card h2 { font-size: 1.35rem; font-weight: 400; letter-spacing: -.02em; }
    .flag-meta { font-size: .95rem; color: var(--muted); }
    .greeting { font-size: 1.1rem; color: var(--muted); }
    @media (min-width: 1000px) {
      .ogrid { display: grid; grid-template-columns: minmax(0, 1.2fr) minmax(0, 1fr); gap: 28px; align-items: start; }
    }
  </style>
</head>
<body>
  <div class="page wide">
    <header class="appbar">
      <button class="icon-btn" id="menu-btn" type="button" aria-label="Open menu" aria-haspopup="true"><span data-icon="dots"></span></button>
      <div class="mid greeting" id="op-name"></div>
      <button class="icon-btn" id="refresh" type="button" aria-label="Refresh"><span data-icon="refresh"></span></button>
    </header>

    <div class="ogrid">
      <div class="col">
        <section class="view active" id="v-overview" aria-label="Overview">
          <div class="label">Revenue today (KES)</div>
          <div class="row wrap" style="align-items:flex-end;gap:12px;margin-top:8px">
            <div class="display xl" id="rev">0</div>
            <span class="delta" id="rev-delta" style="margin-bottom:8px"></span>
          </div>
          <div class="row" style="margin:22px 0 12px">
            <button class="icon-btn lg" type="button" data-go="demand" aria-label="See demand"><span data-icon="chart"></span></button>
            <button class="icon-btn lg" type="button" data-go="flags" aria-label="See suspicious trips"><span data-icon="alert"></span></button>
            <button class="btn btn-white grow payout-btn" type="button" style="height:58px"><span data-icon="cash" data-size="22"></span> Run payout</button>
          </div>
          <div id="payout-msg" class="note hidden" role="status" style="margin-bottom:14px"></div>

          <div class="card card-lime">
            <div class="row spread">
              <div class="chips" role="group" aria-label="Chart type">
                <button class="chip" type="button" data-tab="revenue" aria-pressed="true">Revenue</button>
                <button class="chip" type="button" data-tab="trips" aria-pressed="false">Trips</button>
              </div>
              <span class="small muted">Last 7 days</span>
            </div>
            <div class="small muted" style="margin-top:18px">Total</div>
            <div class="display lg" id="chart-total" style="margin-top:4px">0</div>
            <div id="chart"></div>
          </div>

          <div class="tiles" style="margin-top:14px">
            <div class="tile glass"><span class="icon-btn dark sm" data-icon="cash" data-size="20"></span><div class="k">Unpaid to operator</div><div class="v" id="t-unpaid">0</div></div>
            <div class="tile lime"><span class="icon-btn dark sm" data-icon="user" data-size="20"></span><div class="k">Riders today</div><div class="v" id="t-riders">0</div></div>
            <div class="tile white"><span class="icon-btn dark sm" data-icon="alert" data-size="20"></span><div class="k">Declined today</div><div class="v" id="t-declined">0</div></div>
          </div>
        </section>

        <section class="view" id="v-flags" aria-label="Suspicious trips">
          <div class="card card-glass">
            <h2>Suspicious trips</h2>
            <p class="muted small" style="margin:6px 0 12px">Leads to review, not verdicts. Found by simple rules plus an anomaly model.</p>
            <ul class="rows" id="flags"></ul>
            <div class="empty hidden" id="flags-empty">Nothing suspicious in the last 14 days.</div>
          </div>
        </section>
      </div>

      <div class="col">
        <section class="view" id="v-demand" aria-label="Demand">
          <div class="card card-white">
            <h2>Typical demand by hour</h2>
            <p class="muted small" id="peaks" style="margin-top:6px"></p>
            <div id="hourly" style="margin-top:6px"></div>
          </div>
          <div class="card card-glass" style="margin-top:18px">
            <h2>Boarding points</h2>
            <ul class="rows" id="stations" style="margin-top:8px"></ul>
            <div class="empty hidden" id="stations-empty">No trips yet.</div>
          </div>
        </section>

        <section class="view" id="v-payouts" aria-label="Payouts">
          <div class="card card-glass">
            <div class="row spread wrap" style="margin-bottom:8px">
              <div><h2>Payouts</h2><p class="muted small">Simulated. No real money moves.</p></div>
              <button class="btn btn-white btn-sm payout-btn" type="button">Run payout</button>
            </div>
            <div id="payout-msg2" class="note hidden" role="status"></div>
            <ul class="rows" id="payouts"></ul>
            <div class="empty hidden" id="payouts-empty">No payouts yet.</div>
          </div>
        </section>
      </div>
    </div>
  </div>

  <nav class="pillnav" aria-label="Main">
    <button type="button" data-view="overview" aria-label="Overview" aria-current="page"><span data-icon="grid"></span></button>
    <button type="button" data-view="demand" aria-label="Demand"><span data-icon="chart"></span></button>
    <button type="button" data-view="flags" aria-label="Suspicious trips"><span data-icon="alert"></span></button>
    <button type="button" data-view="payouts" aria-label="Payouts"><span data-icon="cash"></span></button>
  </nav>

  <div class="sheet-back hidden" id="sheet-back">
    <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="sheet-name">
      <div class="row spread"><div><div id="sheet-name" style="font-size:1.4rem;font-weight:500;letter-spacing:-.02em"></div><div class="muted small">Operator dashboard</div></div>
        <button class="icon-btn dark sm" id="sheet-close" type="button" aria-label="Close"><span data-icon="plus" data-size="20" style="display:block;transform:rotate(45deg)"></span></button></div>
      <button class="btn btn-black btn-block" id="signout" type="button" style="margin-top:20px"><span data-icon="logout" data-size="20"></span> Sign out</button>
    </div>
  </div>

  <script src="../shared/api.js"></script>
  <script src="../shared/ui.js"></script>
  <script src="app.js"></script>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/rider/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/rider/app.js' @'
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
    if (k in idx) { if (h.amount < 0) days[idx[k]].spent += -h.amount; else days[idx[k]].added += h.amount; }
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
'@
$script:count++

# ---------------------------------------------------------------------------
# web/rider/index.html
# ---------------------------------------------------------------------------
Write-BundleFile 'web/rider/index.html' @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Transit Link</title>
  <meta name="theme-color" content="#1c2120">
  <link rel="manifest" href="manifest.webmanifest">
  <link rel="stylesheet" href="../shared/theme.css">
  <style>
    .rgrid { display: block; }
    .rgrid .col > * + * { margin-top: 18px; }
    .qr-box { display: grid; place-items: center; margin: 22px 0 18px; }
    #qr { padding: 14px; border-radius: 24px; background: #fff; border: 1px solid #e6ebe1; line-height: 0; }
    #qr img, #qr canvas { width: min(210px, 62vw); height: auto; }
    .presets { display: flex; gap: 8px; flex-wrap: wrap; }
    .section-title { display: flex; align-items: center; justify-content: space-between; margin: 26px 0 6px; }
    .section-title h2 { font-size: 1.35rem; font-weight: 400; letter-spacing: -.02em; }
    .link-btn { background: none; border: 0; color: var(--muted); cursor: pointer; text-decoration: underline; text-underline-offset: 3px; padding: 6px; }
    .greeting { font-size: 1.1rem; color: var(--muted); }
    @media (min-width: 1000px) {
      .rgrid { display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(0, 1fr); gap: 28px; align-items: start; }
      .section-title.only-mobile { display: none; }
    }
  </style>
</head>
<body>
  <div class="page wide">
    <header class="appbar">
      <button class="icon-btn" id="menu-btn" type="button" aria-label="Open menu" aria-haspopup="true"><span data-icon="dots"></span></button>
      <div class="mid greeting" id="greeting"></div>
      <button class="icon-btn" id="pass-shortcut" type="button" aria-label="Show my pass"><span data-icon="qr"></span></button>
    </header>

    <div class="rgrid">
      <div class="col">
        <section class="view active" id="v-home" aria-label="Wallet">
          <div class="label">Wallet (KES)</div>
          <div class="row wrap" style="align-items:flex-end;gap:12px;margin-top:8px">
            <div class="display xl" id="balance">0</div>
            <span class="delta" id="delta" style="margin-bottom:8px"></span>
          </div>
          <div id="neg-note" class="note hidden" style="margin-top:14px"></div>
          <div class="row" style="margin:22px 0">
            <button class="icon-btn lg" type="button" data-go="pass" aria-label="Show my pass"><span data-icon="qr"></span></button>
            <button class="icon-btn lg" type="button" data-go="activity" aria-label="See activity"><span data-icon="receipt"></span></button>
            <button class="icon-btn lg" type="button" id="refresh" aria-label="Refresh"><span data-icon="refresh"></span></button>
            <button class="btn btn-white grow" type="button" data-go="topup" style="height:58px" aria-label="Top up"><span data-icon="plus" data-size="26"></span></button>
          </div>

          <div class="card card-lime">
            <div class="row spread">
              <div class="chips" role="group" aria-label="Chart type">
                <button class="chip" type="button" data-tab="spent" aria-pressed="true">Spent</button>
                <button class="chip" type="button" data-tab="added" aria-pressed="false">Added</button>
              </div>
              <span class="small muted">This week</span>
            </div>
            <div class="small muted" style="margin-top:18px">Total</div>
            <div class="display lg" id="chart-total" style="margin-top:4px">0</div>
            <div id="chart"></div>
            <p class="small muted" style="margin-top:6px">Based on your latest activity.</p>
          </div>

          <div class="only-mobile">
            <div class="section-title"><h2>Recent activity</h2><button class="link-btn" type="button" data-go="activity">See all</button></div>
            <ul class="txns" id="recent"></ul>
            <div class="empty hidden" id="recent-empty">No activity yet. Top up to get started.</div>
          </div>
        </section>

        <section class="view" id="v-activity" aria-label="Activity">
          <div class="card card-glass">
            <div class="row spread" style="margin-bottom:6px"><h2 style="font-size:1.35rem;font-weight:400;letter-spacing:-.02em">Activity</h2><span class="muted small" id="count"></span></div>
            <ul class="txns" id="all"></ul>
            <div class="empty hidden" id="all-empty">No activity yet. Top up to get started.</div>
          </div>
        </section>
      </div>

      <div class="col">
        <section class="view" id="v-pass" aria-label="Gate pass">
          <div class="card card-white">
            <div class="row spread">
              <div><h2 style="font-size:1.5rem;font-weight:500;letter-spacing:-.02em">Gate pass</h2><div class="muted small" id="pass-name"></div></div>
              <span class="icon-btn dark sm" data-icon="qr" data-size="20"></span>
            </div>
            <div class="qr-box"><div id="qr" aria-label="Your QR pass"></div></div>
            <div class="row spread" style="align-items:flex-end">
              <div class="display md" id="pass-timer">1:00</div>
              <div class="muted small">until a fresh code</div>
            </div>
            <div class="meter" style="margin-top:14px"><i id="pass-meter" style="width:100%"></i></div>
            <p class="muted small" id="pass-note" style="margin-top:12px">Hold this code up to the scanner.</p>
          </div>
        </section>

        <section class="view" id="v-topup" aria-label="Top up">
          <div class="card card-white">
            <h2 style="font-size:1.5rem;font-weight:500;letter-spacing:-.02em">Top up with M-Pesa</h2>
            <form id="topup-form" class="stack" style="margin-top:16px" novalidate>
              <div class="presets" role="group" aria-label="Quick amounts">
                <button class="chip" type="button" data-amt="100" aria-pressed="false">100</button>
                <button class="chip" type="button" data-amt="200" aria-pressed="true">200</button>
                <button class="chip" type="button" data-amt="500" aria-pressed="false">500</button>
                <button class="chip" type="button" data-amt="1000" aria-pressed="false">1,000</button>
              </div>
              <div class="field"><label for="amount">Amount (KES)</label><input class="input" id="amount" inputmode="numeric" value="200"></div>
              <div class="field"><label for="topup-phone">Pay from (optional)</label><input class="input" id="topup-phone" inputmode="tel" placeholder="Same as your account"></div>
              <button class="btn btn-black btn-block" id="topup-btn" type="submit">Send M-Pesa prompt</button>
              <button class="btn btn-lime btn-block hidden" id="confirm-btn" type="button">Approve on phone (demo)</button>
              <div id="topup-msg" class="note hidden" role="status"></div>
            </form>
          </div>
        </section>
      </div>
    </div>
  </div>

  <nav class="pillnav" aria-label="Main">
    <button type="button" data-view="home" aria-label="Home" aria-current="page"><span data-icon="home"></span></button>
    <button type="button" data-view="pass" aria-label="Pass"><span data-icon="qr"></span></button>
    <button type="button" data-view="topup" aria-label="Top up"><span data-icon="plus"></span></button>
    <button type="button" data-view="activity" aria-label="Activity"><span data-icon="receipt"></span></button>
  </nav>

  <div class="sheet-back hidden" id="sheet-back">
    <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="sheet-name">
      <div class="row spread"><div><div id="sheet-name" style="font-size:1.4rem;font-weight:500;letter-spacing:-.02em"></div><div class="muted small" id="sheet-phone"></div></div>
        <button class="icon-btn dark sm" id="sheet-close" type="button" aria-label="Close"><span data-icon="plus" data-size="20" style="display:block;transform:rotate(45deg)"></span></button></div>
      <button class="btn btn-black btn-block" id="signout" type="button" style="margin-top:20px"><span data-icon="logout" data-size="20"></span> Sign out</button>
    </div>
  </div>

  <script src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js"></script>
  <script src="../shared/api.js"></script>
  <script src="../shared/ui.js"></script>
  <script src="app.js"></script>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/rider/manifest.webmanifest
# ---------------------------------------------------------------------------
Write-BundleFile 'web/rider/manifest.webmanifest' @'
{
  "name": "Transit Link Rider",
  "short_name": "Transit Link",
  "start_url": "./",
  "display": "standalone",
  "background_color": "#e8ebe6",
  "theme_color": "#0a7a55"
}
'@
$script:count++

# ---------------------------------------------------------------------------
# web/validator/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/validator/app.js' @'
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
'@
$script:count++

# ---------------------------------------------------------------------------
# web/validator/index.html
# ---------------------------------------------------------------------------
Write-BundleFile 'web/validator/index.html' @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Gate · Transit Link</title>
  <meta name="theme-color" content="#1c2120">
  <link rel="stylesheet" href="../shared/theme.css">
  <style>
    .vgrid { display: block; }
    .vgrid .col > * + * { margin-top: 16px; }
    .vgrid .col + .col { margin-top: 16px; }
    .card h2 { font-size: 1.35rem; font-weight: 400; letter-spacing: -.02em; }
    details.card summary { cursor: pointer; font-size: 1.1rem; list-style: none; display: flex; justify-content: space-between; align-items: center; }
    details.card summary::-webkit-details-marker { display: none; }
    .toggle { display: flex; align-items: center; gap: 12px; cursor: pointer; }
    .toggle input { width: 22px; height: 22px; accent-color: var(--lime); }
    @media (min-width: 1000px) {
      .vgrid { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(0, 1fr); gap: 28px; align-items: start; }
      .vgrid .col + .col { margin-top: 0; }
    }
  </style>
</head>
<body>
  <div class="page wide" style="padding-bottom:48px">
    <header class="appbar">
      <a class="brand" href="/" style="font-size:1.05rem"><span class="mark" data-star="26" style="color:var(--lime);display:grid"></span>Gate</a>
      <div class="row">
        <span id="net-pill" class="pill">Online</span>
        <span id="queue-pill" class="pill">0 waiting</span>
        <button class="icon-btn sm" id="signout" type="button" aria-label="Sign out"><span data-icon="logout" data-size="20"></span></button>
      </div>
    </header>

    <div class="vgrid">
      <div class="col">
        <div id="lamp" class="lamp" role="status" aria-live="polite">
          <h1 id="lamp-title">Ready</h1>
          <div id="lamp-sub" class="muted">Start the camera and point it at a rider's QR code.</div>
        </div>

        <div class="viewfinder"><video id="video" playsinline muted></video></div>
        <canvas id="canvas" class="hidden"></canvas>
        <div class="row">
          <button class="btn btn-white grow" id="cam-btn" type="button"><span data-icon="scan" data-size="22"></span> Start camera</button>
          <button class="btn btn-ghost grow" id="sync-btn" type="button"><span data-icon="refresh" data-size="20"></span> Sync now</button>
        </div>
        <div id="cam-msg" class="note hidden"></div>
      </div>

      <div class="col">
        <div class="card card-white">
          <div class="row spread" style="align-items:flex-start">
            <div><div class="muted small">Boarding point</div><h2 id="station" style="font-size:1.7rem;font-weight:500;letter-spacing:-.03em"></h2><div class="muted small" id="operator"></div></div>
            <span class="icon-btn dark sm" data-icon="train" data-size="20"></span>
          </div>
          <div class="display lg" id="fare" style="margin-top:14px"></div>
          <div class="muted small" style="margin-top:4px">Fare per ride</div>
        </div>

        <div class="card card-glass">
          <h2>Latest results</h2>
          <ul class="txns" id="log" style="margin-top:6px"></ul>
          <div class="empty" id="log-empty">Nothing synced yet.</div>
        </div>

        <details class="card card-glass">
          <summary>No camera? Paste a pass <span data-icon="plus" data-size="20"></span></summary>
          <div class="stack" style="margin-top:14px">
            <textarea class="input" id="manual" placeholder="Paste the pass token from the rider app"></textarea>
            <button class="btn btn-lime btn-block" id="manual-btn" type="button">Add pass</button>
          </div>
        </details>

        <label class="card card-glass toggle"><input id="offline-sw" type="checkbox"><span><strong>Simulate offline</strong><span class="muted small" style="display:block">For demos: queue taps on this device without a connection.</span></span></label>
      </div>
    </div>
  </div>

  <script src="https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js" crossorigin="anonymous"></script>
  <script src="../shared/api.js"></script>
  <script src="../shared/ui.js"></script>
  <script src="app.js"></script>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/validator/sw.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/validator/sw.js' @'
/* Service worker: lets the gate screen open with no connection after the first visit.
   Strategy: network first, fall back to the cache. API calls are never intercepted. */
const CACHE = 'tl-validator-v2';
const ASSETS = [
  './',
  './app.js',
  '../shared/theme.css',
  '../shared/api.js',
  '../shared/ui.js',
  'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => Promise.all(ASSETS.map(url => {
        const cross = url.startsWith('http');
        return cache.add(new Request(url, cross ? { mode: 'cors' } : {})).catch(() => {});
      })))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.pathname.startsWith('/api/')) return;
  event.respondWith(
    fetch(event.request)
      .then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(event.request, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(event.request, { ignoreSearch: true }))
  );
});
'@
$script:count++


Write-Host ""
Write-Host "Done. $($script:count) UI files written." -ForegroundColor Green
Write-Host "Start the app:  cd $Target ; uvicorn app.main:app --reload   then open http://localhost:8000"
Write-Host "Sign-in routing and demo logins are in docs/UI.md."
