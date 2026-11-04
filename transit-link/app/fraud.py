"""Suspicious-trip detection: transparent rules first, a small ML model second.

Linked to: routers/operator (GET /operator/flags), models, config.
Rules (explainable, always on):
  double_tap         same rider, same station, under 2 minutes after their last trip
  impossible_travel  same rider, DIFFERENT station, under 5 minutes after their last trip
  rapid_burst        4 or more trips by one rider inside an hour
  missed_tap_out     journey closed at the maximum fare because the rider never tapped out
  exit_without_entry an exit scan an hour or more old that no entry scan has matched
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
from .models import TapOut, Trip
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
ORPHAN_GRACE_MINUTES = 60
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
        if t.reason == "no_tap_out":
            reasons.append("missed_tap_out")

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
    # exit scans that never found an entry scan (someone may have boarded without tapping in)
    grace = utcnow() - timedelta(minutes=ORPHAN_GRACE_MINUTES)
    for o in db.scalars(
        select(TapOut).where(
            TapOut.operator_id == operator_id,
            TapOut.status == "orphan",
            TapOut.rider_id.is_not(None),
            TapOut.tapped_at >= since,
            TapOut.tapped_at <= grace,
        )
    ):
        flagged.append(
            {
                "trip_id": o.id,
                "rider_id": o.rider_id,
                "station_id": o.station_id,
                "tapped_at": o.tapped_at.isoformat() + "Z",
                "fare": 0,
                "status": "orphan",
                "reasons": ["exit_without_entry"],
                "score": None,
            }
        )
    flagged.sort(key=lambda f: f["tapped_at"], reverse=True)
    return flagged
