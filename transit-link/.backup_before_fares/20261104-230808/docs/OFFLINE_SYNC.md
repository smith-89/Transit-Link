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
