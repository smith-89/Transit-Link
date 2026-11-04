"""Operator dashboard API.

Linked to: analytics (summary), fraud (flags), payouts (run), models, security.
Every query is scoped to the logged-in operator's own id.
"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import analytics, fraud, payouts, trips
from ..db import get_db
from ..models import Operator, Payout, Station
from ..security import current_operator

router = APIRouter(prefix="/operator", tags=["operator"])


def _close_stale(db: Session) -> None:
    """Journeys still open after OPEN_TRIP_HOURS are closed at the held maximum fare."""
    if trips.close_stale(db):
        db.commit()


def _payout_json(p: Payout) -> dict:
    return {
        "id": p.id,
        "trips": p.trips_count,
        "gross": p.gross,
        "fee": p.fee,
        "net": p.net,
        "status": p.status,
        "created_at": p.created_at.isoformat() + "Z",
    }


@router.get("/summary")
def summary(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    _close_stale(db)
    return {"operator": op.name, **analytics.summary(db, op.id)}


@router.get("/flags")
def flags(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    _close_stale(db)
    stations = {s.id: s.name for s in db.scalars(select(Station))}
    items = fraud.scan(db, op.id)
    for item in items:
        item["station"] = stations.get(item["station_id"], "?")
    return {"flags": items[:100]}


@router.get("/payouts")
def list_payouts(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    rows = db.scalars(select(Payout).where(Payout.operator_id == op.id).order_by(Payout.id.desc()).limit(20))
    return {"payouts": [_payout_json(p) for p in rows]}


@router.post("/payouts/run")
def run_payout(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    trips.close_stale(db)
    payout = payouts.run_payout(db, op.id)
    if payout is None:
        raise HTTPException(409, "Nothing to pay out yet. No unpaid trips.")
    db.commit()
    return _payout_json(payout)
