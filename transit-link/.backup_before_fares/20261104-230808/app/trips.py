"""Tap processing: turns a scanned QR pass into a charged, declined or rejected trip.

Linked to: security (decode_pass_token), ledger (fare debit), models,
routers/taps (calls process_tap for each offline tap), fraud (reads trips).

Order of checks for every tap:
  1. Already seen this tap_id?          -> return the stored result (idempotent sync)
  2. Pass signature valid?              -> else rejected / invalid_pass
  3. Tap time inside the pass window?   -> else rejected / stale_pass
  4. Same pass already used?            -> else rejected / replayed_pass
  5. Rider exists?                      -> else rejected / unknown_rider
  6. Balance minus fare above overdraft -> else declined / insufficient_funds
  7. Otherwise charged: one negative ledger row, reference = tap_id
"""
from datetime import datetime, timedelta

import jwt
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import ledger
from .config import settings
from .models import Rider, Station, Trip, Validator
from .security import decode_pass_token
from .timeutil import from_epoch, utcnow


def _result(trip: Trip, duplicate: bool, balance: int | None) -> dict:
    return {
        "tap_id": trip.id,
        "status": trip.status,
        "reason": trip.reason,
        "fare": trip.fare,
        "duplicate": duplicate,
        "balance": balance,
    }


def process_tap(db: Session, validator: Validator, tap_id: str, pass_token: str, tapped_at: datetime) -> dict:
    existing = db.get(Trip, tap_id)
    if existing is not None:
        bal = ledger.balance(db, existing.rider_id) if existing.rider_id else None
        return _result(existing, True, bal)

    station = db.get(Station, validator.station_id)
    trip = Trip(
        id=tap_id,
        validator_id=validator.id,
        station_id=validator.station_id,
        operator_id=validator.operator_id,
        tapped_at=tapped_at,
        received_at=utcnow(),
        fare=0,
        status="rejected",
    )
    reason: str | None = None
    rider: Rider | None = None

    try:
        claims = decode_pass_token(pass_token)
    except jwt.PyJWTError:
        claims = None
        reason = "invalid_pass"

    if claims is not None:
        trip.pass_jti = claims["jti"]
        rider = db.get(Rider, int(claims["sub"]))
        trip.rider_id = rider.id if rider else None
        window = timedelta(seconds=settings.tap_tolerance_seconds)
        valid_from, valid_to = from_epoch(claims["iat"]) - window, from_epoch(claims["exp"]) + window
        if not (valid_from <= tapped_at <= valid_to):
            reason = "stale_pass"
        elif db.scalar(select(Trip.id).where(Trip.pass_jti == claims["jti"], Trip.id != tap_id).limit(1)):
            reason = "replayed_pass"
        elif rider is None:
            reason = "unknown_rider"

    if reason is not None:
        trip.reason = reason
    else:
        fare = station.fare
        current = ledger.balance(db, rider.id)
        if current - fare < -settings.overdraft_limit:
            trip.status, trip.reason = "declined", "insufficient_funds"
        else:
            trip.status, trip.fare = "charged", fare
            ledger.post(db, rider.id, -fare, "fare", tap_id)

    db.add(trip)
    db.flush()
    bal = ledger.balance(db, rider.id) if rider else None
    return _result(trip, False, bal)
