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
