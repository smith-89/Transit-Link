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
