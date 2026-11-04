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
