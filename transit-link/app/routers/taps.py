"""Validator endpoints: fetch device config and sync offline taps (boarding and alighting).

Linked to: trips.process_tap, security.current_validator, models.
"""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from .. import fares, trips
from ..db import get_db
from ..models import Operator, Station, Validator
from ..schemas import SyncIn
from ..security import current_validator
from ..timeutil import to_naive_utc

router = APIRouter(tags=["validator"])


@router.get("/validator/config")
def validator_config(validator: Validator = Depends(current_validator), db: Session = Depends(get_db)):
    station = db.get(Station, validator.station_id)
    operator = db.get(Operator, validator.operator_id)
    top = fares.max_fare(db, station.id)
    return {
        "validator": validator.name,
        "operator": operator.name,
        "station": station.name,
        # "distance": boarding holds the maximum fare and alighting settles the exact one
        # "flat": one fixed fare charged at boarding, no exit scan needed
        "mode": "distance" if top is not None else "flat",
        "fare": top if top is not None else station.fare,
    }


@router.post("/taps/sync")
def sync_taps(body: SyncIn, validator: Validator = Depends(current_validator), db: Session = Depends(get_db)):
    """Process a batch of taps in the order they happened. Safe to re-send."""
    ordered = sorted(body.taps, key=lambda t: to_naive_utc(t.tapped_at))
    results = [
        trips.process_tap(db, validator, t.tap_id, t.pass_token, to_naive_utc(t.tapped_at), t.direction) for t in ordered
    ]
    db.commit()
    return {"results": results}
