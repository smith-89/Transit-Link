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
| `GET /validator/config` | validator | Device, operator, station, `mode` (`distance` or `flat`) and the fare (the maximum for distance stations) |
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

## Distance fares: boarding and alighting

Each tap in `POST /taps/sync` has an optional `direction`: `"in"` (default, so older devices keep working) or `"out"`.

```json
{ "taps": [ { "tap_id": "9c1e...", "pass_token": "<jwt from QR>", "tapped_at": "2026-10-16T05:40:00.000Z", "direction": "out" } ] }
```

Each result adds `direction`, `refund`, `from_station` and `to_station`:

```json
{ "tap_id": "9c1e...", "direction": "out", "status": "settled", "reason": null, "fare": 45, "refund": 35,
  "duplicate": false, "balance": 455, "from_station": "Nairobi Central", "to_station": "Githurai" }
```

| Direction | Status | Meaning |
| --- | --- | --- |
| in | `open` | Maximum fare held, waiting for the exit scan |
| in | `charged` | Flat-fare stop: charged and final |
| in | `declined` / `rejected` | Balance too low, or the pass failed a check |
| out | `settled` | Exact fare found, difference refunded |
| out | `cancelled` | Exited at the boarding station: fully refunded |
| out | `orphan` | No boarding scan yet (reason `no_tap_in`); matched later if it arrives |
| out | `ignored` | Flat-fare stop, nothing to settle |
| out | `rejected` | Pass failed a check |

`GET /operator/summary` also returns `open_journeys`. `GET /wallet` entries now include `kind`
(`topup`, `fare` or `refund`). See `docs/FARES.md` for the rules.
