"""Demo data. Run:  python -m app.seed [--history] [--reset]

Linked to: models, ledger, fares, security (hash_secret), db. main.py calls ensure_demo()
on start-up when AUTO_SEED=1.

  core     2 operators, 6 boarding points, a fare table for the rail line, 6 gate devices and
           1 demo rider (safe to repeat; also tops up older databases with the fare table)
  history  40 simulated riders and 14 days of commuter journeys with injected anomalies, a few
           missed tap-outs and two journeys still in progress, so the dashboard has something to show

All names, stations and fares are DEMO values, not official Kenya Railways data.
Demo logins are printed at the end. Change or remove them before any public deployment.
"""
import random
import sys
import uuid
from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import fares, ledger
from .config import settings
from .db import Base, SessionLocal, engine, init_db
from .models import Fare, Operator, Rider, Station, Trip, Validator
from .security import hash_secret
from .timeutil import utcnow

DEMO_RIDER = {"phone": "254712345678", "name": "Demo Rider", "pin": "1234"}
DEMO_OPERATORS = [
    {"name": "Demo Commuter Rail", "username": "rail", "password": "demo1234"},
    {"name": "Demo Feeder Sacco", "username": "sacco", "password": "demo1234"},
]
# (name, flat fare KES, operator index). Rail stations also get a distance fare table (below);
# their flat fare is only a fallback. The feeder stop stays flat.
DEMO_STATIONS = [
    ("Nairobi Central", 80, 0),
    ("Makadara", 60, 0),
    ("Githurai", 45, 0),
    ("Ruiru", 60, 0),
    ("Thika", 80, 0),
    ("Githurai Matatu Stage", 30, 1),
]
RAIL_STATIONS = [name for name, _, op in DEMO_STATIONS if op == 0]
HOP_PRICES = {1: 30, 2: 45, 3: 60, 4: 80}  # KES by number of stops travelled
DEMO_VALIDATORS = [
    {"name": "Rail gate 1 (Nairobi Central)", "api_key": "demo-validator-key-1", "station": 0, "operator": 0},
    {"name": "Feeder matatu 1 (Githurai stage)", "api_key": "demo-validator-key-2", "station": 5, "operator": 1},
    {"name": "Rail gate 2 (Makadara)", "api_key": "demo-validator-key-3", "station": 1, "operator": 0},
    {"name": "Rail gate 3 (Githurai)", "api_key": "demo-validator-key-4", "station": 2, "operator": 0},
    {"name": "Rail gate 4 (Ruiru)", "api_key": "demo-validator-key-5", "station": 3, "operator": 0},
    {"name": "Rail gate 5 (Thika)", "api_key": "demo-validator-key-6", "station": 4, "operator": 0},
]


def seed_core(db: Session) -> bool:
    if db.scalar(select(Operator.id).limit(1)):
        return False
    for o in DEMO_OPERATORS:
        db.add(Operator(name=o["name"], username=o["username"], password_hash=hash_secret(o["password"])))
    db.flush()
    for i, (name, fare, _) in enumerate(DEMO_STATIONS):
        db.add(Station(name=name, order_index=i, fare=fare))
    db.flush()
    rider = Rider(phone=DEMO_RIDER["phone"], name=DEMO_RIDER["name"], pin_hash=hash_secret(DEMO_RIDER["pin"]))
    db.add(rider)
    db.flush()
    ledger.post(db, rider.id, 500, "topup", "SEED-DEMO-TOPUP")
    db.commit()
    return True


def ensure_fares(db: Session) -> int:
    """Create the rail fare table if missing (also upgrades databases made before distance fares)."""
    if db.scalar(select(Fare.id).limit(1)):
        return 0
    stations = {s.name: s.id for s in db.scalars(select(Station))}
    ids = [stations[n] for n in RAIL_STATIONS if n in stations]
    if len(ids) < 2:
        return 0
    added = fares.set_pair_fares(db, ids, HOP_PRICES)
    db.commit()
    return added


def ensure_validators(db: Session) -> int:
    """Add any demo gate devices that are missing (matched by device key)."""
    stations = {s.name: s.id for s in db.scalars(select(Station))}
    operators = {o.username: o.id for o in db.scalars(select(Operator))}
    added = 0
    for v in DEMO_VALIDATORS:
        if db.scalar(select(Validator.id).where(Validator.api_key == v["api_key"])):
            continue
        station = stations.get(DEMO_STATIONS[v["station"]][0])
        operator = operators.get(DEMO_OPERATORS[v["operator"]]["username"])
        if station and operator:
            db.add(Validator(name=v["name"], api_key=v["api_key"], operator_id=operator, station_id=station))
            added += 1
    db.commit()
    return added


def seed_history(db: Session, riders: int = 40, days: int = 14, seed: int = 7) -> dict:
    rng = random.Random(seed)
    rail = db.scalar(select(Operator).where(Operator.username == "rail"))
    stations = [s for s in db.scalars(select(Station).order_by(Station.order_index)) if s.name in RAIL_STATIONS]
    if rail is None or len(stations) < 5:
        raise RuntimeError("Run seed_core first.")
    ensure_fares(db)
    price = {(f.from_station_id, f.to_station_id): f.price for f in db.scalars(select(Fare))}
    pin_hash = hash_secret("0000")  # one hash reused: demo riders all use PIN 0000
    now = utcnow()
    offset = timedelta(hours=settings.local_utc_offset_hours)
    made, anomalies = 0, 0

    def journey(rider: Rider, origin: Station, when, dest: Station | None = None, **extra) -> Trip:
        """A completed journey: charged the exact fare, with an exit scan 20-70 minutes later."""
        dest = dest or max((s for s in stations if s.id != origin.id), key=lambda s: price.get((origin.id, s.id), 0))
        fare = price[(origin.id, dest.id)]
        trip = Trip(
            id=uuid.uuid4().hex, rider_id=rider.id, validator_id=None, station_id=origin.id, operator_id=rail.id,
            pass_jti="seed-" + uuid.uuid4().hex[:12], tapped_at=when, received_at=when, fare=fare, hold=0,
            status="charged", exit_station_id=dest.id, exit_at=when + timedelta(minutes=rng.randint(20, 70)),
            exit_tap_id=uuid.uuid4().hex, **extra,
        )
        db.add(trip)
        db.flush()
        ledger.post(db, rider.id, -fare, "fare", trip.id)
        return trip

    for n in range(riders):
        rider = Rider(phone=f"2547000{n:05d}", name=f"Sim Rider {n + 1}", pin_hash=pin_hash)
        db.add(rider)
        db.flush()
        ledger.post(db, rider.id, 4000, "topup", f"SEED-TOPUP-{rider.id}")
        home, work = rng.sample(stations, 2)
        for d in range(days, -1, -1):  # d=0 is today (only trips already in the past)
            day_local = (now + offset - timedelta(days=d)).replace(hour=0, minute=0, second=0, microsecond=0)
            if day_local.weekday() >= 5 and rng.random() < 0.8:
                continue  # few weekend trips
            for origin, dest, hour_mu in ((home, work, 7.2), (work, home, 17.8)):
                if rng.random() < 0.15:
                    continue
                hour = min(max(rng.gauss(hour_mu, 0.7), 5.0), 22.0)
                when = day_local + timedelta(hours=hour) - offset  # back to UTC
                if when > now:
                    continue
                journey(rider, origin, when, dest)
                made += 1

    # injected anomalies the rules and the model should surface
    victims = list(db.scalars(select(Rider).where(Rider.phone.like("2547000%")).limit(9)))
    for i, rider in enumerate(victims[:6]):
        base = now - timedelta(days=rng.randint(1, 5), hours=rng.randint(0, 3))
        if i % 3 == 0:  # same rider, same station, seconds apart
            journey(rider, stations[0], base, stations[1])
            journey(rider, stations[0], base + timedelta(seconds=25), stations[1])
        elif i % 3 == 1:  # two different stations a minute apart
            journey(rider, stations[1], base, stations[2])
            journey(rider, stations[4], base + timedelta(seconds=70), stations[3])
        else:  # burst: many taps in half an hour
            for k in range(6):
                journey(rider, stations[2], base + timedelta(minutes=5 * k), stations[3])
        anomalies += 1

    # three riders who never tapped out: closed at the maximum fare
    missed = 0
    for rider in victims[6:9]:
        origin = stations[1]
        top = max(price[(origin.id, s.id)] for s in stations if s.id != origin.id)
        when = now - timedelta(days=1, hours=rng.randint(1, 4))
        trip = Trip(
            id=uuid.uuid4().hex, rider_id=rider.id, station_id=origin.id, operator_id=rail.id,
            pass_jti="seed-" + uuid.uuid4().hex[:12], tapped_at=when, received_at=when, fare=top, hold=top,
            status="charged", reason="no_tap_out",
        )
        db.add(trip)
        db.flush()
        ledger.post(db, rider.id, -top, "fare", trip.id)
        missed += 1

    # two journeys in progress right now (maximum fare held, waiting for a tap-out)
    in_progress = 0
    for rider in list(db.scalars(select(Rider).where(Rider.phone.like("2547000%")).offset(10).limit(2))):
        origin = stations[0]
        top = max(price[(origin.id, s.id)] for s in stations if s.id != origin.id)
        when = now - timedelta(minutes=12)
        trip = Trip(
            id=uuid.uuid4().hex, rider_id=rider.id, station_id=origin.id, operator_id=rail.id,
            pass_jti="seed-" + uuid.uuid4().hex[:12], tapped_at=when, received_at=when, fare=top, hold=top, status="open",
        )
        db.add(trip)
        db.flush()
        ledger.post(db, rider.id, -top, "fare", trip.id)
        in_progress += 1
    db.commit()
    return {"riders": riders, "journeys": made, "anomaly_groups": anomalies, "missed_tap_outs": missed, "in_progress": in_progress}


def ensure_demo() -> bool:
    init_db()
    with SessionLocal() as db:
        created = seed_core(db)
        ensure_fares(db)
        ensure_validators(db)
        return created


def main(argv: list[str]) -> None:
    if "--reset" in argv:
        Base.metadata.drop_all(engine)
    init_db()
    with SessionLocal() as db:
        created = seed_core(db)
        print("Core demo data created." if created else "Core demo data already present.")
        fare_rows, gates = ensure_fares(db), ensure_validators(db)
        if fare_rows:
            print(f"Fare table created ({fare_rows} station pairs).")
        if created or gates:
            print(f"Gate devices ready ({len(DEMO_VALIDATORS)}).")
        if "--history" in argv:
            if db.scalar(select(Rider.id).where(Rider.phone.like("2547000%")).limit(1)):
                print("History already present. Use --reset to rebuild.")
            else:
                print("History:", seed_history(db))
    print("\nDemo logins")
    print("  Rider      phone 0712345678   PIN 1234")
    print("  Operator   rail / demo1234    (also: sacco / demo1234)")
    print("  Gates      Account = device ID, no passcode:")
    for v in DEMO_VALIDATORS:
        print(f"             {v['api_key']}  {v['name']}")


if __name__ == "__main__":
    main(sys.argv[1:])
