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
