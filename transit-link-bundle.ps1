<#
.SYNOPSIS
    Transit Link MVP - one-file bundle. Running this script recreates the whole project.

.DESCRIPTION
    Contains every module, web app, test and document of the Transit Link MVP
    (account-based, M-Pesa-first fare system). Each file is stored below as readable text,
    so you can also just open this script and read the code and docs in order:
      1. README.md and docs/*.md   (start with docs/ARCHITECTURE.md)
      2. app/*.py                  (backend: config -> db -> models -> domain -> routers -> main)
      3. web/*                     (rider app, validator, operator dashboard)
      4. tests/*.py

.PARAMETER Target
    Folder to create. Default: .\transit-link

.PARAMETER Setup
    After writing the files: create a Python virtual environment, install the requirements
    and load the demo data (including 14 days of simulated trips).

.PARAMETER Run
    Do -Setup if needed, then start the server at http://localhost:8000

.EXAMPLE
    .\transit-link-bundle.ps1                 # just write the files
    .\transit-link-bundle.ps1 -Run            # write, install, seed and start the app

.NOTES
    Needs PowerShell 5.1 or newer. -Setup and -Run also need Python 3.10 or newer.
    Demo data only: no real money moves, and demo passwords must be removed before public use.
#>
param(
    [string]$Target = "transit-link",
    [switch]$Setup,
    [switch]$Run
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$isWin = ($env:OS -eq "Windows_NT")
$root = if ([System.IO.Path]::IsPathRooted($Target)) { $Target } else { Join-Path (Get-Location).Path $Target }
$root = [System.IO.Path]::GetFullPath($root)

if ((Test-Path $root) -and (Get-ChildItem $root -Force | Select-Object -First 1)) {
    Write-Host "Folder '$root' already has files. Existing files with the same names will be overwritten." -ForegroundColor Yellow
}

function Write-BundleFile([string]$RelPath, [string]$Content) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $RelPath))
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content + "`n", $utf8)
    Write-Host "  wrote $RelPath"
}

Write-Host "Creating Transit Link in $root" -ForegroundColor Cyan

$script:count = 0
# ---------------------------------------------------------------------------
# README.md
# ---------------------------------------------------------------------------
Write-BundleFile 'README.md' @'
# Transit Link MVP

An account-based, M-Pesa-first fare system, demonstrated on commuter rail with a matatu feeder.
A rider tops up with M-Pesa, shows a QR pass, a validator scans it (even offline), the ledger
charges the fare once, and the operator sees revenue, demand, suspicious trips and a simulated payout.

> This is a showcase prototype. It holds no real money, uses demo stations and fares (not official
> Kenya Railways data), and ships with demo passwords that must be removed before any public use.

## What is inside

| Part | Where | Tech |
| --- | --- | --- |
| Backend API, ledger, fraud model | `app/` | Python, FastAPI, SQLAlchemy |
| Rider app (top-up, QR pass) | `web/rider/` | Plain HTML and JavaScript |
| Validator (offline scanner) | `web/validator/` | Plain JavaScript, IndexedDB, service worker |
| Operator dashboard | `web/operator/` | Plain JavaScript, inline SVG charts |
| Tests | `tests/` | pytest, 10 end-to-end tests |
| Documentation | `docs/` | Markdown with Mermaid diagrams |

One service serves both the API and the three web apps, so there is a single thing to run and deploy.

## Quick start

Requires Python 3.10 or newer.

```bash
python -m venv .venv
source .venv/bin/activate          # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -r requirements.txt
python -m app.seed --history        # demo data + 14 days of simulated trips
uvicorn app.main:app --reload
```

Open http://localhost:8000 and pick an app. API docs are at http://localhost:8000/docs.

Demo logins (also printed by the seed command):

| Who | Login |
| --- | --- |
| Rider | phone 0712 345 678, PIN 1234 |
| Operator | `rail` / `demo1234` (feeder sacco: `sacco` / `demo1234`) |
| Validator | device key `demo-validator-key-1` (Nairobi Central), `demo-validator-key-2` (feeder) |

By default M-Pesa runs in `mock` mode: no credentials needed, and the rider app shows an
"Approve on phone (simulated)" button. See `docs/MPESA.md` to switch to the real Daraja sandbox.

## Run the tests

```bash
pip install pytest
pytest -q
```

## Reading order for the docs

1. `docs/ARCHITECTURE.md` - the big picture and how every module links to the others
2. `docs/DATA_MODEL.md` - tables and the ledger rule
3. `docs/API.md` - every endpoint, who may call it
4. `docs/OFFLINE_SYNC.md` - how the validator works with no connection
5. `docs/MPESA.md`, `docs/FRAUD_MODEL.md` - the two integrations
6. `docs/DEMO_SCRIPT.md` - a 4 minute showcase run
7. `docs/DEPLOY.md`, `docs/ROADMAP.md` - going online and what comes after the MVP
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/API.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/API.md' @'
# API reference

Base path `/api`. Interactive docs: `/docs`. Errors return `{"detail": "..."}` with a plain-language message.

Auth types:
- **Rider / Operator**: `Authorization: Bearer <token>` from the login endpoints (12 hour life).
- **Validator**: `X-Validator-Key: <device key>` header.
- **Callback**: the secret in the URL.

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `GET /health` | none | Status and M-Pesa mode |
| `POST /auth/register` | none | Create a rider `{phone, name, pin}` -> `{token, name}` |
| `POST /auth/login` | none | Rider sign-in `{phone, pin}` |
| `POST /auth/operator/login` | none | Operator sign-in `{username, password}` |
| `GET /wallet` | rider | Balance and last 30 ledger entries |
| `GET /pass` | rider | Signed QR token `{token, expires_in}` (2 minutes by default) |
| `POST /topups` | rider | Start an STK Push `{amount, phone?}` -> topup with `checkout_request_id` and `mode` |
| `GET /topups/{id}` | rider | Poll a top-up (`pending`, `success`, `failed`) |
| `POST /mpesa/callback/{secret}` | secret | Daraja result. Replies `{"ResultCode":0,"ResultDesc":"Accepted"}` |
| `POST /dev/mpesa/confirm/{checkout_request_id}?success=true` | rider | Mock mode only: simulate the PIN entry |
| `GET /validator/config` | validator | Device, operator, station, fare |
| `POST /taps/sync` | validator | Batch of offline taps (max 500). Safe to re-send |
| `GET /operator/summary` | operator | KPIs, 7-day series, by-station, hourly profile, peak hours |
| `GET /operator/flags` | operator | Suspicious trips with reasons |
| `GET /operator/payouts` | operator | Last 20 payouts |
| `POST /operator/payouts/run` | operator | Simulated payout of all unpaid trips (409 if none) |

## Sync request and response

```json
POST /api/taps/sync
{ "taps": [ { "tap_id": "3f1c...", "pass_token": "<jwt from QR>", "tapped_at": "2026-10-16T05:12:09.000Z" } ] }
```

```json
{ "results": [ { "tap_id": "3f1c...", "status": "charged", "reason": null, "fare": 50, "duplicate": false, "balance": 450 } ] }
```

`duplicate: true` means this tap id was already processed; the original result is returned and
nothing is charged again.
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/ARCHITECTURE.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/ARCHITECTURE.md' @'
# Architecture

## Big picture

```
 Rider phone            Validator (phone/laptop)         Operator browser
 web/rider              web/validator                    web/operator
 - QR pass              - camera scan                    - revenue, demand
 - top-up               - IndexedDB queue (offline)      - flags, payouts
        \                    |  (syncs when online)        /
         \                   |                            /
          v                  v                           v
        +-------------------------------------------------+
        |  FastAPI service  (app/main.py, /api/*)         |
        |  routers -> domain modules -> models            |
        |                                                 |
        |  ledger  trips  payouts  fraud  analytics       |
        +-----------+---------------------+---------------+
                    |                     |
                    v                     v
          SQL database               M-Pesa Daraja
          (SQLite or Postgres)       (mock or live STK Push)
```

The same FastAPI process also serves the three web apps as static files, so there is no separate
front-end server.

## Design rules

1. **The ledger is the truth.** A rider's balance is the sum of their `wallet_ledger` rows. Rows are only added, never edited.
2. **Everything that can repeat is idempotent.** A top-up is keyed by its M-Pesa receipt, a fare by its tap id. Re-sending either changes nothing.
3. **The gate never waits for the network.** The validator accepts a readable, unexpired pass and queues it. The server decides charge, decline or reject on sync.
4. **The card is only a key.** The QR pass identifies an account; fares, balances and rules live on the server (account-based ticketing).
5. **Keep logic in domain modules, not routers.** Routers parse requests and call modules.

## Module map

Dependencies point downward: a module only imports from modules listed above it.

| Layer | Module | Responsibility | Uses | Used by |
| --- | --- | --- | --- | --- |
| Foundation | `config.py` | Settings from environment | - | everything |
| | `timeutil.py` | Naive-UTC helpers | - | models, trips, analytics, fraud |
| | `db.py` | Engine, session, `init_db` | config | models, routers, seed |
| | `models.py` | All tables | db, timeutil | every domain module |
| Domain | `security.py` | PIN hashing, JWTs, auth dependencies | config, db, models | routers, trips, seed |
| | `mpesa.py` | STK Push, callback parsing, mock mode | config | routers/topups, schemas |
| | `ledger.py` | Balance, idempotent posting, history | models | trips, topups, wallet, seed |
| | `trips.py` | Turn a scan into a charged/declined/rejected trip | ledger, security, models | routers/taps |
| | `payouts.py` | Simulated operator settlement | models, config | routers/operator |
| | `fraud.py` | Rules and anomaly model | models, config | routers/operator |
| | `analytics.py` | Dashboard numbers | models, config | routers/operator |
| Interface | `schemas.py` | Request bodies | mpesa | routers |
| | `routers/auth.py` | Register, login | security, models | main |
| | `routers/wallet.py` | Balance, history, QR pass | ledger, security | main |
| | `routers/topups.py` | Top-up, M-Pesa callback, mock confirm | mpesa, ledger | main |
| | `routers/taps.py` | Validator config and tap sync | trips | main |
| | `routers/operator.py` | Summary, flags, payouts | analytics, fraud, payouts | main |
| Entry | `main.py` | Wires routers, start-up, static files | all routers, seed | uvicorn |
| Tooling | `seed.py` | Demo data and simulated history | models, ledger, security | main (core), CLI |

## Front-end map

| App | Files | Calls |
| --- | --- | --- |
| Rider | `web/rider/index.html`, `app.js` | `/auth/*`, `/wallet`, `/pass`, `/topups`, `/dev/mpesa/confirm/*` |
| Validator | `web/validator/index.html`, `app.js`, `sw.js` | `/validator/config`, `/taps/sync` |
| Operator | `web/operator/index.html`, `app.js` | `/auth/operator/login`, `/operator/*` |
| Shared | `web/shared/api.js`, `style.css` | fetch wrapper, formatting helpers, theme |

## Request flows

### Top-up

```mermaid
sequenceDiagram
    participant R as Rider app
    participant A as API (topups)
    participant M as M-Pesa Daraja
    participant L as Ledger
    R->>A: POST /topups {amount}
    A->>M: STK Push to rider phone
    A-->>R: pending topup
    M->>A: POST /mpesa/callback/{secret} (result + receipt)
    A->>L: post(+amount, "topup", receipt)  once only
    R->>A: GET /topups/{id} (poll)
    A-->>R: success
```

### Tap and sync

```mermaid
sequenceDiagram
    participant R as Rider app
    participant V as Validator
    participant Q as IndexedDB queue
    participant A as API (taps)
    participant L as Ledger
    R->>R: GET /pass every 60 s (signed, 2 min life)
    V->>V: scan QR, check format and expiry locally
    V->>Q: save {tap_id, pass_token, tapped_at}
    Note over V,Q: works with no connection
    V->>A: POST /taps/sync (when online)
    A->>A: verify signature, time window, replay, balance
    A->>L: post(-fare, "fare", tap_id)
    A-->>V: per-tap result (charged / declined / rejected)
    V->>Q: delete synced taps
```

### Payout

Operator clicks Run payout -> `payouts.run_payout` gathers charged trips with no payout id,
deducts the platform fee, stores a `payouts` row, stamps the trips -> trips can never be paid twice.

## Decisions and trade-offs

| Decision | Why | What changes at scale |
| --- | --- | --- |
| Plain HTML/JS front-ends served by FastAPI | One service, no build step, works offline easily | Port screens to React or Next.js; the API does not change |
| SQLite by default, Postgres by setting `DATABASE_URL` | Zero setup locally, same code on Supabase | Add migrations (Alembic) before real data |
| Fare charged at tap-in, flat per boarding point | Simplest correct model for a demo | Add tap-out and distance fares in `trips.py` and a fares table |
| Whole-shilling integers for money | Matches M-Pesa amounts, avoids float errors | Keep integers or move to minor units |
| Shared-secret signed QR (HS256) | Simple, forgery-proof for the server | Move to public-key signing so validators can verify offline |
| Simulated payouts | No licence is needed to demo | Real settlement needs a licensed partner (see ROADMAP) |
| Demo seed data on start-up (`AUTO_SEED=1`) | Instant showcase | Set `AUTO_SEED=0` and remove demo keys and passwords |

## Where to start reading the code

`app/main.py` -> `app/routers/taps.py` -> `app/trips.py` -> `app/ledger.py`. That path is the whole
tap-to-charge story in about 150 lines.
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/DATA_MODEL.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/DATA_MODEL.md' @'
# Data model

```mermaid
erDiagram
    RIDERS ||--o{ WALLET_LEDGER : has
    RIDERS ||--o{ TOPUPS : starts
    RIDERS ||--o{ TRIPS : takes
    OPERATORS ||--o{ VALIDATORS : owns
    OPERATORS ||--o{ TRIPS : earns
    OPERATORS ||--o{ PAYOUTS : receives
    STATIONS ||--o{ VALIDATORS : hosts
    STATIONS ||--o{ TRIPS : boards
    VALIDATORS ||--o{ TRIPS : records
    PAYOUTS ||--o{ TRIPS : settles
```

## The ledger rule

`wallet_ledger` never has rows edited or deleted. Balance = `SUM(amount)` for the rider.
`UNIQUE (kind, ref)` means the same M-Pesa receipt (kind `topup`) or the same tap id (kind `fare`)
can post only once, even if a callback or sync is repeated.

## Tables

| Table | Key columns | Notes |
| --- | --- | --- |
| `riders` | id, phone (unique, `2547XXXXXXXX`), name, pin_hash | PIN stored as salted PBKDF2 |
| `operators` | id, name, username (unique), password_hash | Dashboard login |
| `stations` | id, name, order_index, fare | Boarding points; flat fare per point (KES) |
| `validators` | id, name, api_key (unique), operator_id, station_id | A device fixed to one operator and one point |
| `topups` | id, rider_id, amount, phone, checkout_request_id (unique), status, mpesa_receipt | `pending`, `success` or `failed` |
| `wallet_ledger` | id, rider_id, amount (+/-), kind, ref, created_at | `topup`, `fare` or `adjustment` |
| `trips` | id (tap id from the device), rider_id, validator_id, station_id, operator_id, pass_jti, tapped_at, fare, status, reason, payout_id | `charged`, `declined`, `rejected` |
| `payouts` | id, operator_id, period_start, period_end, trips_count, gross, fee, net, status | Simulated settlement |

## Trip status and reason

| Status | Reason | Meaning | Money moves? |
| --- | --- | --- | --- |
| charged | - | Fare debited once | Yes |
| declined | insufficient_funds | Balance minus fare would pass the overdraft limit | No |
| rejected | invalid_pass | Signature failed or not a pass | No |
| rejected | stale_pass | Tap time outside the pass's validity window | No |
| rejected | replayed_pass | Same pass already used on another tap | No |
| rejected | unknown_rider | Valid signature, rider no longer exists | No |

## Time and money

- All datetimes are stored as naive UTC. Reports convert to Nairobi time (UTC+3, `LOCAL_UTC_OFFSET_HOURS`).
- All money is whole Kenya shillings (integers).
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/DEMO_SCRIPT.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/DEMO_SCRIPT.md' @'
# Showcase script (about 4 minutes)

## Before you start

```bash
python -m app.seed --reset --history
uvicorn app.main:app
```

Open three browser windows: `/rider/`, `/validator/`, `/operator/` (the rider on your phone if you can).
Browsers allow the camera on `localhost` and HTTPS only.

## Run of show

1. **The problem (20 s).** One account for rail and matatus, paid with M-Pesa. Earlier cards failed because
   they were many incompatible cards. This is one account.
2. **Top up (40 s).** Rider app, sign in as 0712 345 678 / 1234. Enter 200, send the prompt, approve (simulated).
   Balance rises. Point out the M-Pesa receipt in the history.
3. **The pass (20 s).** Show the QR and the countdown bar. Explain it is signed and expires, so a screenshot is useless.
4. **Go offline (60 s).** Validator: connect with `demo-validator-key-1`, tick "Simulate offline". Scan the rider's QR
   (or paste the token). The gate says "Go ahead" and the queue shows 1 waiting.
5. **Come back online (40 s).** Untick offline. The queue syncs, the rider's balance drops by one fare. Scan the same
   QR again: it is rejected as a replay, with no second charge.
6. **Operator view (60 s).** Sign in as `rail` / `demo1234`. Show revenue, the busiest hours (highlighted), trips per
   boarding point. Open Suspicious trips and explain the three rules plus the anomaly model. Click Run payout and
   show gross, fee and net. Say clearly that no real money moves.
7. **Close (20 s).** Roadmap: pilot with one rail station pair, add feeders, align with the national system.

## If something goes wrong

| Problem | Fix |
| --- | --- |
| Camera will not start | Use "No camera? Paste a pass". Get a token from `GET /api/pass` in `/docs` (Authorize with the rider token first) |
| Rider balance too low | Top up again in the rider app |
| Dashboard empty | Re-run `python -m app.seed --reset --history` and restart |
| Projector blocks CDN scripts | Open each page once on the venue Wi-Fi first so the browser caches them |
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/DEPLOY.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/DEPLOY.md' @'
# Deployment

## Local

See `README.md`.

## Render or Railway (one web service)

1. Push the project to GitHub.
2. Create a Web Service from the repo.
   - Build: `pip install -r requirements.txt "psycopg[binary]"`
   - Start: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`
   (A `Dockerfile` is also included.)
3. Create a free Supabase project and copy its Postgres connection string. Change the prefix to
   `postgresql+psycopg://` and set it as `DATABASE_URL`.
4. Set environment variables: `JWT_SECRET` (long random), `CALLBACK_SECRET` (long random),
   `CALLBACK_BASE_URL` (your service URL), and the `MPESA_*` values if using Daraja.
5. Open `https://<your-service>/`. HTTPS gives you camera access on phones and the Daraja callback URL.

## Before showing it to anyone outside the team

| Item | Action |
| --- | --- |
| Demo passwords and keys | Set `AUTO_SEED=0`, delete the demo operators, validators and rider, issue new ones |
| `JWT_SECRET` | Must be unique and secret; rotating it signs everyone out |
| Login throttling | Not included. Add rate limiting before public use |
| Backups | Use Supabase backups; the ledger is the record of money |
| Privacy | Register with the ODPC if you process personal data, publish a privacy notice |

## Cold starts

Free hosting tiers sleep when idle. Open the app a few minutes before a demo.
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/FRAUD_MODEL.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/FRAUD_MODEL.md' @'
# Suspicious-trip detection

Code: `app/fraud.py`. Endpoint: `GET /api/operator/flags`. Flags are computed on demand from the
last 14 days of the operator's trips; nothing is blocked automatically.

## Rules (always on, easy to explain)

| Flag | Trigger |
| --- | --- |
| `double_tap` | Same rider, same boarding point, under 2 minutes after their previous trip |
| `impossible_travel` | Same rider, a different boarding point, under 5 minutes after their previous trip |
| `rapid_burst` | 4 or more trips by one rider inside one hour |

## Anomaly model (optional)

- Library: scikit-learn `IsolationForest`, 100 trees, contamination 2%.
- Features per trip: log of seconds since the rider's previous trip, trips in the last hour, local hour of day.
- Trained on all of the operator's recent trips each time the endpoint is called; needs at least 60 trips.
- Trips the model scores as outliers but the rules did not catch are labelled `model_outlier`.
- If scikit-learn is not installed, the rules still run.

## Test data

`python -m app.seed --history` creates 40 simulated riders over 14 days of commuter trips (peaks around 07:00 and
18:00) plus six injected anomaly groups (double taps, impossible travel, bursts). The test suite asserts that
all three rule flags appear.

## Limits and good practice

- Simulated data proves the pipeline works, not that the model is accurate on real riders.
- Treat flags as leads for a human to review. False positives are expected (for example, a family sharing a phone).
- Flags show an anonymous rider number, not the phone or name.
- Real use needs a data protection impact assessment under the Kenya Data Protection Act 2019.
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/MPESA.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/MPESA.md' @'
# M-Pesa integration

Code: `app/mpesa.py` and `app/routers/topups.py`.

## Modes

| `MPESA_MODE` | Behaviour |
| --- | --- |
| `mock` (default) | No network. `POST /topups` returns a fake checkout id. The rider app shows "Approve on phone (simulated)", which calls `POST /dev/mpesa/confirm/{id}`. |
| `live` | Real Daraja STK Push (sandbox or production per `MPESA_ENV`). |

## Going live on the Daraja sandbox

1. Create an app at the Safaricom Daraja developer portal and copy the consumer key and secret.
2. Use the sandbox shortcode and passkey shown for the Lipa Na M-Pesa Online test credentials.
3. Expose your API over HTTPS (deployed URL, or `ngrok http 8000` locally).
4. Set in `.env`:

```
MPESA_MODE=live
MPESA_ENV=sandbox
MPESA_CONSUMER_KEY=...
MPESA_CONSUMER_SECRET=...
MPESA_SHORTCODE=...
MPESA_PASSKEY=...
CALLBACK_BASE_URL=https://your-public-url
CALLBACK_SECRET=a-long-random-string
```

5. Top up from the rider app with a sandbox test phone number. Daraja calls
   `POST {CALLBACK_BASE_URL}/api/mpesa/callback/{CALLBACK_SECRET}` with the result.

The live path has not been exercised against Daraja in this bundle (only the mock path and the callback
parser are tested). Check the Daraja portal for current sandbox test numbers and request formats.

## Safeguards in the code

- The callback URL contains a secret because Daraja callbacks are not signed. A wrong secret returns 404.
- `apply_result` only changes a top-up that is still `pending`, so retried callbacks are harmless.
- The ledger credit is keyed by the M-Pesa receipt number, so it can never post twice.
- The phone number is normalised to `2547XXXXXXXX` / `2541XXXXXXXX` before use.
- Amount limits come from `MIN_TOPUP` and `MAX_TOPUP`.

## Money and licensing

The MVP never holds real customer funds. A production system that stores rider balances is
handling e-money and needs a licensed partner (see `ROADMAP.md`).
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/OFFLINE_SYNC.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/OFFLINE_SYNC.md' @'
# Offline sync

Goal: a gate keeps moving when the network drops, nobody is charged twice, and fraud is still caught.

## On the validator (`web/validator/app.js`)

1. Scan a QR code (camera + jsQR) or paste a token.
2. Check locally that it looks like a pass and has not expired (payload is decoded, **not** verified).
3. Save `{tap_id, pass_token, tapped_at}` to IndexedDB. `tap_id` is a UUID made on the device.
4. Show "Go ahead". No server call is needed for this.
5. When online (browser event, a 10 second timer, or the Sync button) send the queue to `POST /taps/sync`, then delete the taps the server answered.

The service worker (`sw.js`) caches the page and scanner library so the device can open with no
connection after its first visit. The station and fare are cached in `localStorage`.

## On the server (`app/trips.py`)

Each tap is processed in time order:

1. Known `tap_id`? Return the stored result. This is what makes retries safe.
2. Signature valid and typed `pass`? Otherwise `invalid_pass`.
3. Tap time within the pass's `iat`/`exp` plus tolerance (`TAP_TOLERANCE_SECONDS`, default 300)? Otherwise `stale_pass`. A screenshot used later fails here.
4. Same pass token id (`jti`) already on another tap? `replayed_pass`.
5. Balance minus fare no lower than `-OVERDRAFT_LIMIT`? Otherwise `declined`.
6. Else `charged`: one negative ledger row with the tap id as reference.

## Why an overdraft limit

The gate cannot know the balance offline. A small negative allowance (default KES 50) lets a rider
whose balance is slightly short through, and the next top-up recovers it. Beyond the limit the trip
is `declined` and flagged for the operator.

## Known limits of this MVP

| Limit | Mitigation later |
| --- | --- |
| The validator cannot verify the signature offline (it holds no key) | Public-key signed passes (ECDSA) verified in the browser |
| Device clock errors can make a tap look stale | Sync time from the server and record clock drift |
| A lost phone loses its unsynced queue | Encrypt and back up the queue, or use dedicated devices |
| Two validators can accept the same pass before either syncs | Server rejects the second on sync; short pass life limits the window |
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/ROADMAP.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/ROADMAP.md' @'
# Roadmap: from MVP to a real pilot

## What the MVP proves

The rider, validator, ledger, operator and analytics layers fit together, work with an unreliable
connection, and never charge a tap twice.

## What it does not do

- Hold or move real money (payouts are simulated, balances are not in a licensed wallet).
- Verify passes offline or run on dedicated hardware.
- Support tap-out, distance fares, concessions, refunds, disputes or customer support tools.
- Defend against login guessing or run at city scale.

## Suggested stages

| Stage | Outcome | Main work |
| --- | --- | --- |
| 0. Validate | Real operator and rider needs confirmed | Interview commuters, matatu owners and crews; approach the rail operator |
| 1. Showcase | This MVP | Done |
| 2. Controlled trial | One station pair, small cohort | Licensed payment partner holds funds; real devices; support process |
| 3. Feeders | Matatu operators opt in | Crew incentives, transfer discounts, per-operator settlement |
| 4. National alignment | Plug into the government fare system | Adopt published standards, integrate with the clearinghouse when it exists |

## Engineering backlog

1. Alembic database migrations
2. Public-key signed passes (offline verification)
3. Tap-out and distance-based fares, fare capping and transfers
4. Rate limiting and audit logging
5. Real payouts through a licensed partner (for example M-Pesa B2C) with reconciliation
6. Admin screens for stations, fares and validators
7. React or Next.js front-ends, native wrapper for the validator
8. Model monitoring with real data, and a privacy impact assessment

## Regulation checklist (verify with a lawyer)

- Central Bank of Kenya authorisation for payment services and e-money, or work through a licensed partner.
- National Payment System Bill 2026: check its status and licence categories before you design the trial.
- Data Protection Act 2019: ODPC registration, privacy notice, data protection impact assessment.
- Operator agreements and the national fare-system requirements.
'@
$script:count++

# ---------------------------------------------------------------------------
# .env.example
# ---------------------------------------------------------------------------
Write-BundleFile '.env.example' @'
# Copy to .env and edit. Every value has a safe local default.

# SQLite for local work. For Supabase/Postgres use the psycopg driver prefix:
#   postgresql+psycopg://USER:PASSWORD@HOST:5432/postgres
DATABASE_URL=sqlite:///./transit_link.db

# Signs login tokens and QR passes. CHANGE THIS in any shared deployment.
JWT_SECRET=dev-secret-change-me

# Create demo operators, stations, validators and a demo rider on first start.
AUTO_SEED=1

# M-Pesa: "mock" needs no credentials. "live" talks to Daraja.
MPESA_MODE=mock
MPESA_ENV=sandbox
MPESA_CONSUMER_KEY=
MPESA_CONSUMER_SECRET=
MPESA_SHORTCODE=174379
MPESA_PASSKEY=
# Public HTTPS URL of this API (use ngrok locally). Daraja calls it back here.
CALLBACK_BASE_URL=https://your-public-url.example
# Random string that forms part of the callback URL (Daraja does not sign callbacks).
CALLBACK_SECRET=change-me-too

# Business rules (whole Kenya shillings)
OVERDRAFT_LIMIT=50
PLATFORM_FEE_PCT=2
PASS_TTL_SECONDS=120
TAP_TOLERANCE_SECONDS=300
LOCAL_UTC_OFFSET_HOURS=3
'@
$script:count++

# ---------------------------------------------------------------------------
# Dockerfile
# ---------------------------------------------------------------------------
Write-BundleFile 'Dockerfile' @'
FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt "psycopg[binary]"
COPY app ./app
COPY web ./web
ENV PORT=8000
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]
'@
$script:count++

# ---------------------------------------------------------------------------
# requirements.txt
# ---------------------------------------------------------------------------
Write-BundleFile 'requirements.txt' @'
fastapi>=0.110
uvicorn[standard]>=0.29
sqlalchemy>=2.0
pyjwt>=2.8
httpx>=0.27
python-dotenv>=1.0
numpy>=1.26
scikit-learn>=1.4
# Only needed when DATABASE_URL points at Postgres/Supabase:
# psycopg[binary]>=3.1
# Only needed to run the tests:
# pytest>=8.0
'@
$script:count++

# ---------------------------------------------------------------------------
# app/__init__.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/__init__.py' @'
"""Transit Link MVP backend. See docs/ARCHITECTURE.md for the module map."""
'@
$script:count++

# ---------------------------------------------------------------------------
# app/analytics.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/analytics.py' @'
"""Numbers for the operator dashboard.

Linked to: routers/operator (GET /operator/summary), models, config.
Everything is bucketed in Nairobi time. Aggregation happens in Python over the last
14 days of trips so the same code runs on SQLite and Postgres.
"""
from collections import Counter, defaultdict
from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .config import settings
from .models import Station, Trip
from .timeutil import utcnow


def _local(dt: datetime) -> datetime:
    return dt + timedelta(hours=settings.local_utc_offset_hours)


def summary(db: Session, operator_id: int, now: datetime | None = None) -> dict:
    now = now or utcnow()
    today = _local(now).date()
    trips = list(db.scalars(select(Trip).where(Trip.operator_id == operator_id, Trip.tapped_at >= now - timedelta(days=14))))
    stations = {s.id: s.name for s in db.scalars(select(Station))}

    charged = [t for t in trips if t.status == "charged"]
    today_charged = [t for t in charged if _local(t.tapped_at).date() == today]

    # last 7 local days, oldest first, zeros included
    days = [today - timedelta(days=i) for i in range(6, -1, -1)]
    per_day = {d: [0, 0] for d in days}
    for t in charged:
        d = _local(t.tapped_at).date()
        if d in per_day:
            per_day[d][0] += 1
            per_day[d][1] += t.fare

    by_station: dict[int, list[int]] = defaultdict(lambda: [0, 0])
    for t in charged:
        if _local(t.tapped_at).date() >= days[0]:
            by_station[t.station_id][0] += 1
            by_station[t.station_id][1] += t.fare

    # average trips per local hour of day: a simple demand profile and peak forecast
    hour_totals: Counter = Counter()
    for t in charged:
        hour_totals[_local(t.tapped_at).hour] += 1
    observed_days = max(1, len({_local(t.tapped_at).date() for t in charged}))
    hourly = [round(hour_totals[h] / observed_days, 1) for h in range(24)]
    peaks = [h for h, v in sorted(enumerate(hourly), key=lambda p: -p[1])[:3] if v > 0]

    unpaid = db.scalar(
        select(func.coalesce(func.sum(Trip.fare), 0)).where(
            Trip.operator_id == operator_id, Trip.status == "charged", Trip.payout_id.is_(None)
        )
    )

    return {
        "today": {
            "trips": len(today_charged),
            "revenue": sum(t.fare for t in today_charged),
            "riders": len({t.rider_id for t in today_charged}),
            "declined": sum(1 for t in trips if t.status == "declined" and _local(t.tapped_at).date() == today),
        },
        "unpaid_revenue": unpaid,
        "daily": [{"date": d.isoformat(), "trips": per_day[d][0], "revenue": per_day[d][1]} for d in days],
        "by_station": sorted(
            ({"station": stations.get(sid, f"#{sid}"), "trips": v[0], "revenue": v[1]} for sid, v in by_station.items()),
            key=lambda r: -r["trips"],
        ),
        "hourly_profile": hourly,
        "forecast_peak_hours": sorted(peaks),
    }
'@
$script:count++

# ---------------------------------------------------------------------------
# app/config.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/config.py' @'
"""Settings, read once from environment variables (and an optional .env file).

Linked to: every other module imports `settings` from here. Nothing here
imports from the rest of the app, so it is the root of the dependency tree.
"""
import os

try:  # .env support is optional
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:  # pragma: no cover
    pass


def _int(name: str, default: int) -> int:
    return int(os.getenv(name, str(default)))


def _float(name: str, default: float) -> float:
    return float(os.getenv(name, str(default)))


class Settings:
    def __init__(self) -> None:
        self.database_url = os.getenv("DATABASE_URL", "sqlite:///./transit_link.db")
        self.jwt_secret = os.getenv("JWT_SECRET", "dev-secret-change-me")
        self.auto_seed = os.getenv("AUTO_SEED", "1") == "1"

        # Money is stored as whole Kenya shillings (M-Pesa STK amounts are integers).
        self.overdraft_limit = _int("OVERDRAFT_LIMIT", 50)
        self.platform_fee_pct = _float("PLATFORM_FEE_PCT", 2.0)
        self.min_topup = _int("MIN_TOPUP", 10)
        self.max_topup = _int("MAX_TOPUP", 10000)

        # QR passes and offline taps
        self.pass_ttl_seconds = _int("PASS_TTL_SECONDS", 120)
        self.tap_tolerance_seconds = _int("TAP_TOLERANCE_SECONDS", 300)
        self.access_token_hours = _int("ACCESS_TOKEN_HOURS", 12)

        # Reporting buckets use Nairobi time (UTC+3, no daylight saving)
        self.local_utc_offset_hours = _int("LOCAL_UTC_OFFSET_HOURS", 3)

        # M-Pesa Daraja
        self.mpesa_mode = os.getenv("MPESA_MODE", "mock")  # mock | live
        self.mpesa_env = os.getenv("MPESA_ENV", "sandbox")  # sandbox | production
        self.mpesa_consumer_key = os.getenv("MPESA_CONSUMER_KEY", "")
        self.mpesa_consumer_secret = os.getenv("MPESA_CONSUMER_SECRET", "")
        self.mpesa_shortcode = os.getenv("MPESA_SHORTCODE", "174379")
        self.mpesa_passkey = os.getenv("MPESA_PASSKEY", "")
        self.callback_base_url = os.getenv("CALLBACK_BASE_URL", "").rstrip("/")
        self.callback_secret = os.getenv("CALLBACK_SECRET", "change-me-too")

        self.cors_origins = [o for o in os.getenv("CORS_ORIGINS", "").split(",") if o]


settings = Settings()
'@
$script:count++

# ---------------------------------------------------------------------------
# app/db.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/db.py' @'
"""Database engine, session factory and the FastAPI session dependency.

Linked to: models (Base), every router (get_db), seed/main (init_db).
SQLite is used by default; set DATABASE_URL to use Postgres/Supabase.
"""
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import settings

_connect_args = {"check_same_thread": False} if settings.database_url.startswith("sqlite") else {}
engine = create_engine(settings.database_url, connect_args=_connect_args, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db() -> None:
    from . import models  # noqa: F401  (registers the tables)

    Base.metadata.create_all(engine)
'@
$script:count++

# ---------------------------------------------------------------------------
# app/fraud.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/fraud.py' @'
"""Suspicious-trip detection: transparent rules first, a small ML model second.

Linked to: routers/operator (GET /operator/flags), models, config.
Rules (explainable, always on):
  double_tap         same rider, same station, under 2 minutes after their last trip
  impossible_travel  same rider, DIFFERENT station, under 5 minutes after their last trip
  rapid_burst        4 or more trips by one rider inside an hour
Model (optional, needs scikit-learn and 60+ trips):
  IsolationForest over [log gap since last trip, trips in last hour, local hour of day].
  Anything the rules did not already catch but the model scores as an outlier is
  reported as model_outlier. Flags are leads for a human to review, not verdicts.
"""
import math
from collections import deque
from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import settings
from .models import Trip
from .timeutil import utcnow

try:
    import numpy as np
    from sklearn.ensemble import IsolationForest
except ImportError:  # the rules still work without scikit-learn
    np = None
    IsolationForest = None

DOUBLE_TAP_SECONDS = 120
IMPOSSIBLE_TRAVEL_SECONDS = 300
BURST_COUNT = 4
BURST_WINDOW_SECONDS = 3600
MIN_TRAIN_ROWS = 60
WEEK = 7 * 86400


def scan(db: Session, operator_id: int, days: int = 14) -> list[dict]:
    since = utcnow() - timedelta(days=days)
    trips = list(
        db.scalars(
            select(Trip)
            .where(
                Trip.operator_id == operator_id,
                Trip.rider_id.is_not(None),
                Trip.status.in_(("charged", "declined")),
                Trip.tapped_at >= since,
            )
            .order_by(Trip.rider_id, Trip.tapped_at)
        )
    )

    rows: list[tuple[Trip, list[str]]] = []
    features: list[list[float]] = []
    prev: Trip | None = None
    window: deque = deque()

    for t in trips:
        if prev is None or prev.rider_id != t.rider_id:
            prev, window = None, deque()
        gap = (t.tapped_at - prev.tapped_at).total_seconds() if prev else None
        while window and (t.tapped_at - window[0]).total_seconds() > BURST_WINDOW_SECONDS:
            window.popleft()
        window.append(t.tapped_at)

        reasons: list[str] = []
        if gap is not None:
            if gap < DOUBLE_TAP_SECONDS and prev.station_id == t.station_id:
                reasons.append("double_tap")
            elif gap < IMPOSSIBLE_TRAVEL_SECONDS and prev.station_id != t.station_id:
                reasons.append("impossible_travel")
        if len(window) >= BURST_COUNT:
            reasons.append("rapid_burst")

        local_hour = (t.tapped_at + timedelta(hours=settings.local_utc_offset_hours)).hour
        features.append([math.log1p(min(gap if gap is not None else WEEK, WEEK)), len(window), local_hour])
        rows.append((t, reasons))
        prev = t

    scores: list[float | None] = [None] * len(rows)
    if IsolationForest is not None and len(rows) >= MIN_TRAIN_ROWS:
        x = np.array(features, dtype=float)
        model = IsolationForest(n_estimators=100, contamination=0.02, random_state=42).fit(x)
        labels = model.predict(x)
        raw = -model.score_samples(x)  # higher = more unusual
        for i, (label, score) in enumerate(zip(labels, raw)):
            scores[i] = round(float(score), 3)
            if label == -1 and not rows[i][1]:
                rows[i][1].append("model_outlier")

    flagged = [
        {
            "trip_id": t.id,
            "rider_id": t.rider_id,
            "station_id": t.station_id,
            "tapped_at": t.tapped_at.isoformat() + "Z",
            "fare": t.fare,
            "status": t.status,
            "reasons": reasons,
            "score": scores[i],
        }
        for i, (t, reasons) in enumerate(rows)
        if reasons
    ]
    flagged.sort(key=lambda f: f["tapped_at"], reverse=True)
    return flagged
'@
$script:count++

# ---------------------------------------------------------------------------
# app/ledger.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/ledger.py' @'
"""The wallet ledger: the single source of truth for rider money.

Linked to: trips (fare debits), routers/topups (credits), routers/wallet (balance),
seed. Rules: rows are only ever added; a balance is the SUM of a rider's rows;
(kind, ref) is unique so the same M-Pesa receipt or trip can never post twice.
"""
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .models import LedgerEntry


def balance(db: Session, rider_id: int) -> int:
    return db.scalar(select(func.coalesce(func.sum(LedgerEntry.amount), 0)).where(LedgerEntry.rider_id == rider_id)) or 0


def post(db: Session, rider_id: int, amount: int, kind: str, ref: str) -> LedgerEntry | None:
    """Add a ledger row. Returns None (and does nothing) if (kind, ref) already exists."""
    exists = db.scalar(select(LedgerEntry.id).where(LedgerEntry.kind == kind, LedgerEntry.ref == ref))
    if exists:
        return None
    entry = LedgerEntry(rider_id=rider_id, amount=amount, kind=kind, ref=ref)
    db.add(entry)
    db.flush()
    return entry


def history(db: Session, rider_id: int, limit: int = 30) -> list[LedgerEntry]:
    return list(
        db.scalars(
            select(LedgerEntry)
            .where(LedgerEntry.rider_id == rider_id)
            .order_by(LedgerEntry.created_at.desc(), LedgerEntry.id.desc())
            .limit(limit)
        )
    )
'@
$script:count++

# ---------------------------------------------------------------------------
# app/main.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/main.py' @'
"""Application entry point: wires routers, start-up and the static web apps.

Linked to: db (init_db), seed (ensure_demo), every router, and the web/ folder.
Run:  uvicorn app.main:app --reload     then open http://localhost:8000
"""
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import APIRouter, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .config import settings
from .db import init_db
from .routers import auth, operator, taps, topups, wallet

WEB_DIR = Path(__file__).resolve().parent.parent / "web"


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    if settings.auto_seed:
        from .seed import ensure_demo

        ensure_demo()
    yield


app = FastAPI(title="Transit Link MVP", version="0.1.0", lifespan=lifespan)

if settings.cors_origins:
    app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["*"], allow_headers=["*"])

api = APIRouter(prefix="/api")
for module in (auth, wallet, topups, taps, operator):
    api.include_router(module.router)


@api.get("/health", tags=["meta"])
def health():
    return {"status": "ok", "mpesa_mode": settings.mpesa_mode}


app.include_router(api)

# Must be last: serves /, /rider/, /validator/ and /operator/ from the web folder.
app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
'@
$script:count++

# ---------------------------------------------------------------------------
# app/models.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/models.py' @'
"""Database tables. See docs/DATA_MODEL.md for the diagram.

Linked to: ledger, trips, payouts, fraud, analytics, seed and all routers.
Design rule: balances are NEVER stored. A rider's balance is the sum of their
wallet_ledger rows, which only ever receive new rows.
"""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .timeutil import utcnow


class Rider(Base):
    __tablename__ = "riders"
    id: Mapped[int] = mapped_column(primary_key=True)
    phone: Mapped[str] = mapped_column(String(15), unique=True, index=True)  # 2547XXXXXXXX
    name: Mapped[str] = mapped_column(String(80))
    pin_hash: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Operator(Base):
    __tablename__ = "operators"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    username: Mapped[str] = mapped_column(String(40), unique=True)
    password_hash: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Station(Base):
    """A boarding point. MVP fares are flat per boarding station (tap-in only)."""

    __tablename__ = "stations"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    order_index: Mapped[int] = mapped_column(Integer, default=0)
    fare: Mapped[int] = mapped_column(Integer, default=50)  # KES


class Validator(Base):
    """A scanning device (phone or laptop) fixed to one operator and one station."""

    __tablename__ = "validators"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    api_key: Mapped[str] = mapped_column(String(64), unique=True)
    operator_id: Mapped[int] = mapped_column(ForeignKey("operators.id"))
    station_id: Mapped[int] = mapped_column(ForeignKey("stations.id"))


class Topup(Base):
    __tablename__ = "topups"
    id: Mapped[int] = mapped_column(primary_key=True)
    rider_id: Mapped[int] = mapped_column(ForeignKey("riders.id"), index=True)
    amount: Mapped[int] = mapped_column(Integer)
    phone: Mapped[str] = mapped_column(String(15))
    checkout_request_id: Mapped[str] = mapped_column(String(80), unique=True)
    merchant_request_id: Mapped[str | None] = mapped_column(String(80), nullable=True)
    status: Mapped[str] = mapped_column(String(10), default="pending")  # pending|success|failed
    mpesa_receipt: Mapped[str | None] = mapped_column(String(30), nullable=True)
    result_desc: Mapped[str | None] = mapped_column(String(200), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class LedgerEntry(Base):
    __tablename__ = "wallet_ledger"
    __table_args__ = (UniqueConstraint("kind", "ref", name="uq_ledger_kind_ref"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    rider_id: Mapped[int] = mapped_column(ForeignKey("riders.id"), index=True)
    amount: Mapped[int] = mapped_column(Integer)  # +credit / -debit
    kind: Mapped[str] = mapped_column(String(20))  # topup | fare | adjustment
    ref: Mapped[str] = mapped_column(String(80))  # M-Pesa receipt or trip id
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Payout(Base):
    __tablename__ = "payouts"
    id: Mapped[int] = mapped_column(primary_key=True)
    operator_id: Mapped[int] = mapped_column(ForeignKey("operators.id"), index=True)
    period_start: Mapped[datetime] = mapped_column(DateTime)
    period_end: Mapped[datetime] = mapped_column(DateTime)
    trips_count: Mapped[int] = mapped_column(Integer)
    gross: Mapped[int] = mapped_column(Integer)
    fee: Mapped[int] = mapped_column(Integer)
    net: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(20), default="simulated_paid")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Trip(Base):
    """One scan. The id is generated on the validator, which makes sync idempotent."""

    __tablename__ = "trips"
    __table_args__ = (Index("ix_trips_op_time", "operator_id", "tapped_at"),)
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    rider_id: Mapped[int | None] = mapped_column(ForeignKey("riders.id"), nullable=True, index=True)
    validator_id: Mapped[int | None] = mapped_column(ForeignKey("validators.id"), nullable=True)
    station_id: Mapped[int] = mapped_column(ForeignKey("stations.id"))
    operator_id: Mapped[int] = mapped_column(ForeignKey("operators.id"))
    pass_jti: Mapped[str] = mapped_column(String(64), default="", index=True)
    tapped_at: Mapped[datetime] = mapped_column(DateTime, index=True)
    received_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    fare: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[str] = mapped_column(String(12))  # charged | declined | rejected
    reason: Mapped[str | None] = mapped_column(String(40), nullable=True)
    payout_id: Mapped[int | None] = mapped_column(ForeignKey("payouts.id"), nullable=True)
'@
$script:count++

# ---------------------------------------------------------------------------
# app/mpesa.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/mpesa.py' @'
"""M-Pesa Daraja integration (STK Push) with a mock mode for offline demos.

Linked to: routers/topups (start a push, parse the callback), schemas (phone check).
MPESA_MODE=mock  -> no network; the rider app shows a 'simulate PIN' button.
MPESA_MODE=live  -> real Daraja calls (sandbox or production per MPESA_ENV).
"""
import base64
import re
import secrets
import uuid
from datetime import timedelta

import httpx

from .config import settings
from .timeutil import utcnow


class MpesaError(Exception):
    pass


def normalize_phone(raw: str) -> str:
    """Return 2547XXXXXXXX / 2541XXXXXXXX or raise ValueError."""
    digits = re.sub(r"\D", "", raw or "")
    if digits.startswith("0") and len(digits) == 10:
        digits = "254" + digits[1:]
    elif len(digits) == 9 and digits[0] in "71":
        digits = "254" + digits
    if not re.fullmatch(r"254[17]\d{8}", digits):
        raise ValueError("Enter a Kenyan mobile number such as 0712 345 678.")
    return digits


def _base_url() -> str:
    return "https://api.safaricom.co.ke" if settings.mpesa_env == "production" else "https://sandbox.safaricom.co.ke"


def _access_token() -> str:
    resp = httpx.get(
        f"{_base_url()}/oauth/v1/generate",
        params={"grant_type": "client_credentials"},
        auth=(settings.mpesa_consumer_key, settings.mpesa_consumer_secret),
        timeout=15,
    )
    if resp.status_code != 200:
        raise MpesaError(f"Daraja auth failed ({resp.status_code}). Check consumer key and secret.")
    return resp.json()["access_token"]


def stk_push(phone: str, amount: int, reference: str) -> dict:
    """Start a payment prompt on the rider's phone.

    Returns {"merchant_request_id", "checkout_request_id", "mode"}.
    """
    if settings.mpesa_mode != "live":
        return {
            "merchant_request_id": f"MOCK-M-{uuid.uuid4().hex[:10]}",
            "checkout_request_id": f"ws_CO_MOCK_{uuid.uuid4().hex[:16]}",
            "mode": "mock",
        }
    if not settings.callback_base_url:
        raise MpesaError("CALLBACK_BASE_URL is not set. Daraja needs a public HTTPS URL.")
    timestamp = (utcnow() + timedelta(hours=3)).strftime("%Y%m%d%H%M%S")  # Nairobi time
    password = base64.b64encode(f"{settings.mpesa_shortcode}{settings.mpesa_passkey}{timestamp}".encode()).decode()
    body = {
        "BusinessShortCode": settings.mpesa_shortcode,
        "Password": password,
        "Timestamp": timestamp,
        "TransactionType": "CustomerPayBillOnline",
        "Amount": amount,
        "PartyA": phone,
        "PartyB": settings.mpesa_shortcode,
        "PhoneNumber": phone,
        "CallBackURL": f"{settings.callback_base_url}/api/mpesa/callback/{settings.callback_secret}",
        "AccountReference": reference[:12],
        "TransactionDesc": "Transit Link top-up",
    }
    resp = httpx.post(
        f"{_base_url()}/mpesa/stkpush/v1/processrequest",
        json=body,
        headers={"Authorization": f"Bearer {_access_token()}"},
        timeout=20,
    )
    data = resp.json()
    if resp.status_code != 200 or data.get("ResponseCode") != "0":
        raise MpesaError(data.get("errorMessage") or data.get("ResponseDescription") or "STK push was rejected.")
    return {
        "merchant_request_id": data["MerchantRequestID"],
        "checkout_request_id": data["CheckoutRequestID"],
        "mode": "live",
    }


def parse_callback(payload: dict) -> dict:
    """Flatten Daraja's nested callback into one dict.

    Shape: {"Body": {"stkCallback": {"CheckoutRequestID", "ResultCode", "ResultDesc",
            "CallbackMetadata": {"Item": [{"Name": "...", "Value": ...}, ...]}}}}
    """
    try:
        cb = payload["Body"]["stkCallback"]
        items = {i["Name"]: i.get("Value") for i in cb.get("CallbackMetadata", {}).get("Item", [])}
        return {
            "checkout_request_id": cb["CheckoutRequestID"],
            "result_code": int(cb["ResultCode"]),
            "result_desc": str(cb.get("ResultDesc", ""))[:200],
            "receipt": items.get("MpesaReceiptNumber"),
            "amount": items.get("Amount"),
        }
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("Unrecognised callback payload") from exc


def mock_receipt() -> str:
    return "MOCK" + secrets.token_hex(4).upper()
'@
$script:count++

# ---------------------------------------------------------------------------
# app/payouts.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/payouts.py' @'
"""Simulated operator settlement. No real money moves in the MVP.

Linked to: routers/operator (POST /payouts/run), models.
A payout bundles every charged trip not yet paid for one operator, takes the
platform fee, and stamps the trips with the payout id so they are never paid twice.
"""
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import settings
from .models import Payout, Trip
from .timeutil import utcnow


def run_payout(db: Session, operator_id: int) -> Payout | None:
    trips = list(
        db.scalars(
            select(Trip).where(Trip.operator_id == operator_id, Trip.status == "charged", Trip.payout_id.is_(None))
        )
    )
    if not trips:
        return None
    gross = sum(t.fare for t in trips)
    fee = round(gross * settings.platform_fee_pct / 100)
    payout = Payout(
        operator_id=operator_id,
        period_start=min(t.tapped_at for t in trips),
        period_end=max(t.tapped_at for t in trips),
        trips_count=len(trips),
        gross=gross,
        fee=fee,
        net=gross - fee,
        status="simulated_paid",
        created_at=utcnow(),
    )
    db.add(payout)
    db.flush()
    for t in trips:
        t.payout_id = payout.id
    db.flush()
    return payout
'@
$script:count++

# ---------------------------------------------------------------------------
# app/routers/__init__.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/routers/__init__.py' @'
"""API routers, one module per area (see docs/ARCHITECTURE.md)."""
'@
$script:count++

# ---------------------------------------------------------------------------
# app/routers/auth.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/routers/auth.py' @'
"""Sign-up and sign-in for riders and operators.

Linked to: security (hash/verify, tokens), models (Rider, Operator), schemas.
"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Operator, Rider
from ..schemas import LoginIn, OperatorLoginIn, RegisterIn
from ..security import create_access_token, hash_secret, verify_secret

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", status_code=201)
def register(body: RegisterIn, db: Session = Depends(get_db)):
    if db.scalar(select(Rider.id).where(Rider.phone == body.phone)):
        raise HTTPException(409, "That phone number already has an account. Sign in instead.")
    rider = Rider(phone=body.phone, name=body.name.strip(), pin_hash=hash_secret(body.pin))
    db.add(rider)
    db.commit()
    return {"token": create_access_token(rider.id, "rider"), "name": rider.name}


@router.post("/login")
def login(body: LoginIn, db: Session = Depends(get_db)):
    rider = db.scalar(select(Rider).where(Rider.phone == body.phone))
    if rider is None or not verify_secret(body.pin, rider.pin_hash):
        raise HTTPException(401, "Phone number or PIN is wrong.")
    return {"token": create_access_token(rider.id, "rider"), "name": rider.name}


@router.post("/operator/login")
def operator_login(body: OperatorLoginIn, db: Session = Depends(get_db)):
    op = db.scalar(select(Operator).where(Operator.username == body.username))
    if op is None or not verify_secret(body.password, op.password_hash):
        raise HTTPException(401, "Username or password is wrong.")
    return {"token": create_access_token(op.id, "operator"), "name": op.name}
'@
$script:count++

# ---------------------------------------------------------------------------
# app/routers/operator.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/routers/operator.py' @'
"""Operator dashboard API.

Linked to: analytics (summary), fraud (flags), payouts (run), models, security.
Every query is scoped to the logged-in operator's own id.
"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import analytics, fraud, payouts
from ..db import get_db
from ..models import Operator, Payout, Station
from ..security import current_operator

router = APIRouter(prefix="/operator", tags=["operator"])


def _payout_json(p: Payout) -> dict:
    return {
        "id": p.id,
        "trips": p.trips_count,
        "gross": p.gross,
        "fee": p.fee,
        "net": p.net,
        "status": p.status,
        "created_at": p.created_at.isoformat() + "Z",
    }


@router.get("/summary")
def summary(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    return {"operator": op.name, **analytics.summary(db, op.id)}


@router.get("/flags")
def flags(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    stations = {s.id: s.name for s in db.scalars(select(Station))}
    items = fraud.scan(db, op.id)
    for item in items:
        item["station"] = stations.get(item["station_id"], "?")
    return {"flags": items[:100]}


@router.get("/payouts")
def list_payouts(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    rows = db.scalars(select(Payout).where(Payout.operator_id == op.id).order_by(Payout.id.desc()).limit(20))
    return {"payouts": [_payout_json(p) for p in rows]}


@router.post("/payouts/run")
def run_payout(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    payout = payouts.run_payout(db, op.id)
    if payout is None:
        raise HTTPException(409, "Nothing to pay out yet. No unpaid trips.")
    db.commit()
    return _payout_json(payout)
'@
$script:count++

# ---------------------------------------------------------------------------
# app/routers/taps.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/routers/taps.py' @'
"""Validator endpoints: fetch device config and sync offline taps.

Linked to: trips.process_tap, security.current_validator, models.
"""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from .. import trips
from ..db import get_db
from ..models import Operator, Station, Validator
from ..schemas import SyncIn
from ..security import current_validator
from ..timeutil import to_naive_utc

router = APIRouter(tags=["validator"])


@router.get("/validator/config")
def validator_config(validator: Validator = Depends(current_validator), db: Session = Depends(get_db)):
    station = db.get(Station, validator.station_id)
    operator = db.get(Operator, validator.operator_id)
    return {
        "validator": validator.name,
        "operator": operator.name,
        "station": station.name,
        "fare": station.fare,
    }


@router.post("/taps/sync")
def sync_taps(body: SyncIn, validator: Validator = Depends(current_validator), db: Session = Depends(get_db)):
    """Process a batch of taps in the order they happened. Safe to re-send."""
    ordered = sorted(body.taps, key=lambda t: to_naive_utc(t.tapped_at))
    results = [
        trips.process_tap(db, validator, t.tap_id, t.pass_token, to_naive_utc(t.tapped_at)) for t in ordered
    ]
    db.commit()
    return {"results": results}
'@
$script:count++

# ---------------------------------------------------------------------------
# app/routers/topups.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/routers/topups.py' @'
"""M-Pesa top-ups: start a payment, receive the result, credit the ledger.

Linked to: mpesa (STK push and callback parsing), ledger (credit), models.Topup.
Flow: POST /topups -> STK prompt on phone -> Daraja POSTs /mpesa/callback/{secret}
      -> pending topup becomes success and one ledger credit is posted (once).
"""
import hmac
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import ledger, mpesa
from ..config import settings
from ..db import get_db
from ..models import Rider, Topup
from ..schemas import TopupIn
from ..security import current_rider
from ..timeutil import utcnow

router = APIRouter(tags=["topups"])


def apply_result(db: Session, checkout_request_id: str, result_code: int, result_desc: str, receipt: str | None) -> Topup | None:
    """Settle a pending top-up. Safe to call twice: only a pending top-up changes."""
    topup = db.scalar(select(Topup).where(Topup.checkout_request_id == checkout_request_id))
    if topup is None or topup.status != "pending":
        return topup
    topup.completed_at = utcnow()
    topup.result_desc = result_desc
    if result_code == 0 and receipt:
        topup.status, topup.mpesa_receipt = "success", receipt
        ledger.post(db, topup.rider_id, topup.amount, "topup", receipt)
    else:
        topup.status = "failed"
    db.commit()
    return topup


def _topup_json(t: Topup) -> dict:
    return {"id": t.id, "status": t.status, "amount": t.amount, "receipt": t.mpesa_receipt, "message": t.result_desc}


@router.post("/topups", status_code=201)
def start_topup(body: TopupIn, rider: Rider = Depends(current_rider), db: Session = Depends(get_db)):
    if not settings.min_topup <= body.amount <= settings.max_topup:
        raise HTTPException(422, f"Top up between KES {settings.min_topup} and KES {settings.max_topup}.")
    phone = body.phone or rider.phone
    try:
        push = mpesa.stk_push(phone, body.amount, reference=f"TL{rider.id}")
    except mpesa.MpesaError as exc:
        raise HTTPException(502, str(exc))
    topup = Topup(
        rider_id=rider.id,
        amount=body.amount,
        phone=phone,
        checkout_request_id=push["checkout_request_id"],
        merchant_request_id=push["merchant_request_id"],
    )
    db.add(topup)
    db.commit()
    return {**_topup_json(topup), "mode": push["mode"], "checkout_request_id": topup.checkout_request_id}


@router.get("/topups/{topup_id}")
def topup_status(topup_id: int, rider: Rider = Depends(current_rider), db: Session = Depends(get_db)):
    topup = db.get(Topup, topup_id)
    if topup is None or topup.rider_id != rider.id:
        raise HTTPException(404, "Top-up not found.")
    return _topup_json(topup)


@router.post("/mpesa/callback/{secret}")
async def mpesa_callback(secret: str, request: Request, db: Session = Depends(get_db)):
    """Daraja calls this. The secret in the URL is our only authentication."""
    if not hmac.compare_digest(secret, settings.callback_secret):
        raise HTTPException(404, "Not found")
    try:
        parsed = mpesa.parse_callback(await request.json())
    except ValueError:
        raise HTTPException(400, "Bad callback payload")
    apply_result(db, parsed["checkout_request_id"], parsed["result_code"], parsed["result_desc"], parsed["receipt"])
    return {"ResultCode": 0, "ResultDesc": "Accepted"}  # Daraja expects this acknowledgement


@router.post("/dev/mpesa/confirm/{checkout_request_id}")
def mock_confirm(checkout_request_id: str, success: bool = True, rider: Rider = Depends(current_rider), db: Session = Depends(get_db)):
    """Mock mode only: pretend the rider entered their M-Pesa PIN."""
    if settings.mpesa_mode != "mock":
        raise HTTPException(404, "Not found")
    topup = db.scalar(select(Topup).where(Topup.checkout_request_id == checkout_request_id))
    if topup is None or topup.rider_id != rider.id:
        raise HTTPException(404, "Top-up not found.")
    apply_result(
        db,
        checkout_request_id,
        0 if success else 1032,
        "Simulated success" if success else "Request cancelled by user",
        mpesa.mock_receipt() if success else None,
    )
    return _topup_json(db.get(Topup, topup.id))
'@
$script:count++

# ---------------------------------------------------------------------------
# app/routers/wallet.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/routers/wallet.py' @'
"""Rider wallet view and the QR pass.

Linked to: ledger (balance, history), security (create_pass_token), models.
The QR pass is a signed token that expires in minutes, so a screenshot is useless.
"""
from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import ledger
from ..db import get_db
from ..models import Rider, Station, Trip
from ..security import create_pass_token, current_rider

router = APIRouter(tags=["wallet"])


@router.get("/wallet")
def wallet(rider: Rider = Depends(current_rider), db: Session = Depends(get_db)):
    entries = ledger.history(db, rider.id)
    trip_ids = [e.ref for e in entries if e.kind == "fare"]
    trips = {t.id: t for t in db.scalars(select(Trip).where(Trip.id.in_(trip_ids)))} if trip_ids else {}
    stations = {s.id: s.name for s in db.scalars(select(Station))}
    items = []
    for e in entries:
        label = "M-Pesa top-up" if e.kind == "topup" else e.kind.capitalize()
        if e.kind == "fare" and e.ref in trips:
            label = f"Fare from {stations.get(trips[e.ref].station_id, 'station')}"
        items.append({"label": label, "amount": e.amount, "at": e.created_at.isoformat() + "Z", "ref": e.ref})
    return {"name": rider.name, "phone": rider.phone, "balance": ledger.balance(db, rider.id), "history": items}


@router.get("/pass")
def qr_pass(rider: Rider = Depends(current_rider)):
    token, ttl = create_pass_token(rider.id)
    return {"token": token, "expires_in": ttl}
'@
$script:count++

# ---------------------------------------------------------------------------
# app/schemas.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/schemas.py' @'
"""Request bodies (pydantic). Responses are plain dicts to keep the MVP small.

Linked to: routers/*. Phone numbers are normalised through mpesa.normalize_phone.
"""
import re
from datetime import datetime

from pydantic import BaseModel, Field, field_validator

from .mpesa import normalize_phone


class _PhoneMixin(BaseModel):
    phone: str

    @field_validator("phone")
    @classmethod
    def _phone(cls, v: str) -> str:
        return normalize_phone(v)


class RegisterIn(_PhoneMixin):
    name: str = Field(min_length=2, max_length=80)
    pin: str

    @field_validator("pin")
    @classmethod
    def _pin(cls, v: str) -> str:
        if not re.fullmatch(r"\d{4,8}", v):
            raise ValueError("PIN must be 4 to 8 digits.")
        return v


class LoginIn(_PhoneMixin):
    pin: str


class OperatorLoginIn(BaseModel):
    username: str
    password: str


class TopupIn(BaseModel):
    amount: int = Field(gt=0)
    phone: str | None = None

    @field_validator("phone")
    @classmethod
    def _phone(cls, v):
        return normalize_phone(v) if v else None


class TapIn(BaseModel):
    tap_id: str = Field(min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    pass_token: str = Field(min_length=20, max_length=2000)
    tapped_at: datetime


class SyncIn(BaseModel):
    taps: list[TapIn] = Field(max_length=500)
'@
$script:count++

# ---------------------------------------------------------------------------
# app/security.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/security.py' @'
"""Password hashing, JWTs (login tokens and QR passes) and auth dependencies.

Linked to: routers/* (Depends), trips (decode_pass_token), seed (hash_secret).
Two kinds of signed token exist, told apart by the `typ` claim:
  access - proves who is logged in (rider or operator), lasts hours
  pass   - the short-lived QR code a rider shows at a validator, lasts minutes
Validators do not log in; they send their device key in the X-Validator-Key header.
"""
import hashlib
import hmac
import secrets
from datetime import timedelta

import jwt
from fastapi import Depends, Header, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import settings
from .db import get_db
from .models import Operator, Rider, Validator
from .timeutil import utcnow

ALGO = "HS256"
bearer = HTTPBearer(auto_error=False)


# ---- passwords / PINs -------------------------------------------------------
def hash_secret(secret: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", secret.encode(), bytes.fromhex(salt), 120_000)
    return f"pbkdf2_sha256${salt}${digest.hex()}"


def verify_secret(secret: str, stored: str) -> bool:
    try:
        _, salt, expected = stored.split("$")
        digest = hashlib.pbkdf2_hmac("sha256", secret.encode(), bytes.fromhex(salt), 120_000)
    except ValueError:
        return False
    return hmac.compare_digest(digest.hex(), expected)


# ---- tokens -----------------------------------------------------------------
def _epoch(dt) -> int:
    from datetime import timezone

    return int(dt.replace(tzinfo=timezone.utc).timestamp())


def create_access_token(subject: int, role: str) -> str:
    now = utcnow()
    payload = {
        "sub": str(subject),
        "role": role,
        "typ": "access",
        "iat": _epoch(now),
        "exp": _epoch(now + timedelta(hours=settings.access_token_hours)),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=ALGO)


def create_pass_token(rider_id: int) -> tuple[str, int]:
    now = utcnow()
    ttl = settings.pass_ttl_seconds
    payload = {
        "sub": str(rider_id),
        "typ": "pass",
        "jti": secrets.token_hex(8),
        "iat": _epoch(now),
        "exp": _epoch(now + timedelta(seconds=ttl)),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=ALGO), ttl


def decode_pass_token(token: str) -> dict:
    """Verify the signature but NOT the expiry.

    Offline taps are synced later, so 'now' is the wrong clock. The caller checks
    that the tap time falls inside the pass's own validity window instead.
    Raises jwt.PyJWTError when the token is forged or is not a pass.
    """
    claims = jwt.decode(
        token,
        settings.jwt_secret,
        algorithms=[ALGO],
        options={"verify_exp": False, "require": ["sub", "jti", "iat", "exp"]},
    )
    if claims.get("typ") != "pass":
        raise jwt.InvalidTokenError("not a pass token")
    return claims


def _access_claims(creds: HTTPAuthorizationCredentials | None) -> dict:
    if creds is None:
        raise HTTPException(401, "Sign in first.")
    try:
        claims = jwt.decode(creds.credentials, settings.jwt_secret, algorithms=[ALGO])
    except jwt.PyJWTError:
        raise HTTPException(401, "Your session expired. Sign in again.")
    if claims.get("typ") != "access":
        raise HTTPException(401, "Invalid session token.")
    return claims


# ---- FastAPI dependencies -----------------------------------------------------
def current_rider(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer), db: Session = Depends(get_db)
) -> Rider:
    claims = _access_claims(creds)
    rider = db.get(Rider, int(claims["sub"])) if claims.get("role") == "rider" else None
    if rider is None:
        raise HTTPException(403, "Rider access only.")
    return rider


def current_operator(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer), db: Session = Depends(get_db)
) -> Operator:
    claims = _access_claims(creds)
    operator = db.get(Operator, int(claims["sub"])) if claims.get("role") == "operator" else None
    if operator is None:
        raise HTTPException(403, "Operator access only.")
    return operator


def current_validator(
    x_validator_key: str | None = Header(default=None), db: Session = Depends(get_db)
) -> Validator:
    if not x_validator_key:
        raise HTTPException(401, "Missing X-Validator-Key header.")
    validator = db.scalar(select(Validator).where(Validator.api_key == x_validator_key))
    if validator is None:
        raise HTTPException(401, "Unknown validator key.")
    return validator
'@
$script:count++

# ---------------------------------------------------------------------------
# app/seed.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/seed.py' @'
"""Demo data. Run:  python -m app.seed [--history] [--reset]

Linked to: models, ledger, security (hash_secret), db. main.py calls ensure_demo()
on start-up when AUTO_SEED=1.

  core     2 operators, 6 boarding points, 2 validators, 1 demo rider (safe to repeat)
  history  40 simulated riders and 14 days of commuter trips with injected
           anomalies, so the dashboard charts and the fraud model have something to show

All names, stations and fares are DEMO values, not official Kenya Railways data.
Demo logins are printed at the end. Change or remove them before any public deployment.
"""
import random
import sys
import uuid
from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import ledger
from .config import settings
from .db import Base, SessionLocal, engine, init_db
from .models import Operator, Rider, Station, Trip, Validator
from .security import hash_secret
from .timeutil import utcnow

DEMO_RIDER = {"phone": "254712345678", "name": "Demo Rider", "pin": "1234"}
DEMO_OPERATORS = [
    {"name": "Demo Commuter Rail", "username": "rail", "password": "demo1234"},
    {"name": "Demo Feeder Sacco", "username": "sacco", "password": "demo1234"},
]
# (name, fare KES, operator index)
DEMO_STATIONS = [
    ("Nairobi Central", 50, 0),
    ("Makadara", 50, 0),
    ("Githurai", 60, 0),
    ("Ruiru", 70, 0),
    ("Thika", 80, 0),
    ("Githurai Matatu Stage", 30, 1),
]
DEMO_VALIDATORS = [
    {"name": "Rail gate 1 (Nairobi Central)", "api_key": "demo-validator-key-1", "station": 0, "operator": 0},
    {"name": "Feeder matatu 1 (Githurai stage)", "api_key": "demo-validator-key-2", "station": 5, "operator": 1},
]


def seed_core(db: Session) -> bool:
    if db.scalar(select(Operator.id).limit(1)):
        return False
    ops = []
    for o in DEMO_OPERATORS:
        op = Operator(name=o["name"], username=o["username"], password_hash=hash_secret(o["password"]))
        db.add(op)
        ops.append(op)
    db.flush()
    stations = []
    for i, (name, fare, _) in enumerate(DEMO_STATIONS):
        st = Station(name=name, order_index=i, fare=fare)
        db.add(st)
        stations.append(st)
    db.flush()
    for v in DEMO_VALIDATORS:
        db.add(
            Validator(
                name=v["name"],
                api_key=v["api_key"],
                operator_id=ops[v["operator"]].id,
                station_id=stations[v["station"]].id,
            )
        )
    rider = Rider(phone=DEMO_RIDER["phone"], name=DEMO_RIDER["name"], pin_hash=hash_secret(DEMO_RIDER["pin"]))
    db.add(rider)
    db.flush()
    ledger.post(db, rider.id, 500, "topup", "SEED-DEMO-TOPUP")
    db.commit()
    return True


def seed_history(db: Session, riders: int = 40, days: int = 14, seed: int = 7) -> dict:
    rng = random.Random(seed)
    rail = db.scalar(select(Operator).where(Operator.username == "rail"))
    stations = list(db.scalars(select(Station).where(Station.id.in_(range(1, 6))).order_by(Station.order_index)))
    validators = {v.station_id: v for v in db.scalars(select(Validator))}
    if rail is None or len(stations) < 5:
        raise RuntimeError("Run seed_core first.")
    pin_hash = hash_secret("0000")  # one hash reused: demo riders all use PIN 0000
    now = utcnow()
    offset = timedelta(hours=settings.local_utc_offset_hours)
    made, anomalies = 0, 0

    def add_trip(rider: Rider, station: Station, when, charge: bool = True) -> Trip:
        trip = Trip(
            id=uuid.uuid4().hex,
            rider_id=rider.id,
            validator_id=None,
            station_id=station.id,
            operator_id=rail.id,
            pass_jti="seed-" + uuid.uuid4().hex[:12],
            tapped_at=when,
            received_at=when,
            fare=station.fare if charge else 0,
            status="charged" if charge else "declined",
            reason=None if charge else "insufficient_funds",
        )
        db.add(trip)
        db.flush()
        if charge:
            ledger.post(db, rider.id, -station.fare, "fare", trip.id)
        return trip

    for n in range(riders):
        rider = Rider(phone=f"2547000{n:05d}", name=f"Sim Rider {n + 1}", pin_hash=pin_hash)
        db.add(rider)
        db.flush()
        ledger.post(db, rider.id, 4000, "topup", f"SEED-TOPUP-{rider.id}")
        home, work = rng.sample(stations, 2)
        for d in range(days, -1, -1):  # d=0 is today (only trips already in the past)
            day_local = (now + offset - timedelta(days=d)).replace(hour=0, minute=0, second=0, microsecond=0)
            if day_local.weekday() >= 5 and rng.random() < 0.8:
                continue  # few weekend trips
            for station, hour_mu in ((home, 7.2), (work, 17.8)):
                if rng.random() < 0.15:
                    continue
                hour = min(max(rng.gauss(hour_mu, 0.7), 5.0), 22.0)
                when = day_local + timedelta(hours=hour) - offset  # back to UTC
                if when > now:
                    continue
                add_trip(rider, station, when)
                made += 1

    # injected anomalies the rules and the model should surface
    victims = list(db.scalars(select(Rider).where(Rider.phone.like("2547000%")).limit(6)))
    for i, rider in enumerate(victims):
        base = now - timedelta(days=rng.randint(1, 5), hours=rng.randint(0, 3))
        if i % 3 == 0:  # same rider, same station, seconds apart
            add_trip(rider, stations[0], base)
            add_trip(rider, stations[0], base + timedelta(seconds=25))
        elif i % 3 == 1:  # two different stations a minute apart
            add_trip(rider, stations[1], base)
            add_trip(rider, stations[4], base + timedelta(seconds=70))
        else:  # burst: many taps in half an hour
            for k in range(6):
                add_trip(rider, stations[2], base + timedelta(minutes=5 * k))
        anomalies += 1
    db.commit()
    return {"riders": riders, "normal_trips": made, "anomaly_groups": anomalies}


def ensure_demo() -> bool:
    init_db()
    with SessionLocal() as db:
        return seed_core(db)


def main(argv: list[str]) -> None:
    if "--reset" in argv:
        Base.metadata.drop_all(engine)
    init_db()
    with SessionLocal() as db:
        created = seed_core(db)
        print("Core demo data created." if created else "Core demo data already present.")
        if "--history" in argv:
            if db.scalar(select(Rider.id).where(Rider.phone.like("2547000%")).limit(1)):
                print("History already present. Use --reset to rebuild.")
            else:
                print("History:", seed_history(db))
    print("\nDemo logins")
    print("  Rider      phone 0712345678   PIN 1234")
    print("  Operator   rail / demo1234    (also: sacco / demo1234)")
    print("  Validator  key demo-validator-key-1 (Nairobi Central), demo-validator-key-2 (feeder)")


if __name__ == "__main__":
    main(sys.argv[1:])
'@
$script:count++

# ---------------------------------------------------------------------------
# app/timeutil.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/timeutil.py' @'
"""Time helpers. The database stores naive UTC datetimes everywhere.

Linked to: models (defaults), trips, analytics, fraud, payouts, routers.
"""
from datetime import datetime, timezone


def utcnow() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None)


def to_naive_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt
    return dt.astimezone(timezone.utc).replace(tzinfo=None)


def from_epoch(seconds: int) -> datetime:
    return datetime.fromtimestamp(seconds, timezone.utc).replace(tzinfo=None)
'@
$script:count++

# ---------------------------------------------------------------------------
# app/trips.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/trips.py' @'
"""Tap processing: turns a scanned QR pass into a charged, declined or rejected trip.

Linked to: security (decode_pass_token), ledger (fare debit), models,
routers/taps (calls process_tap for each offline tap), fraud (reads trips).

Order of checks for every tap:
  1. Already seen this tap_id?          -> return the stored result (idempotent sync)
  2. Pass signature valid?              -> else rejected / invalid_pass
  3. Tap time inside the pass window?   -> else rejected / stale_pass
  4. Same pass already used?            -> else rejected / replayed_pass
  5. Rider exists?                      -> else rejected / unknown_rider
  6. Balance minus fare above overdraft -> else declined / insufficient_funds
  7. Otherwise charged: one negative ledger row, reference = tap_id
"""
from datetime import datetime, timedelta

import jwt
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import ledger
from .config import settings
from .models import Rider, Station, Trip, Validator
from .security import decode_pass_token
from .timeutil import from_epoch, utcnow


def _result(trip: Trip, duplicate: bool, balance: int | None) -> dict:
    return {
        "tap_id": trip.id,
        "status": trip.status,
        "reason": trip.reason,
        "fare": trip.fare,
        "duplicate": duplicate,
        "balance": balance,
    }


def process_tap(db: Session, validator: Validator, tap_id: str, pass_token: str, tapped_at: datetime) -> dict:
    existing = db.get(Trip, tap_id)
    if existing is not None:
        bal = ledger.balance(db, existing.rider_id) if existing.rider_id else None
        return _result(existing, True, bal)

    station = db.get(Station, validator.station_id)
    trip = Trip(
        id=tap_id,
        validator_id=validator.id,
        station_id=validator.station_id,
        operator_id=validator.operator_id,
        tapped_at=tapped_at,
        received_at=utcnow(),
        fare=0,
        status="rejected",
    )
    reason: str | None = None
    rider: Rider | None = None

    try:
        claims = decode_pass_token(pass_token)
    except jwt.PyJWTError:
        claims = None
        reason = "invalid_pass"

    if claims is not None:
        trip.pass_jti = claims["jti"]
        rider = db.get(Rider, int(claims["sub"]))
        trip.rider_id = rider.id if rider else None
        window = timedelta(seconds=settings.tap_tolerance_seconds)
        valid_from, valid_to = from_epoch(claims["iat"]) - window, from_epoch(claims["exp"]) + window
        if not (valid_from <= tapped_at <= valid_to):
            reason = "stale_pass"
        elif db.scalar(select(Trip.id).where(Trip.pass_jti == claims["jti"], Trip.id != tap_id).limit(1)):
            reason = "replayed_pass"
        elif rider is None:
            reason = "unknown_rider"

    if reason is not None:
        trip.reason = reason
    else:
        fare = station.fare
        current = ledger.balance(db, rider.id)
        if current - fare < -settings.overdraft_limit:
            trip.status, trip.reason = "declined", "insufficient_funds"
        else:
            trip.status, trip.fare = "charged", fare
            ledger.post(db, rider.id, -fare, "fare", tap_id)

    db.add(trip)
    db.flush()
    bal = ledger.balance(db, rider.id) if rider else None
    return _result(trip, False, bal)
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
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Transit Link</title>
  <link rel="stylesheet" href="shared/style.css">
</head>
<body>
  <main class="shell">
    <header class="top"><div class="brand">Transit Link</div></header>
    <h1>One account for every ride.</h1>
    <p class="muted">MVP showcase. Pick the screen you want to demo.</p>
    <nav class="choices" aria-label="Apps">
      <a class="choice" href="rider/"><div class="card"><h2>Rider app</h2><p class="muted">Top up with M-Pesa, show the QR pass, see trips.</p></div></a>
      <a class="choice" href="validator/"><div class="card"><h2>Validator</h2><p class="muted">Scan passes at the gate. Keeps working offline.</p></div></a>
      <a class="choice" href="operator/"><div class="card"><h2>Operator dashboard</h2><p class="muted">Revenue, demand, suspicious trips and payouts.</p></div></a>
    </nav>
    <p class="muted" style="margin-top:18px">Demo data only. API docs: <a href="/docs">/docs</a></p>
  </main>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/operator/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/operator/app.js' @'
/* Operator dashboard. Talks to: POST /auth/operator/login, GET /operator/summary,
   GET /operator/flags, GET|POST /operator/payouts. Charts are inline SVG (no library). */
const TOKEN_KEY = 'tl_operator_token';
let token = localStorage.getItem(TOKEN_KEY);
let timer = null;

const REASON_TEXT = {
  double_tap: 'Charged twice at one point within 2 minutes',
  impossible_travel: 'Tapped at two different points within 5 minutes',
  rapid_burst: '4 or more trips in one hour',
  model_outlier: 'Unusual pattern (anomaly model)',
};

/* ---------- tiny SVG bar chart; colours come from CSS variables so dark mode works ---------- */
function barChart(el, labels, values, highlight) {
  const W = 480, H = 220, padL = 36, padB = 26, padT = 10;
  const max = Math.max(1, ...values);
  const bw = (W - padL) / values.length;
  let svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" width="100%" height="100%" role="img">';
  [0, 0.5, 1].forEach(f => {
    const y = padT + (H - padT - padB) * (1 - f);
    svg += '<line x1="' + padL + '" x2="' + W + '" y1="' + y + '" y2="' + y + '" stroke="var(--line)" stroke-width="1"/>';
    svg += '<text x="' + (padL - 6) + '" y="' + (y + 4) + '" text-anchor="end" font-size="11" fill="var(--ink-soft)">' + Math.round(max * f) + '</text>';
  });
  values.forEach((v, i) => {
    const h = (H - padT - padB) * (v / max);
    const x = padL + i * bw + bw * 0.15;
    const y = H - padB - h;
    const hot = highlight && highlight.includes(i);
    svg += '<rect x="' + x + '" y="' + y + '" width="' + bw * 0.7 + '" height="' + Math.max(h, 0) + '" rx="3" fill="' + (hot ? 'var(--amber)' : 'var(--signal)') + '"><title>' + labels[i] + ': ' + v + '</title></rect>';
    if (labels.length <= 8 || i % 3 === 0) {
      svg += '<text x="' + (x + bw * 0.35) + '" y="' + (H - 8) + '" text-anchor="middle" font-size="11" fill="var(--ink-soft)">' + labels[i] + '</text>';
    }
  });
  el.innerHTML = svg + '</svg>';
}

function cell(text, cls) {
  const td = document.createElement('td');
  td.textContent = text;
  if (cls) td.className = cls;
  return td;
}

function fill(tbody, rows) {
  tbody.innerHTML = '';
  rows.forEach(cells => {
    const tr = document.createElement('tr');
    cells.forEach(c => tr.appendChild(c));
    tbody.appendChild(tr);
  });
}

async function load() {
  try {
    const [s, f, p] = await Promise.all([
      api('/operator/summary', { token }),
      api('/operator/flags', { token }),
      api('/operator/payouts', { token }),
    ]);
    $('op-name').textContent = '· ' + s.operator;
    $('k-rev').textContent = kes(s.today.revenue);
    $('k-trips').textContent = kes(s.today.trips);
    $('k-riders').textContent = kes(s.today.riders);
    $('k-unpaid').textContent = kes(s.unpaid_revenue);

    barChart($('chart-daily'), s.daily.map(d => d.date.slice(5)), s.daily.map(d => d.revenue));
    barChart($('chart-hourly'), s.hourly_profile.map((_, h) => String(h)), s.hourly_profile, s.forecast_peak_hours);
    $('peaks').textContent = s.forecast_peak_hours.length
      ? 'Expect the busiest hours around ' + s.forecast_peak_hours.map(h => String(h).padStart(2, '0') + ':00').join(', ') + ' (Nairobi time, highlighted).'
      : 'Not enough trips yet to show a pattern.';

    fill($('stations'), s.by_station.map(r => [cell(r.station), cell(kes(r.trips), 'num'), cell(kes(r.revenue), 'num')]));
    fill($('payouts'), p.payouts.map(x => [cell(when(x.created_at)), cell(x.trips, 'num'), cell(kes(x.gross), 'num'), cell(kes(x.fee), 'num'), cell(kes(x.net), 'num')]));

    fill($('flags'), f.flags.slice(0, 40).map(x => {
      const why = document.createElement('td');
      x.reasons.forEach(r => {
        const t = document.createElement('span');
        t.className = 'tag';
        t.textContent = REASON_TEXT[r] || r;
        why.appendChild(t);
      });
      return [cell(when(x.tapped_at)), cell('#' + x.rider_id), cell(x.station), why];
    }));
    show($('flags-empty'), f.flags.length === 0);
  } catch (err) {
    if (err.status === 401 || err.status === 403) signOut();
  }
}

$('payout-btn').onclick = async () => {
  try {
    const p = await api('/operator/payouts/run', { method: 'POST', token });
    say($('payout-msg'), 'Simulated payout of KES ' + kes(p.net) + ' for ' + p.trips + ' trips (fee KES ' + kes(p.fee) + '). No real money moved.', 'ok');
    load();
  } catch (err) {
    say($('payout-msg'), err.message, 'err');
  }
};

$('login-form').onsubmit = async (e) => {
  e.preventDefault();
  try {
    const res = await api('/auth/operator/login', { method: 'POST', body: { username: $('user').value, password: $('pass').value } });
    token = res.token;
    localStorage.setItem(TOKEN_KEY, token);
    $('pass').value = '';
    enter();
  } catch (err) {
    say($('login-msg'), err.message, 'err');
  }
};

function signOut() {
  token = null;
  localStorage.removeItem(TOKEN_KEY);
  clearInterval(timer);
  show($('dash'), false);
  show($('login'), true);
  show($('logout'), false);
  $('op-name').textContent = '';
}
$('logout').onclick = signOut;

function enter() {
  show($('login'), false);
  show($('dash'), true);
  show($('logout'), true);
  load();
  clearInterval(timer);
  timer = setInterval(() => { if (!document.hidden) load(); }, 15000);
}

if (token) enter();
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
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Transit Link · Operator</title>
  <link rel="stylesheet" href="../shared/style.css">
</head>
<body>
  <main class="shell wide">
    <header class="top">
      <div class="brand">Transit Link <span class="muted" id="op-name"></span></div>
      <button id="logout" class="ghost hidden" type="button">Sign out</button>
    </header>

    <section id="login" class="card" style="max-width:420px">
      <h2>Operator sign in</h2>
      <form id="login-form" class="stack">
        <div><label for="user">Username</label><input id="user" autocomplete="username"></div>
        <div><label for="pass">Password</label><input id="pass" type="password" autocomplete="current-password"></div>
        <button type="submit">Sign in</button>
        <div id="login-msg" class="msg hidden" role="alert"></div>
        <p class="muted">Demo: rail / demo1234 or sacco / demo1234.</p>
      </form>
    </section>

    <section id="dash" class="hidden">
      <div class="grid cols4" style="margin-bottom:14px">
        <div class="card kpi"><div class="muted">Revenue today (KES)</div><div class="v" id="k-rev">0</div></div>
        <div class="card kpi"><div class="muted">Trips today</div><div class="v" id="k-trips">0</div></div>
        <div class="card kpi"><div class="muted">Riders today</div><div class="v" id="k-riders">0</div></div>
        <div class="card kpi"><div class="muted">Unpaid to operator (KES)</div><div class="v" id="k-unpaid">0</div></div>
      </div>

      <div class="grid cols2">
        <div class="card"><h2>Revenue, last 7 days (KES)</h2><div id="chart-daily" class="canvas-box"></div></div>
        <div class="card">
          <h2>Typical demand by hour of day</h2>
          <div id="chart-hourly" class="canvas-box"></div>
          <p class="muted" id="peaks"></p>
        </div>
      </div>

      <div class="grid cols2" style="margin-top:14px">
        <div class="card"><h2>Trips by boarding point</h2><table><thead><tr><th>Point</th><th class="num">Trips</th><th class="num">KES</th></tr></thead><tbody id="stations"></tbody></table></div>
        <div class="card">
          <div class="row spread"><h2>Payouts (simulated)</h2><button id="payout-btn" type="button">Run payout</button></div>
          <div id="payout-msg" class="msg hidden" role="status"></div>
          <table style="margin-top:8px"><thead><tr><th>When</th><th class="num">Trips</th><th class="num">Gross</th><th class="num">Fee</th><th class="num">Net</th></tr></thead><tbody id="payouts"></tbody></table>
        </div>
      </div>

      <div class="card" style="margin-top:14px">
        <h2>Suspicious trips</h2>
        <p class="muted">Leads to review, not verdicts. Found by simple rules plus an anomaly model.</p>
        <div style="overflow-x:auto">
          <table><thead><tr><th>When</th><th>Rider</th><th>Point</th><th>Why flagged</th></tr></thead><tbody id="flags"></tbody></table>
        </div>
        <p id="flags-empty" class="muted hidden">Nothing suspicious in the last 14 days.</p>
      </div>
    </section>
  </main>
  <script src="../shared/api.js"></script>
  <script src="app.js"></script>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/rider/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/rider/app.js' @'
/* Rider app: sign in, balance, QR pass, M-Pesa top-up, history.
   Talks to: POST /auth/register|login, GET /wallet, GET /pass, POST /topups,
   GET /topups/{id}, POST /dev/mpesa/confirm/{checkout_request_id} (mock mode only). */
const TOKEN_KEY = 'tl_rider_token';
let token = localStorage.getItem(TOKEN_KEY);
let mode = 'login';
let qr = null;
let passTimer = null;
let pollTimer = null;
let currentTopup = null;

/* ---------- auth ---------- */
function setMode(next) {
  mode = next;
  $('tab-login').classList.toggle('off', next !== 'login');
  $('tab-register').classList.toggle('off', next !== 'register');
  show($('name-wrap'), next === 'register');
  $('auth-submit').textContent = next === 'login' ? 'Sign in' : 'Create account';
  $('pin').autocomplete = next === 'login' ? 'current-password' : 'new-password';
  say($('auth-msg'), '');
}

$('tab-login').onclick = () => setMode('login');
$('tab-register').onclick = () => setMode('register');

$('auth-form').onsubmit = async (e) => {
  e.preventDefault();
  const btn = $('auth-submit');
  btn.disabled = true;
  try {
    const body = { phone: $('phone').value, pin: $('pin').value };
    if (mode === 'register') body.name = $('name').value;
    const res = await api(mode === 'login' ? '/auth/login' : '/auth/register', { method: 'POST', body });
    token = res.token;
    localStorage.setItem(TOKEN_KEY, token);
    $('pin').value = '';
    await enter();
  } catch (err) {
    say($('auth-msg'), err.message, 'err');
  } finally {
    btn.disabled = false;
  }
};

function signOut() {
  token = null;
  localStorage.removeItem(TOKEN_KEY);
  clearInterval(passTimer);
  clearInterval(pollTimer);
  show($('home'), false);
  show($('auth'), true);
  show($('logout'), false);
}
$('logout').onclick = signOut;

/* ---------- wallet ---------- */
async function loadWallet() {
  const w = await api('/wallet', { token });
  $('who').textContent = w.name;
  const bal = $('balance');
  bal.innerHTML = '<small>KES</small>' + kes(w.balance);
  bal.classList.toggle('neg', w.balance < 0);
  const list = $('history');
  list.innerHTML = '';
  w.history.forEach(h => {
    const li = document.createElement('li');
    const left = document.createElement('div');
    left.textContent = h.label;
    const when_ = document.createElement('div');
    when_.className = 'muted';
    when_.textContent = when(h.at);
    left.appendChild(when_);
    const amt = document.createElement('div');
    amt.className = 'amt' + (h.amount > 0 ? ' in' : '');
    amt.textContent = (h.amount > 0 ? '+' : '') + kes(h.amount);
    li.append(left, amt);
    list.appendChild(li);
  });
  show($('history-empty'), w.history.length === 0);
  return w;
}

/* ---------- QR pass: a signed token that expires in minutes ---------- */
async function refreshPass() {
  try {
    const p = await api('/pass', { token });
    if (!qr) {
      qr = new QRCode($('qr'), { text: p.token, width: 220, height: 220, correctLevel: QRCode.CorrectLevel.M });
    } else {
      qr.clear();
      qr.makeCode(p.token);
    }
    const bar = $('bar');
    bar.style.transition = 'none';
    bar.style.transform = 'scaleX(1)';
    void bar.offsetWidth;
    bar.style.transition = 'transform ' + Math.max(p.expires_in - 10, 10) + 's linear';
    bar.style.transform = 'scaleX(0)';
    $('pass-note').textContent = 'Show this code at the gate. It refreshes by itself.';
  } catch (err) {
    if (err.status === 401) return signOut();
    $('pass-note').textContent = 'Offline. Reconnect to refresh your pass.';
  }
}

/* ---------- top-up ---------- */
$('topup-form').onsubmit = async (e) => {
  e.preventDefault();
  const btn = $('topup-btn');
  btn.disabled = true;
  show($('confirm-btn'), false);
  try {
    const body = { amount: parseInt($('amount').value, 10) };
    if ($('topup-phone').value.trim()) body.phone = $('topup-phone').value;
    currentTopup = await api('/topups', { method: 'POST', body, token });
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
};

$('confirm-btn').onclick = async () => {
  try {
    const res = await api('/dev/mpesa/confirm/' + currentTopup.checkout_request_id, { method: 'POST', token });
    finishTopup(res);
  } catch (err) {
    say($('topup-msg'), err.message, 'err');
  }
};

function pollTopup() {
  clearInterval(pollTimer);
  let tries = 0;
  pollTimer = setInterval(async () => {
    tries += 1;
    try {
      const res = await api('/topups/' + currentTopup.id, { token });
      if (res.status !== 'pending') finishTopup(res);
    } catch (_) { /* keep trying */ }
    if (tries > 30) {
      clearInterval(pollTimer);
      say($('topup-msg'), 'Still waiting. If you paid, your balance will update shortly.');
    }
  }, 2000);
}

async function finishTopup(res) {
  clearInterval(pollTimer);
  show($('confirm-btn'), false);
  if (res.status === 'success') {
    say($('topup-msg'), 'Added KES ' + kes(res.amount) + '. M-Pesa receipt ' + res.receipt + '.', 'ok');
    await loadWallet();
  } else {
    say($('topup-msg'), 'Top-up did not go through' + (res.message ? ': ' + res.message : '.') + ' You were not charged.', 'err');
  }
}

/* ---------- start ---------- */
async function enter() {
  try {
    await loadWallet();
  } catch (err) {
    return signOut();
  }
  show($('auth'), false);
  show($('home'), true);
  show($('logout'), true);
  await refreshPass();
  clearInterval(passTimer);
  passTimer = setInterval(refreshPass, 60000);
}

if (token) enter(); else setMode('login');
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
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Transit Link · Rider</title>
  <meta name="theme-color" content="#0a7a55">
  <link rel="manifest" href="manifest.webmanifest">
  <link rel="stylesheet" href="../shared/style.css">
</head>
<body>
  <main class="shell">
    <header class="top">
      <div class="brand">Transit Link</div>
      <button id="logout" class="ghost hidden" type="button">Sign out</button>
    </header>

    <!-- Signed out -->
    <section id="auth" class="card">
      <div class="tabs" role="tablist">
        <button id="tab-login" type="button">Sign in</button>
        <button id="tab-register" type="button" class="off">Create account</button>
      </div>
      <form id="auth-form" class="stack" autocomplete="on">
        <div id="name-wrap" class="hidden"><label for="name">Your name</label><input id="name" autocomplete="name"></div>
        <div><label for="phone">M-Pesa phone number</label><input id="phone" inputmode="tel" autocomplete="tel" placeholder="0712 345 678"></div>
        <div><label for="pin">PIN (4 to 8 digits)</label><input id="pin" type="password" inputmode="numeric" autocomplete="current-password"></div>
        <button id="auth-submit" type="submit">Sign in</button>
        <div id="auth-msg" class="msg hidden" role="alert"></div>
        <p class="muted">Demo account: 0712 345 678, PIN 1234.</p>
      </form>
    </section>

    <!-- Signed in -->
    <section id="home" class="hidden">
      <div class="ticket">
        <div class="stub">
          <div class="muted" id="who"></div>
          <div class="balance" id="balance"><small>KES</small>0</div>
        </div>
        <div class="tear"></div>
        <div class="pass">
          <div id="qr" aria-label="Your QR pass"></div>
          <div class="bar"><i id="bar"></i></div>
          <p class="muted" style="margin-top:8px" id="pass-note">Show this code at the gate. It refreshes by itself.</p>
        </div>
      </div>

      <div class="card">
        <h2>Top up with M-Pesa</h2>
        <form id="topup-form" class="stack">
          <div class="row">
            <div class="grow"><label for="amount">Amount (KES)</label><input id="amount" inputmode="numeric" value="200"></div>
            <div class="grow"><label for="topup-phone">Pay from</label><input id="topup-phone" inputmode="tel" placeholder="Same as your account"></div>
          </div>
          <button id="topup-btn" type="submit">Send M-Pesa prompt</button>
          <button id="confirm-btn" type="button" class="ghost hidden">Approve on phone (simulated)</button>
          <div id="topup-msg" class="msg hidden" role="status"></div>
        </form>
      </div>

      <div class="card">
        <h2>Recent activity</h2>
        <ul id="history" class="list"></ul>
        <p id="history-empty" class="muted hidden">No activity yet. Top up to get started.</p>
      </div>
    </section>
  </main>

  <script src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js"></script>
  <script src="../shared/api.js"></script>
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
# web/shared/api.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/shared/api.js' @'
/* Tiny fetch wrapper and helpers shared by the three web apps. Plain script, no build step. */
const API = '/api';

async function api(path, { method = 'GET', body, token, headers = {} } = {}) {
  const h = { ...headers };
  if (body !== undefined) h['Content-Type'] = 'application/json';
  if (token) h['Authorization'] = 'Bearer ' + token;
  const res = await fetch(API + path, { method, headers: h, body: body !== undefined ? JSON.stringify(body) : undefined });
  let data = null;
  try { data = await res.json(); } catch (_) { /* empty body */ }
  if (!res.ok) {
    let detail = data && data.detail;
    if (Array.isArray(detail)) detail = detail.map(d => (d.msg || '').replace(/^Value error, /, '')).join(' ');
    const err = new Error(detail || 'Something went wrong (' + res.status + ').');
    err.status = res.status;
    throw err;
  }
  return data;
}

function kes(n) {
  const sign = n < 0 ? '-' : '';
  return sign + Math.abs(n).toLocaleString('en-KE');
}

function when(iso) {
  return new Date(iso).toLocaleString('en-KE', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

function $(id) { return document.getElementById(id); }

function show(el, on) { el.classList.toggle('hidden', !on); }

function say(el, text, kind) {
  el.textContent = text || '';
  el.className = 'msg' + (kind ? ' ' + kind : '');
  show(el, !!text);
}
'@
$script:count++

# ---------------------------------------------------------------------------
# web/shared/style.css
# ---------------------------------------------------------------------------
Write-BundleFile 'web/shared/style.css' @'
/* Transit Link shared styles. Palette is named after what you see on a platform. */
:root {
  --concrete: #e8ebe6;
  --paper: #fbfaf5;
  --ink: #15231d;
  --ink-soft: #52605a;
  --line: #cfd5cd;
  --signal: #0a7a55;
  --signal-ink: #ffffff;
  --amber: #b86a00;
  --stop: #b42318;
  --focus: #0b5cad;
  --radius: 10px;
  --num: ui-rounded, "SF Pro Rounded", "Segoe UI", system-ui, sans-serif;
}
@media (prefers-color-scheme: dark) {
  :root {
    --concrete: #111915;
    --paper: #1a2520;
    --ink: #e8efe9;
    --ink-soft: #9fb0a7;
    --line: #2d3b34;
    --signal: #34c18a;
    --signal-ink: #06231a;
    --amber: #f0a23b;
    --stop: #ff7b6e;
    --focus: #6db3ff;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0; background: var(--concrete); color: var(--ink);
  font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
h1, h2, h3 { line-height: 1.2; margin: 0 0 .5rem; letter-spacing: -.01em; }
h2 { font-size: 1.05rem; }
p { margin: 0 0 .75rem; }
.muted { color: var(--ink-soft); font-size: .9rem; }
.hidden { display: none !important; }
:focus-visible { outline: 3px solid var(--focus); outline-offset: 2px; }

.shell { max-width: 520px; margin: 0 auto; padding: 16px 16px 48px; }
.shell.wide { max-width: 1040px; }
.top { display: flex; align-items: center; justify-content: space-between; padding: 8px 0 16px; }
.brand { font-weight: 800; letter-spacing: -.02em; font-size: 1.1rem; }
.brand::before {
  content: ""; display: inline-block; width: 14px; height: 14px; margin-right: 8px;
  border-radius: 50%; background: var(--signal); box-shadow: 0 0 0 4px color-mix(in srgb, var(--signal) 25%, transparent);
  vertical-align: -1px;
}

.card { background: var(--paper); border: 1px solid var(--line); border-radius: var(--radius); padding: 16px; margin-bottom: 14px; }
.stack > * + * { margin-top: 10px; }
.row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
.row > .grow { flex: 1 1 140px; }
.spread { justify-content: space-between; }

label { display: block; font-size: .85rem; color: var(--ink-soft); margin-bottom: 4px; }
input, select, textarea {
  width: 100%; padding: 11px 12px; font: inherit; color: var(--ink); background: var(--concrete);
  border: 1px solid var(--line); border-radius: 8px;
}
textarea { min-height: 70px; resize: vertical; font-family: ui-monospace, Menlo, Consolas, monospace; font-size: .8rem; }
button {
  font: inherit; font-weight: 650; padding: 11px 16px; border-radius: 8px; cursor: pointer;
  border: 1px solid var(--signal); background: var(--signal); color: var(--signal-ink);
}
button:hover { filter: brightness(1.05); }
button:disabled { opacity: .5; cursor: not-allowed; }
button.ghost { background: transparent; color: var(--ink); border-color: var(--line); }
button.danger { background: var(--stop); border-color: var(--stop); color: #fff; }
.tabs { display: flex; gap: 6px; margin-bottom: 12px; }
.tabs button { flex: 1; }
.tabs button.off { background: transparent; color: var(--ink); border-color: var(--line); }

.msg { padding: 10px 12px; border-radius: 8px; font-size: .92rem; border: 1px solid var(--line); background: var(--concrete); }
.msg.err { border-color: var(--stop); color: var(--stop); }
.msg.ok { border-color: var(--signal); color: var(--signal); }

/* Rider: the ticket. A notch on each side and a dashed tear line separate balance from pass. */
.ticket { position: relative; background: var(--paper); border: 1px solid var(--line); border-radius: 14px; margin-bottom: 14px; overflow: hidden; }
.ticket .stub { padding: 18px 18px 16px; }
.ticket .tear { position: relative; border-top: 2px dashed var(--line); margin: 0 14px; }
.ticket .tear::before, .ticket .tear::after {
  content: ""; position: absolute; top: -13px; width: 24px; height: 24px; border-radius: 50%;
  background: var(--concrete); border: 1px solid var(--line);
}
.ticket .tear::before { left: -26px; }
.ticket .tear::after { right: -26px; }
.ticket .pass { padding: 16px 18px 20px; text-align: center; }
.balance { font-family: var(--num); font-variant-numeric: tabular-nums; font-size: 2.8rem; font-weight: 800; letter-spacing: -.03em; line-height: 1; }
.balance small { font-size: 1rem; font-weight: 650; color: var(--ink-soft); margin-right: 6px; letter-spacing: 0; }
.balance.neg { color: var(--amber); }
#qr { display: inline-block; padding: 12px; background: #fff; border-radius: 10px; line-height: 0; }
#qr img, #qr canvas { max-width: 100%; height: auto; }
.bar { height: 4px; background: var(--line); border-radius: 2px; margin: 12px auto 0; max-width: 220px; overflow: hidden; }
.bar > i { display: block; height: 100%; width: 100%; background: var(--signal); transform-origin: left; }
.list { list-style: none; margin: 0; padding: 0; }
.list li { display: flex; justify-content: space-between; gap: 12px; padding: 10px 0; border-top: 1px solid var(--line); }
.list li:first-child { border-top: 0; }
.amt { font-family: var(--num); font-variant-numeric: tabular-nums; font-weight: 700; white-space: nowrap; }
.amt.in { color: var(--signal); }

/* Validator: a signal lamp. Colour is the message; text repeats it for accessibility. */
.lamp { border-radius: 14px; padding: 22px 16px; text-align: center; border: 2px solid var(--line); background: var(--paper); }
.lamp h1 { font-size: 1.6rem; margin: 0 0 4px; }
.lamp.go { border-color: var(--signal); background: color-mix(in srgb, var(--signal) 14%, var(--paper)); }
.lamp.warn { border-color: var(--amber); background: color-mix(in srgb, var(--amber) 14%, var(--paper)); }
.lamp.stop { border-color: var(--stop); background: color-mix(in srgb, var(--stop) 14%, var(--paper)); }
.viewfinder { position: relative; border-radius: 12px; overflow: hidden; background: #000; aspect-ratio: 4 / 3; }
.viewfinder video { width: 100%; height: 100%; object-fit: cover; }
.pill { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: .8rem; font-weight: 650; border: 1px solid var(--line); }
.pill.on { border-color: var(--signal); color: var(--signal); }
.pill.off { border-color: var(--amber); color: var(--amber); }

/* Operator dashboard */
.grid { display: grid; gap: 14px; }
.grid.cols4 { grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); }
.grid.cols2 { grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); }
.kpi .v { font-family: var(--num); font-variant-numeric: tabular-nums; font-size: 1.9rem; font-weight: 800; letter-spacing: -.02em; }
table { width: 100%; border-collapse: collapse; font-size: .92rem; }
th, td { text-align: left; padding: 8px 6px; border-top: 1px solid var(--line); }
th { color: var(--ink-soft); font-weight: 600; border-top: 0; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.tag { display: inline-block; padding: 1px 8px; margin: 0 4px 2px 0; border-radius: 999px; font-size: .78rem; border: 1px solid var(--amber); color: var(--amber); }
.canvas-box { position: relative; height: 220px; }

/* Landing */
.choices { display: grid; gap: 12px; }
.choice { display: block; text-decoration: none; color: inherit; }
.choice .card { margin: 0; transition: border-color .15s; }
.choice:hover .card { border-color: var(--signal); }
.choice h2 { font-size: 1.15rem; }

@media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }
'@
$script:count++

# ---------------------------------------------------------------------------
# web/validator/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/validator/app.js' @'
/* Validator: scans rider QR passes, queues every tap on the device (IndexedDB),
   and syncs the queue to POST /taps/sync whenever a connection is available.
   The gate decision never waits for the network: a readable, unexpired pass is accepted
   and queued. The SERVER decides charge / decline / reject when the batch arrives. */
const KEY = 'tl_validator_key';
const CFG = 'tl_validator_cfg';
const STORE = 'taps';
let simulateOffline = false;
let syncing = false;
let stream = null;
let lastText = '';
let lastAt = 0;
const recent = []; // latest sync results, newest first

/* ---------- IndexedDB queue ---------- */
const dbp = new Promise((resolve, reject) => {
  const req = indexedDB.open('tl-validator', 1);
  req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: 'tap_id' });
  req.onsuccess = () => resolve(req.result);
  req.onerror = () => reject(req.error);
});
function putTap(tap) {
  return dbp.then(db => new Promise((res, rej) => {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).put(tap);
    tx.oncomplete = () => res();
    tx.onerror = () => rej(tx.error);
  }));
}
function allTaps() {
  return dbp.then(db => new Promise((res, rej) => {
    const req = db.transaction(STORE, 'readonly').objectStore(STORE).getAll();
    req.onsuccess = () => res(req.result);
    req.onerror = () => rej(req.error);
  }));
}
function deleteTaps(ids) {
  return dbp.then(db => new Promise((res, rej) => {
    const tx = db.transaction(STORE, 'readwrite');
    ids.forEach(id => tx.objectStore(STORE).delete(id));
    tx.oncomplete = () => res();
    tx.onerror = () => rej(tx.error);
  }));
}

/* ---------- small helpers ---------- */
function newId() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  return 'tap-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
}

/* Read the pass payload WITHOUT verifying the signature (the server verifies it). */
function readPass(text) {
  const parts = text.trim().split('.');
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const p = JSON.parse(atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4)));
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
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const o = ctx.createOscillator();
    o.frequency.value = ok ? 880 : 220;
    o.connect(ctx.destination);
    o.start();
    o.stop(ctx.currentTime + (ok ? 0.12 : 0.3));
  } catch (_) { /* sound is optional */ }
  if (navigator.vibrate) navigator.vibrate(ok ? 60 : [80, 60, 80]);
}

function isOnline() { return navigator.onLine && !simulateOffline; }

async function refreshStatus() {
  const pill = $('net-pill');
  pill.textContent = isOnline() ? 'Online' : 'Offline';
  pill.className = 'pill ' + (isOnline() ? 'on' : 'off');
  const n = (await allTaps()).length;
  $('queue-pill').textContent = n + ' waiting';
  $('queue-pill').className = 'pill' + (n ? ' off' : '');
}

/* ---------- setup ---------- */
async function connect(key) {
  const cfg = await api('/validator/config', { headers: { 'X-Validator-Key': key } });
  localStorage.setItem(KEY, key);
  localStorage.setItem(CFG, JSON.stringify(cfg));
  return cfg;
}

function showScan(cfg) {
  show($('setup'), false);
  show($('scan'), true);
  $('station').textContent = cfg.station;
  $('operator').textContent = cfg.operator + ' · ' + cfg.validator;
  $('fare').textContent = 'KES ' + kes(cfg.fare);
}

$('setup-form').onsubmit = async (e) => {
  e.preventDefault();
  try {
    showScan(await connect($('key').value.trim()));
    say($('setup-msg'), '');
    refreshStatus();
  } catch (err) {
    say($('setup-msg'), err.status === 401 ? 'That key is not recognised. Check it and try again.' : err.message, 'err');
  }
};

$('reset-btn').onclick = async () => {
  const waiting = (await allTaps()).length;
  if (waiting && !confirm(waiting + ' taps have not synced yet. Disconnecting keeps them on this device, but they cannot sync without the key. Continue?')) return;
  localStorage.removeItem(KEY);
  localStorage.removeItem(CFG);
  stopCamera();
  show($('scan'), false);
  show($('setup'), true);
};

/* ---------- accepting a scan ---------- */
async function onScan(text) {
  const now = Date.now();
  if (text === lastText && now - lastAt < 4000) return; // same code still in view
  lastText = text;
  lastAt = now;

  const pass = readPass(text);
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

$('manual-btn').onclick = async () => {
  const text = $('manual').value.trim();
  if (text) { await onScan(text); $('manual').value = ''; }
};

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
  const video = $('video');
  video.srcObject = stream;
  await video.play();
  $('cam-btn').textContent = 'Stop camera';
  tick();
}

function stopCamera() {
  if (stream) stream.getTracks().forEach(t => t.stop());
  stream = null;
  $('cam-btn').textContent = 'Start camera';
}

function tick() {
  if (!stream) return;
  const video = $('video');
  if (video.readyState === video.HAVE_ENOUGH_DATA && video.videoWidth) {
    const scale = Math.min(1, 640 / video.videoWidth);
    const canvas = $('canvas');
    canvas.width = Math.round(video.videoWidth * scale);
    canvas.height = Math.round(video.videoHeight * scale);
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const code = jsQR(img.data, img.width, img.height, { inversionAttempts: 'dontInvert' });
    if (code && code.data) onScan(code.data);
  }
  setTimeout(() => requestAnimationFrame(tick), 120);
}

$('cam-btn').onclick = () => (stream ? stopCamera() : startCamera());

/* ---------- sync ---------- */
const REASONS = {
  insufficient_funds: 'Balance too low',
  replayed_pass: 'Pass already used',
  stale_pass: 'Pass was not valid at that time',
  invalid_pass: 'Not a valid pass',
  unknown_rider: 'Unknown rider',
};

function renderLog() {
  const ul = $('log');
  ul.innerHTML = '';
  recent.slice(0, 8).forEach(r => {
    const li = document.createElement('li');
    const left = document.createElement('div');
    left.textContent = r.status === 'charged' ? 'Charged' : (r.status === 'declined' ? 'Declined' : 'Rejected');
    const sub = document.createElement('div');
    sub.className = 'muted';
    sub.textContent = r.reason ? (REASONS[r.reason] || r.reason) : 'Tap ' + r.tap_id.slice(0, 8);
    left.appendChild(sub);
    const right = document.createElement('div');
    right.className = 'amt';
    right.textContent = r.status === 'charged' ? 'KES ' + kes(r.fare) : '';
    li.append(left, right);
    ul.appendChild(li);
  });
  show($('log-empty'), recent.length === 0);
}

async function syncNow() {
  if (syncing || !isOnline()) return;
  const key = localStorage.getItem(KEY);
  if (!key) return;
  const queued = (await allTaps()).sort((a, b) => a.tapped_at.localeCompare(b.tapped_at)).slice(0, 200);
  if (!queued.length) return;
  syncing = true;
  try {
    const res = await api('/taps/sync', { method: 'POST', body: { taps: queued }, headers: { 'X-Validator-Key': key } });
    await deleteTaps(res.results.map(r => r.tap_id));
    res.results.forEach(r => recent.unshift(r));
    renderLog();
    const bad = res.results.find(r => r.status !== 'charged' && !r.duplicate);
    if (bad) lamp(bad.status === 'declined' ? 'warn' : 'stop', bad.status === 'declined' ? 'Declined after sync' : 'Rejected after sync', REASONS[bad.reason] || bad.reason);
    else lamp('go', 'Synced', res.results.length + ' tap(s) processed.');
  } catch (err) {
    if (err.status === 401) lamp('stop', 'Device key rejected', 'Disconnect and connect again.');
    /* network errors: keep the queue and retry later */
  } finally {
    syncing = false;
    refreshStatus();
  }
}

$('sync-btn').onclick = syncNow;
$('offline-sw').onchange = (e) => { simulateOffline = e.target.checked; refreshStatus(); if (isOnline()) syncNow(); };
window.addEventListener('online', () => { refreshStatus(); syncNow(); });
window.addEventListener('offline', refreshStatus);
setInterval(() => { refreshStatus(); syncNow(); }, 10000);

/* ---------- start ---------- */
if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});

(async () => {
  const key = localStorage.getItem(KEY);
  const cached = localStorage.getItem(CFG);
  if (key && cached) {
    showScan(JSON.parse(cached)); // works offline: station and fare come from the cache
    refreshStatus();
    syncNow();
    connect(key).then(showScan).catch(() => {}); // refresh the cache when online
  }
})();
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
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Transit Link · Validator</title>
  <meta name="theme-color" content="#0a7a55">
  <link rel="stylesheet" href="../shared/style.css">
</head>
<body>
  <main class="shell">
    <header class="top">
      <div class="brand">Validator</div>
      <div class="row">
        <span id="net-pill" class="pill on">Online</span>
        <span id="queue-pill" class="pill">0 waiting</span>
      </div>
    </header>

    <!-- Setup: one time per device -->
    <section id="setup" class="card">
      <h2>Connect this device</h2>
      <form id="setup-form" class="stack">
        <div><label for="key">Device key</label><input id="key" autocomplete="off" placeholder="demo-validator-key-1"></div>
        <button type="submit">Connect</button>
        <div id="setup-msg" class="msg hidden" role="alert"></div>
        <p class="muted">Keys are issued to each gate or vehicle. Demo keys: demo-validator-key-1 (rail), demo-validator-key-2 (feeder).</p>
      </form>
    </section>

    <!-- Scanning -->
    <section id="scan" class="hidden">
      <div class="card row spread">
        <div><strong id="station"></strong><div class="muted" id="operator"></div></div>
        <div class="amt" id="fare"></div>
      </div>

      <div id="lamp" class="lamp" role="status" aria-live="polite" style="margin-bottom:14px">
        <h1 id="lamp-title">Ready</h1>
        <div id="lamp-sub" class="muted">Start the camera and point it at a rider's QR code.</div>
      </div>

      <div class="card stack">
        <div class="viewfinder"><video id="video" playsinline muted></video></div>
        <canvas id="canvas" class="hidden"></canvas>
        <div class="row">
          <button id="cam-btn" type="button" class="grow">Start camera</button>
          <button id="sync-btn" type="button" class="ghost grow">Sync now</button>
        </div>
        <label class="row" style="margin:0"><input id="offline-sw" type="checkbox" style="width:auto"> Simulate offline (for demos)</label>
        <div id="cam-msg" class="msg hidden"></div>
      </div>

      <details class="card">
        <summary>No camera? Paste a pass</summary>
        <div class="stack" style="margin-top:10px">
          <textarea id="manual" placeholder="Paste the pass token from the rider app"></textarea>
          <button id="manual-btn" type="button">Add pass</button>
        </div>
      </details>

      <div class="card">
        <h2>Latest results</h2>
        <ul id="log" class="list"></ul>
        <p id="log-empty" class="muted">Nothing synced yet.</p>
      </div>
      <button id="reset-btn" class="ghost" type="button">Disconnect this device</button>
    </section>
  </main>

  <script src="https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js" crossorigin="anonymous"></script>
  <script src="../shared/api.js"></script>
  <script src="app.js"></script>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/validator/sw.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/validator/sw.js' @'
/* Service worker: lets the validator page open with no connection after the first visit.
   Strategy: network first, fall back to the cache. API calls are never intercepted. */
const CACHE = 'tl-validator-v1';
const ASSETS = [
  './',
  './app.js',
  '../shared/style.css',
  '../shared/api.js',
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

# ---------------------------------------------------------------------------
# tests/conftest.py
# ---------------------------------------------------------------------------
Write-BundleFile 'tests/conftest.py' @'
import os
import sys
import tempfile
from pathlib import Path

# Environment must be set BEFORE the app is imported.
_tmp = tempfile.mkdtemp()
os.environ["DATABASE_URL"] = f"sqlite:///{_tmp}/test.db"
os.environ["JWT_SECRET"] = "test-secret"
os.environ["MPESA_MODE"] = "mock"
os.environ["AUTO_SEED"] = "1"
os.environ["CALLBACK_SECRET"] = "cb-secret"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
'@
$script:count++

# ---------------------------------------------------------------------------
# tests/test_flow.py
# ---------------------------------------------------------------------------
Write-BundleFile 'tests/test_flow.py' @'
"""End-to-end tests of the MVP showcase flow. Run:  pytest -q"""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import app

KEY1 = {"X-Validator-Key": "demo-validator-key-1"}


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _iso(dt=None):
    return (dt or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z")


def _new_rider(client, phone, topup=0):
    r = client.post("/api/auth/register", json={"phone": phone, "name": "Test Rider", "pin": "4321"})
    assert r.status_code == 201, r.text
    token = r.json()["token"]
    if topup:
        t = client.post("/api/topups", json={"amount": topup}, headers=_auth(token)).json()
        done = client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token)).json()
        assert done["status"] == "success"
    return token


def _tap(client, token, tap_id, when=None):
    qr = client.get("/api/pass", headers=_auth(token)).json()["token"]
    body = {"taps": [{"tap_id": tap_id, "pass_token": qr, "tapped_at": _iso(when)}]}
    return client.post("/api/taps/sync", json=body, headers=KEY1).json()["results"][0], qr


def test_health_and_static(client):
    assert client.get("/api/health").json()["status"] == "ok"
    assert client.get("/rider/").status_code == 200
    assert client.get("/validator/").status_code == 200
    assert client.get("/operator/").status_code == 200


def test_register_login_validation(client):
    token = _new_rider(client, "0711000001")
    assert client.post("/api/auth/login", json={"phone": "0711000001", "pin": "4321"}).status_code == 200
    assert client.post("/api/auth/login", json={"phone": "0711000001", "pin": "0000"}).status_code == 401
    assert client.post("/api/auth/register", json={"phone": "0711000001", "name": "X Y", "pin": "4321"}).status_code == 409
    assert client.post("/api/auth/register", json={"phone": "12345", "name": "X Y", "pin": "4321"}).status_code == 422
    assert client.get("/api/wallet", headers=_auth(token)).json()["balance"] == 0


def test_topup_mock_flow_and_idempotency(client):
    token = _new_rider(client, "0711000002")
    t = client.post("/api/topups", json={"amount": 300}, headers=_auth(token)).json()
    assert t["status"] == "pending" and t["mode"] == "mock"
    client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token))
    client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token))  # twice
    assert client.get("/api/wallet", headers=_auth(token)).json()["balance"] == 300
    assert client.post("/api/topups", json={"amount": 5}, headers=_auth(token)).status_code == 422


def test_daraja_callback(client):
    token = _new_rider(client, "0711000003")
    t = client.post("/api/topups", json={"amount": 200}, headers=_auth(token)).json()
    payload = {
        "Body": {
            "stkCallback": {
                "MerchantRequestID": "x",
                "CheckoutRequestID": t["checkout_request_id"],
                "ResultCode": 0,
                "ResultDesc": "The service request is processed successfully.",
                "CallbackMetadata": {
                    "Item": [
                        {"Name": "Amount", "Value": 200},
                        {"Name": "MpesaReceiptNumber", "Value": "TESTRCPT01"},
                        {"Name": "PhoneNumber", "Value": 254711000003},
                    ]
                },
            }
        }
    }
    assert client.post("/api/mpesa/callback/wrong", json=payload).status_code == 404
    assert client.post("/api/mpesa/callback/cb-secret", json=payload).json()["ResultCode"] == 0
    client.post("/api/mpesa/callback/cb-secret", json=payload)  # Daraja may retry
    wallet = client.get("/api/wallet", headers=_auth(token)).json()
    assert wallet["balance"] == 200
    assert wallet["history"][0]["ref"] == "TESTRCPT01"


def test_tap_charges_once_and_sync_is_idempotent(client):
    token = _new_rider(client, "0711000004", topup=500)
    res, qr = _tap(client, token, "tap-aaaaaaaa-0001")
    assert res["status"] == "charged" and res["fare"] == 50 and res["balance"] == 450
    again = client.post(
        "/api/taps/sync",
        json={"taps": [{"tap_id": "tap-aaaaaaaa-0001", "pass_token": qr, "tapped_at": _iso()}]},
        headers=KEY1,
    ).json()["results"][0]
    assert again["duplicate"] is True and again["balance"] == 450


def test_replayed_pass_is_rejected(client):
    token = _new_rider(client, "0711000005", topup=500)
    first, qr = _tap(client, token, "tap-bbbbbbbb-0001")
    assert first["status"] == "charged"
    second = client.post(
        "/api/taps/sync",
        json={"taps": [{"tap_id": "tap-bbbbbbbb-0002", "pass_token": qr, "tapped_at": _iso()}]},
        headers=KEY1,
    ).json()["results"][0]
    assert second["status"] == "rejected" and second["reason"] == "replayed_pass"
    assert client.get("/api/wallet", headers=_auth(token)).json()["balance"] == 450


def test_stale_and_forged_passes(client):
    token = _new_rider(client, "0711000006", topup=500)
    old, _ = _tap(client, token, "tap-cccccccc-0001", when=datetime.now(timezone.utc) - timedelta(hours=3))
    assert old["status"] == "rejected" and old["reason"] == "stale_pass"
    forged = client.post(
        "/api/taps/sync",
        json={"taps": [{"tap_id": "tap-cccccccc-0002", "pass_token": "x" * 40, "tapped_at": _iso()}]},
        headers=KEY1,
    ).json()["results"][0]
    assert forged["reason"] == "invalid_pass"
    assert client.post("/api/taps/sync", json={"taps": []}).status_code == 401


def test_offline_overdraft_limit(client):
    token = _new_rider(client, "0711000007", topup=60)
    ok, _ = _tap(client, token, "tap-dddddddd-0001")  # 60 -> 10
    ok2, _ = _tap(client, token, "tap-dddddddd-0002")  # 10 -> -40, within the KES 50 overdraft
    no, _ = _tap(client, token, "tap-dddddddd-0003")  # -40 -> -90, beyond the limit
    assert (ok["status"], ok2["status"], no["status"]) == ("charged", "charged", "declined")
    assert no["reason"] == "insufficient_funds"
    assert client.get("/api/wallet", headers=_auth(token)).json()["balance"] == -40


def test_operator_summary_payout_and_scope(client):
    login = client.post("/api/auth/operator/login", json={"username": "rail", "password": "demo1234"})
    assert login.status_code == 200
    h = _auth(login.json()["token"])
    summary = client.get("/api/operator/summary", headers=h).json()
    assert summary["today"]["trips"] >= 1 and summary["unpaid_revenue"] > 0
    unpaid = summary["unpaid_revenue"]
    payout = client.post("/api/operator/payouts/run", headers=h).json()
    assert payout["gross"] == unpaid and payout["gross"] == payout["fee"] + payout["net"]
    assert client.post("/api/operator/payouts/run", headers=h).status_code == 409
    assert client.get("/api/operator/payouts", headers=h).json()["payouts"][0]["id"] == payout["id"]
    # a rider token must not open operator endpoints
    rider_token = _new_rider(client, "0711000008")
    assert client.get("/api/operator/summary", headers=_auth(rider_token)).status_code == 403


def test_fraud_flags_on_seeded_history(client):
    from app.db import SessionLocal
    from app.seed import seed_history

    with SessionLocal() as db:
        info = seed_history(db, riders=30, days=10)
    assert info["normal_trips"] > 100
    h = _auth(client.post("/api/auth/operator/login", json={"username": "rail", "password": "demo1234"}).json()["token"])
    flags = client.get("/api/operator/flags", headers=h).json()["flags"]
    reasons = {r for f in flags for r in f["reasons"]}
    assert {"double_tap", "impossible_travel", "rapid_burst"} <= reasons
    summary = client.get("/api/operator/summary", headers=h).json()
    assert len(summary["daily"]) == 7 and len(summary["hourly_profile"]) == 24
    assert summary["forecast_peak_hours"]
'@
$script:count++


Write-Host ""
Write-Host "Done. $($script:count) files written to $root" -ForegroundColor Green

if ($Setup -or $Run) {
    Push-Location $root
    try {
        $python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
        if (-not $python) { throw "Python 3.10+ was not found. Install it from python.org, then run this script again with -Setup." }
        Write-Host "Creating virtual environment..." -ForegroundColor Cyan
        & $python.Source -m venv .venv
        $venvPy = if ($isWin) { Join-Path $root ".venv\Scripts\python.exe" } else { Join-Path $root ".venv/bin/python" }
        Write-Host "Installing requirements (this can take a few minutes)..." -ForegroundColor Cyan
        & $venvPy -m pip install --quiet -r requirements.txt
        if (-not (Test-Path ".env")) { Copy-Item ".env.example" ".env" }
        Write-Host "Loading demo data..." -ForegroundColor Cyan
        & $venvPy -m app.seed --history
        if ($Run) {
            Write-Host "Starting http://localhost:8000  (Ctrl+C to stop)" -ForegroundColor Green
            & $venvPy -m uvicorn app.main:app --reload
        }
    }
    finally { Pop-Location }
}
else {
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  cd $Target"
    Write-Host "  python -m venv .venv ; .\.venv\Scripts\Activate.ps1"
    Write-Host "  pip install -r requirements.txt"
    Write-Host "  python -m app.seed --history"
    Write-Host "  uvicorn app.main:app --reload"
    Write-Host "Or re-run this script with -Run to do all of that for you. Start with docs/ARCHITECTURE.md."
}
