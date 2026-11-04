"""Demo data. Run:  python -m app.seed [--history] [--reset]

Linked to: models, ledger, security (hash_secret), db. main.py calls ensure_demo()
on start-up when AUTO_SEED=1.

  core     2 operators, 6 boarding points, 2 validators, 1 demo rider (safe to repeat)
  history  40 simulated riders and 14 days of commuter trips with injected
           anomalies, so the dashboard charts and the fraud model have something to show

All names, stations and fares are DEMO values, not official Kenya Railways data.
Demo logins are printed at the end. Change or remove them before any public deployment.
"""
import random
import sys
import uuid
from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import ledger
from .config import settings
from .db import Base, SessionLocal, engine, init_db
from .models import Operator, Rider, Station, Trip, Validator
from .security import hash_secret
from .timeutil import utcnow

DEMO_RIDER = {"phone": "254712345678", "name": "Demo Rider", "pin": "1234"}
DEMO_OPERATORS = [
    {"name": "Demo Commuter Rail", "username": "rail", "password": "demo1234"},
    {"name": "Demo Feeder Sacco", "username": "sacco", "password": "demo1234"},
]
# (name, fare KES, operator index)
DEMO_STATIONS = [
    ("Nairobi Central", 50, 0),
    ("Makadara", 50, 0),
    ("Githurai", 60, 0),
    ("Ruiru", 70, 0),
    ("Thika", 80, 0),
    ("Githurai Matatu Stage", 30, 1),
]
DEMO_VALIDATORS = [
    {"name": "Rail gate 1 (Nairobi Central)", "api_key": "demo-validator-key-1", "station": 0, "operator": 0},
    {"name": "Feeder matatu 1 (Githurai stage)", "api_key": "demo-validator-key-2", "station": 5, "operator": 1},
]


def seed_core(db: Session) -> bool:
    if db.scalar(select(Operator.id).limit(1)):
        return False
    ops = []
    for o in DEMO_OPERATORS:
        op = Operator(name=o["name"], username=o["username"], password_hash=hash_secret(o["password"]))
        db.add(op)
        ops.append(op)
    db.flush()
    stations = []
    for i, (name, fare, _) in enumerate(DEMO_STATIONS):
        st = Station(name=name, order_index=i, fare=fare)
        db.add(st)
        stations.append(st)
    db.flush()
    for v in DEMO_VALIDATORS:
        db.add(
            Validator(
                name=v["name"],
                api_key=v["api_key"],
                operator_id=ops[v["operator"]].id,
                station_id=stations[v["station"]].id,
            )
        )
    rider = Rider(phone=DEMO_RIDER["phone"], name=DEMO_RIDER["name"], pin_hash=hash_secret(DEMO_RIDER["pin"]))
    db.add(rider)
    db.flush()
    ledger.post(db, rider.id, 500, "topup", "SEED-DEMO-TOPUP")
    db.commit()
    return True


def seed_history(db: Session, riders: int = 40, days: int = 14, seed: int = 7) -> dict:
    rng = random.Random(seed)
    rail = db.scalar(select(Operator).where(Operator.username == "rail"))
    stations = list(db.scalars(select(Station).where(Station.id.in_(range(1, 6))).order_by(Station.order_index)))
    validators = {v.station_id: v for v in db.scalars(select(Validator))}
    if rail is None or len(stations) < 5:
        raise RuntimeError("Run seed_core first.")
    pin_hash = hash_secret("0000")  # one hash reused: demo riders all use PIN 0000
    now = utcnow()
    offset = timedelta(hours=settings.local_utc_offset_hours)
    made, anomalies = 0, 0

    def add_trip(rider: Rider, station: Station, when, charge: bool = True) -> Trip:
        trip = Trip(
            id=uuid.uuid4().hex,
            rider_id=rider.id,
            validator_id=None,
            station_id=station.id,
            operator_id=rail.id,
            pass_jti="seed-" + uuid.uuid4().hex[:12],
            tapped_at=when,
            received_at=when,
            fare=station.fare if charge else 0,
            status="charged" if charge else "declined",
            reason=None if charge else "insufficient_funds",
        )
        db.add(trip)
        db.flush()
        if charge:
            ledger.post(db, rider.id, -station.fare, "fare", trip.id)
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
            for station, hour_mu in ((home, 7.2), (work, 17.8)):
                if rng.random() < 0.15:
                    continue
                hour = min(max(rng.gauss(hour_mu, 0.7), 5.0), 22.0)
                when = day_local + timedelta(hours=hour) - offset  # back to UTC
                if when > now:
                    continue
                add_trip(rider, station, when)
                made += 1

    # injected anomalies the rules and the model should surface
    victims = list(db.scalars(select(Rider).where(Rider.phone.like("2547000%")).limit(6)))
    for i, rider in enumerate(victims):
        base = now - timedelta(days=rng.randint(1, 5), hours=rng.randint(0, 3))
        if i % 3 == 0:  # same rider, same station, seconds apart
            add_trip(rider, stations[0], base)
            add_trip(rider, stations[0], base + timedelta(seconds=25))
        elif i % 3 == 1:  # two different stations a minute apart
            add_trip(rider, stations[1], base)
            add_trip(rider, stations[4], base + timedelta(seconds=70))
        else:  # burst: many taps in half an hour
            for k in range(6):
                add_trip(rider, stations[2], base + timedelta(minutes=5 * k))
        anomalies += 1
    db.commit()
    return {"riders": riders, "normal_trips": made, "anomaly_groups": anomalies}


def ensure_demo() -> bool:
    init_db()
    with SessionLocal() as db:
        return seed_core(db)


def main(argv: list[str]) -> None:
    if "--reset" in argv:
        Base.metadata.drop_all(engine)
    init_db()
    with SessionLocal() as db:
        created = seed_core(db)
        print("Core demo data created." if created else "Core demo data already present.")
        if "--history" in argv:
            if db.scalar(select(Rider.id).where(Rider.phone.like("2547000%")).limit(1)):
                print("History already present. Use --reset to rebuild.")
            else:
                print("History:", seed_history(db))
    print("\nDemo logins")
    print("  Rider      phone 0712345678   PIN 1234")
    print("  Operator   rail / demo1234    (also: sacco / demo1234)")
    print("  Validator  key demo-validator-key-1 (Nairobi Central), demo-validator-key-2 (feeder)")


if __name__ == "__main__":
    main(sys.argv[1:])
