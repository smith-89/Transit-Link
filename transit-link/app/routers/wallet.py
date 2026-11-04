"""Rider wallet view and the QR pass.

Linked to: ledger (balance, history), security (create_pass_token), models.
The QR pass is a signed token that expires in minutes, so a screenshot is useless.
"""
from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import ledger
from ..db import get_db
from ..models import Rider, Station, Trip
from ..security import create_pass_token, current_rider

router = APIRouter(tags=["wallet"])


@router.get("/wallet")
def wallet(rider: Rider = Depends(current_rider), db: Session = Depends(get_db)):
    entries = ledger.history(db, rider.id)
    trip_ids = [e.ref for e in entries if e.kind in ("fare", "refund")]
    trips = {t.id: t for t in db.scalars(select(Trip).where(Trip.id.in_(trip_ids)))} if trip_ids else {}
    stations = {s.id: s.name for s in db.scalars(select(Station))}
    items = []
    for e in entries:
        label = "M-Pesa top-up" if e.kind == "topup" else e.kind.capitalize()
        trip = trips.get(e.ref)
        if e.kind == "fare" and trip:
            origin = stations.get(trip.station_id, "station")
            label = f"Fare held from {origin}" if trip.hold else f"Fare from {origin}"
        elif e.kind == "refund" and trip:
            label = f"Refund: {stations.get(trip.station_id, 'station')} to {stations.get(trip.exit_station_id, 'exit')}"
        items.append({"label": label, "amount": e.amount, "kind": e.kind, "at": e.created_at.isoformat() + "Z", "ref": e.ref})
    return {"name": rider.name, "phone": rider.phone, "balance": ledger.balance(db, rider.id), "history": items}


@router.get("/pass")
def qr_pass(rider: Rider = Depends(current_rider)):
    token, ttl = create_pass_token(rider.id)
    return {"token": token, "expires_in": ttl}
