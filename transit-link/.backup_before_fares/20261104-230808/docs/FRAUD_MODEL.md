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
