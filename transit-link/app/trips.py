"""Tap processing: turns a scanned QR pass into a journey, charged by distance.

Linked to: security (decode_pass_token), ledger (debits and refunds), fares (price table),
models, routers/taps (calls process_tap for every tap), fraud and analytics (read trips).

Two kinds of tap, chosen on the gate device ("in" = boarding, "out" = alighting):

  TAP-IN   Station has distance fares -> the MAXIMUM fare from that station is debited at once
           and the trip is `open`. Station is flat-fare -> the flat fare is charged and the trip
           is `charged` straight away (no tap-out needed).
  TAP-OUT  The rider's open trip is found, the exact fare for origin -> here is looked up, and the
           difference is refunded: trip becomes `charged` with the final fare.

Checks on every tap, in this order (the first failure wins):
  already seen this tap id?  -> return the stored result (retries are safe)
  pass signature valid?      -> else rejected / invalid_pass
  tap time inside pass window?   -> else rejected / stale_pass
  pass already used (same direction)? -> else rejected / replayed_pass
  rider exists?              -> else rejected / unknown_rider

Edge cases handled:
  - missed tap-out: the open trip is closed at the held maximum fare when the rider next taps in,
    or after OPEN_TRIP_HOURS (see close_stale). Flagged `missed_tap_out`.
  - tap-out arrives before its tap-in (two devices syncing in a different order): stored as
    `orphan`, then matched automatically when the tap-in arrives.
  - tap-out at the station you entered: journey is `cancelled` and fully refunded.
  - a pass can be used once to enter AND once to leave, so a short journey works.
"""
from datetime import datetime, timedelta

import jwt
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import fares, ledger
from .config import settings
from .models import Rider, Station, TapOut, Trip, Validator
from .security import decode_pass_token
from .timeutil import from_epoch, utcnow


def _station_name(db: Session, station_id: int | None) -> str | None:
    if station_id is None:
        return None
    station = db.get(Station, station_id)
    return station.name if station else None


def _result(db, direction, tap_id, status, reason=None, fare=0, refund=0, duplicate=False, balance=None, origin=None, destination=None):
    return {
        "tap_id": tap_id,
        "direction": direction,
        "status": status,
        "reason": reason,
        "fare": fare,
        "refund": refund,
        "duplicate": duplicate,
        "balance": balance,
        "from_station": _station_name(db, origin),
        "to_station": _station_name(db, destination),
    }


def _check_pass(db: Session, pass_token: str, tapped_at: datetime, tap_id: str, replay_model):
    """Validate a pass. Returns (rider or None, pass id, failure reason or None)."""
    try:
        claims = decode_pass_token(pass_token)
    except jwt.PyJWTError:
        return None, "", "invalid_pass"
    jti = claims["jti"]
    rider = db.get(Rider, int(claims["sub"]))
    window = timedelta(seconds=settings.tap_tolerance_seconds)
    if not (from_epoch(claims["iat"]) - window <= tapped_at <= from_epoch(claims["exp"]) + window):
        return rider, jti, "stale_pass"
    if db.scalar(select(replay_model.id).where(replay_model.pass_jti == jti, replay_model.id != tap_id).limit(1)):
        return rider, jti, "replayed_pass"
    if rider is None:
        return None, jti, "unknown_rider"
    return rider, jti, None


def process_tap(db: Session, validator: Validator, tap_id: str, pass_token: str, tapped_at: datetime, direction: str = "in") -> dict:
    for model in (Trip, TapOut):
        existing = db.get(model, tap_id)
        if existing is not None:
            return _duplicate(db, existing)
    if direction == "out":
        return _tap_out(db, validator, tap_id, pass_token, tapped_at)
    return _tap_in(db, validator, tap_id, pass_token, tapped_at)


def _duplicate(db: Session, row) -> dict:
    balance = ledger.balance(db, row.rider_id) if row.rider_id else None
    if isinstance(row, Trip):
        return _result(db, "in", row.id, row.status, row.reason, row.fare, 0, True, balance, row.station_id, row.exit_station_id)
    origin = db.get(Trip, row.trip_id).station_id if row.trip_id else None
    return _result(db, "out", row.id, row.status, row.reason, row.final_fare, row.refund, True, balance, origin, row.station_id)


# ---------------------------------------------------------------- tap-in
def _tap_in(db: Session, validator: Validator, tap_id: str, pass_token: str, tapped_at: datetime) -> dict:
    station = db.get(Station, validator.station_id)
    trip = Trip(
        id=tap_id,
        validator_id=validator.id,
        station_id=station.id,
        operator_id=validator.operator_id,
        tapped_at=tapped_at,
        received_at=utcnow(),
        fare=0,
        hold=0,
        status="rejected",
    )
    rider, jti, reason = _check_pass(db, pass_token, tapped_at, tap_id, Trip)
    trip.pass_jti = jti
    trip.rider_id = rider.id if rider else None

    if reason is not None:
        trip.reason = reason
    else:
        close_open_trips(db, rider.id, before=tapped_at)  # earlier journeys the rider never tapped out of
        top = fares.max_fare(db, station.id)
        amount = top if top is not None else station.fare
        if ledger.balance(db, rider.id) - amount < -settings.overdraft_limit:
            trip.status, trip.reason = "declined", "insufficient_funds"
        else:
            trip.fare = amount
            if top is not None:
                trip.hold, trip.status = amount, "open"  # settled at tap-out
            else:
                trip.status = "charged"  # flat fare, final immediately
            ledger.post(db, rider.id, -amount, "fare", tap_id)

    db.add(trip)
    db.flush()
    if trip.status == "open":
        _match_orphan(db, trip)
    balance = ledger.balance(db, rider.id) if rider else None
    return _result(db, "in", tap_id, trip.status, trip.reason, trip.fare, 0, False, balance, trip.station_id, trip.exit_station_id)


# ---------------------------------------------------------------- tap-out
def _tap_out(db: Session, validator: Validator, tap_id: str, pass_token: str, tapped_at: datetime) -> dict:
    out = TapOut(
        id=tap_id,
        validator_id=validator.id,
        station_id=validator.station_id,
        operator_id=validator.operator_id,
        tapped_at=tapped_at,
        received_at=utcnow(),
        status="rejected",
    )
    rider, jti, reason = _check_pass(db, pass_token, tapped_at, tap_id, TapOut)
    out.pass_jti = jti
    out.rider_id = rider.id if rider else None
    origin = None

    if reason is not None:
        out.reason = reason
        db.add(out)
    elif not fares.in_network(db, out.station_id):
        out.status, out.reason = "ignored", "flat_fare"  # nothing to settle at a flat-fare stop
        db.add(out)
    else:
        trip = db.scalar(
            select(Trip)
            .where(
                Trip.rider_id == rider.id,
                Trip.operator_id == out.operator_id,
                Trip.status == "open",
                Trip.tapped_at <= tapped_at,
                Trip.tapped_at >= tapped_at - timedelta(hours=settings.open_trip_hours),
            )
            .order_by(Trip.tapped_at.desc())
            .limit(1)
        )
        db.add(out)
        if trip is None:
            out.status, out.reason = "orphan", "no_tap_in"  # may be matched when the tap-in syncs
        else:
            origin = trip.station_id
            db.flush()
            _settle(db, trip, out)

    db.flush()
    balance = ledger.balance(db, rider.id) if rider else None
    return _result(db, "out", tap_id, out.status, out.reason, out.final_fare, out.refund, False, balance, origin, out.station_id)


def _settle(db: Session, trip: Trip, out: TapOut) -> None:
    """Close an open trip using an exit scan. Refunds whatever was held above the real fare."""
    if trip.station_id == out.station_id:
        final, trip.status, out.status, out.reason = 0, "cancelled", "cancelled", "same_station"
        trip.reason = "same_station"
    else:
        exact = fares.price(db, trip.station_id, out.station_id)
        if exact is None:  # pair missing from the table: keep the held maximum
            final, trip.reason, out.reason = trip.hold, "no_fare_for_pair", "no_fare_for_pair"
        else:
            final = min(exact, trip.hold)
        trip.status, out.status = "charged", "settled"
    refund = trip.hold - final
    trip.fare = final
    trip.exit_station_id, trip.exit_at, trip.exit_tap_id = out.station_id, out.tapped_at, out.id
    out.trip_id, out.final_fare, out.refund = trip.id, final, refund
    if refund > 0:
        ledger.post(db, trip.rider_id, refund, "refund", trip.id)  # (kind, ref) is unique: refunded once
    db.flush()


def _match_orphan(db: Session, trip: Trip) -> None:
    """A tap-in arrived late: attach the earliest exit scan that was waiting for it."""
    orphan = db.scalar(
        select(TapOut)
        .where(
            TapOut.rider_id == trip.rider_id,
            TapOut.operator_id == trip.operator_id,
            TapOut.status == "orphan",
            TapOut.tapped_at > trip.tapped_at,
            TapOut.tapped_at <= trip.tapped_at + timedelta(hours=settings.open_trip_hours),
        )
        .order_by(TapOut.tapped_at)
        .limit(1)
    )
    if orphan is not None:
        orphan.reason = None
        _settle(db, trip, orphan)


# ---------------------------------------------------------------- open journeys that never closed
def close_open_trips(db: Session, rider_id: int, before: datetime) -> int:
    """Close a rider's earlier open trips at the held maximum fare (they never tapped out)."""
    rows = db.scalars(select(Trip).where(Trip.rider_id == rider_id, Trip.status == "open", Trip.tapped_at < before))
    count = 0
    for trip in rows:
        trip.status, trip.reason = "charged", "no_tap_out"
        count += 1
    return count


def close_stale(db: Session, now: datetime | None = None) -> int:
    """Close every journey still open after OPEN_TRIP_HOURS at its held maximum fare.
    Called before the operator dashboard and payouts read their numbers."""
    cutoff = (now or utcnow()) - timedelta(hours=settings.open_trip_hours)
    count = 0
    for trip in db.scalars(select(Trip).where(Trip.status == "open", Trip.tapped_at < cutoff)):
        trip.status, trip.reason = "charged", "no_tap_out"
        count += 1
    db.flush()
    return count
