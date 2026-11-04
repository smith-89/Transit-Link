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
