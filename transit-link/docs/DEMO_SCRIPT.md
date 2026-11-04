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

## Distance fare demo (about 2 minutes)

Open two gate windows: sign in with device ID `demo-validator-key-1` (Nairobi Central) and `demo-validator-key-4`
(Githurai), leaving the passcode empty. Set the second gate to **Alighting**.

1. In the rider app (0712 345 678 / 1234), open the Pass tab and copy the token (or use the camera).
2. Gate 1 scans the pass: balance drops by 80 (the maximum is held).
3. Gate 2 scans the same pass: balance rises by 35. The fare was 45.
4. Rider Activity shows "Fare held from Nairobi Central" and "Refund: Nairobi Central to Githurai".
5. Try Thika as the exit (`demo-validator-key-6`): the fare is the full 80, no refund.
6. On the operator dashboard, "In journeys now" counts riders who have boarded but not left, and revenue rises
   only when journeys settle.

Other gates: `-3` Makadara, `-5` Ruiru, `-2` the flat-fare feeder stop (no Boarding/Alighting switch).
