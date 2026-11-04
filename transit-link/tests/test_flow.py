"""End-to-end tests of the MVP showcase flow, including distance fares. Run:  pytest -q

Demo fare table (KES): stops apart -> 1: 30, 2: 45, 3: 60, 4: 80.
Stations: 1 Nairobi Central, 2 Makadara, 3 Githurai, 4 Ruiru, 5 Thika (rail); 6 feeder stop (flat 30).
Gate devices: key-1 Central, key-2 feeder, key-3 Makadara, key-4 Githurai, key-5 Ruiru, key-6 Thika.
"""
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import app

K = {i: {"X-Validator-Key": f"demo-validator-key-{i}"} for i in range(1, 7)}
CENTRAL, FEEDER, MAKADARA, GITHURAI, RUIRU, THIKA = 1, 2, 3, 4, 5, 6  # gate device numbers


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


_phone = iter(range(711100100, 711199999))


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _iso(dt=None):
    return (dt or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z")


def _rider(client, topup=0):
    r = client.post("/api/auth/register", json={"phone": "0" + str(next(_phone)), "name": "Test Rider", "pin": "4321"})
    assert r.status_code == 201, r.text
    token = r.json()["token"]
    if topup:
        t = client.post("/api/topups", json={"amount": topup}, headers=_auth(token)).json()
        done = client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token)).json()
        assert done["status"] == "success"
    return token


def _pass(client, token):
    return client.get("/api/pass", headers=_auth(token)).json()["token"]


def _balance(client, token):
    return client.get("/api/wallet", headers=_auth(token)).json()["balance"]


def _tap(client, gate, qr, direction="in", when=None, tap_id=None):
    body = {"taps": [{"tap_id": tap_id or uuid.uuid4().hex, "pass_token": qr, "tapped_at": _iso(when), "direction": direction}]}
    return client.post("/api/taps/sync", json=body, headers=K[gate]).json()["results"][0]


def _journey(client, token, start, end):
    """Tap in at one gate and out at another with the same pass. Returns (entry, exit)."""
    qr = _pass(client, token)
    return _tap(client, start, qr, "in"), _tap(client, end, qr, "out")


def _operator(client, username="rail"):
    r = client.post("/api/auth/operator/login", json={"username": username, "password": "demo1234"})
    assert r.status_code == 200
    return _auth(r.json()["token"])


# ------------------------------------------------------------------ basics
def test_health_and_static(client):
    assert client.get("/api/health").json()["status"] == "ok"
    for path in ("/", "/login/", "/rider/", "/validator/", "/operator/"):
        assert client.get(path).status_code == 200, path


def test_register_login_validation(client):
    token = _rider(client)
    me = client.get("/api/wallet", headers=_auth(token)).json()
    phone = "0" + str(int(me["phone"][3:]))
    assert client.post("/api/auth/login", json={"phone": phone, "pin": "4321"}).status_code == 200
    assert client.post("/api/auth/login", json={"phone": phone, "pin": "0000"}).status_code == 401
    assert client.post("/api/auth/register", json={"phone": phone, "name": "X Y", "pin": "4321"}).status_code == 409
    assert client.post("/api/auth/register", json={"phone": "12345", "name": "X Y", "pin": "4321"}).status_code == 422
    assert me["balance"] == 0


def test_topup_mock_flow_and_idempotency(client):
    token = _rider(client)
    t = client.post("/api/topups", json={"amount": 300}, headers=_auth(token)).json()
    assert t["status"] == "pending" and t["mode"] == "mock"
    client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token))
    client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token))  # twice
    assert _balance(client, token) == 300
    assert client.post("/api/topups", json={"amount": 5}, headers=_auth(token)).status_code == 422


def test_daraja_callback(client):
    token = _rider(client)
    t = client.post("/api/topups", json={"amount": 200}, headers=_auth(token)).json()
    payload = {"Body": {"stkCallback": {
        "MerchantRequestID": "x", "CheckoutRequestID": t["checkout_request_id"], "ResultCode": 0,
        "ResultDesc": "The service request is processed successfully.",
        "CallbackMetadata": {"Item": [
            {"Name": "Amount", "Value": 200}, {"Name": "MpesaReceiptNumber", "Value": "TESTRCPT01"},
            {"Name": "PhoneNumber", "Value": 254711000003}]},
    }}}
    assert client.post("/api/mpesa/callback/wrong", json=payload).status_code == 404
    assert client.post("/api/mpesa/callback/cb-secret", json=payload).json()["ResultCode"] == 0
    client.post("/api/mpesa/callback/cb-secret", json=payload)  # Daraja may retry
    wallet = client.get("/api/wallet", headers=_auth(token)).json()
    assert wallet["balance"] == 200 and wallet["history"][0]["ref"] == "TESTRCPT01"


# ------------------------------------------------------------------ gate config
def test_gate_config_reports_fare_mode(client):
    rail = client.get("/api/validator/config", headers=K[CENTRAL]).json()
    assert (rail["mode"], rail["fare"], rail["station"]) == ("distance", 80, "Nairobi Central")
    assert client.get("/api/validator/config", headers=K[MAKADARA]).json()["fare"] == 60  # shorter maximum
    feeder = client.get("/api/validator/config", headers=K[FEEDER]).json()
    assert (feeder["mode"], feeder["fare"]) == ("flat", 30)


# ------------------------------------------------------------------ flat-fare stop (feeder)
def test_flat_fare_charges_once_and_exit_scan_is_ignored(client):
    token = _rider(client, topup=100)
    qr = _pass(client, token)
    tap_id = uuid.uuid4().hex
    first = _tap(client, FEEDER, qr, "in", tap_id=tap_id)
    assert (first["status"], first["fare"], first["balance"]) == ("charged", 30, 70)
    again = _tap(client, FEEDER, qr, "in", tap_id=tap_id)
    assert again["duplicate"] is True and again["balance"] == 70
    out = _tap(client, FEEDER, qr, "out")
    assert (out["status"], out["reason"]) == ("ignored", "flat_fare")
    assert _balance(client, token) == 70


# ------------------------------------------------------------------ distance fares
def test_distance_journey_holds_maximum_then_settles_exact_fare(client):
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    entry = _tap(client, CENTRAL, qr, "in")
    assert (entry["status"], entry["fare"], entry["balance"]) == ("open", 80, 420)
    exit_ = _tap(client, GITHURAI, qr, "out")  # same pass may leave as well as enter
    assert (exit_["status"], exit_["fare"], exit_["refund"], exit_["balance"]) == ("settled", 45, 35, 455)
    assert (exit_["from_station"], exit_["to_station"]) == ("Nairobi Central", "Githurai")
    labels = [h["label"] for h in client.get("/api/wallet", headers=_auth(token)).json()["history"]]
    assert "Fare held from Nairobi Central" in labels and "Refund: Nairobi Central to Githurai" in labels


def test_different_boarding_and_exit_points_pay_different_fares(client):
    cases = [  # (board gate, exit gate, held maximum, exact fare)
        (CENTRAL, THIKA, 80, 80),    # whole line: no refund
        (MAKADARA, RUIRU, 60, 45),   # two stops
        (THIKA, MAKADARA, 80, 60),   # reverse direction, three stops
        (GITHURAI, RUIRU, 45, 30),   # one stop
    ]
    for board, leave, held, exact in cases:
        token = _rider(client, topup=500)
        entry, exit_ = _journey(client, token, board, leave)
        assert entry["fare"] == held and exit_["fare"] == exact and exit_["refund"] == held - exact
        assert _balance(client, token) == 500 - exact


def test_exit_at_the_entry_station_cancels_with_full_refund(client):
    token = _rider(client, topup=300)
    entry, exit_ = _journey(client, token, CENTRAL, CENTRAL)
    assert entry["status"] == "open"
    assert (exit_["status"], exit_["reason"], exit_["fare"], exit_["refund"]) == ("cancelled", "same_station", 0, 80)
    assert _balance(client, token) == 300


def test_entry_and_exit_synced_by_two_different_devices(client):
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    now = datetime.now(timezone.utc)
    taps = [  # sent out of order on purpose: the server sorts by tap time
        {"tap_id": uuid.uuid4().hex, "pass_token": qr, "tapped_at": _iso(now), "direction": "out"},
        {"tap_id": uuid.uuid4().hex, "pass_token": qr, "tapped_at": _iso(now - timedelta(minutes=2)), "direction": "in"},
    ]
    # the in-tap and out-tap come from different stations, so use two devices
    r1 = client.post("/api/taps/sync", json={"taps": [taps[1]]}, headers=K[CENTRAL]).json()["results"][0]
    r2 = client.post("/api/taps/sync", json={"taps": [taps[0]]}, headers=K[RUIRU]).json()["results"][0]
    assert r1["status"] == "open" and (r2["status"], r2["fare"]) == ("settled", 60)
    assert _balance(client, token) == 440


def test_exit_that_syncs_before_its_entry_is_matched_later(client):
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    now = datetime.now(timezone.utc)
    early = _tap(client, GITHURAI, qr, "out", when=now)  # exit device synced first
    assert (early["status"], early["reason"]) == ("orphan", "no_tap_in")
    assert _balance(client, token) == 500  # nothing charged yet
    entry = _tap(client, CENTRAL, qr, "in", when=now - timedelta(minutes=3))
    assert entry["status"] == "charged" and entry["fare"] == 45  # settled the moment the entry arrived
    assert _balance(client, token) == 455


def test_missed_tap_out_is_closed_at_the_maximum_fare(client):
    from app.db import SessionLocal
    from app.models import Trip

    token = _rider(client, topup=500)
    now = datetime.now(timezone.utc)
    qr1, qr2 = _pass(client, token), _pass(client, token)
    first = _tap(client, CENTRAL, qr1, "in", when=now - timedelta(minutes=4))
    second = _tap(client, MAKADARA, qr2, "in", when=now)  # boards again without ever tapping out
    assert first["status"] == "open" and second["status"] == "open"
    with SessionLocal() as db:
        trip = db.get(Trip, first["tap_id"])
        assert (trip.status, trip.reason, trip.fare) == ("charged", "no_tap_out", 80)
    assert _balance(client, token) == 500 - 80 - 60


def test_stale_open_journeys_are_closed_and_flagged(client):
    from app.db import SessionLocal
    from app.models import Rider, Trip
    from app.timeutil import utcnow
    from app import ledger

    token = _rider(client, topup=500)
    phone = client.get("/api/wallet", headers=_auth(token)).json()["phone"]
    trip_id = uuid.uuid4().hex
    with SessionLocal() as db:
        rider = db.query(Rider).filter(Rider.phone == phone).one()
        old = utcnow() - timedelta(hours=7)
        db.add(Trip(id=trip_id, rider_id=rider.id, station_id=1, operator_id=1, pass_jti="x" + trip_id[:10], tapped_at=old,
                    received_at=old, fare=80, hold=80, status="open"))
        db.flush()
        ledger.post(db, rider.id, -80, "fare", trip_id)
        db.commit()
    h = _operator(client)
    flags = client.get("/api/operator/flags", headers=h).json()["flags"]  # also closes stale journeys
    assert any(f["trip_id"] == trip_id and "missed_tap_out" in f["reasons"] for f in flags)
    with SessionLocal() as db:
        assert db.get(Trip, trip_id).status == "charged"


def test_exit_without_any_entry_is_flagged_after_an_hour(client):
    from app.db import SessionLocal
    from app.models import Rider, TapOut
    from app.timeutil import utcnow

    token = _rider(client)
    phone = client.get("/api/wallet", headers=_auth(token)).json()["phone"]
    out_id = uuid.uuid4().hex
    with SessionLocal() as db:
        rider = db.query(Rider).filter(Rider.phone == phone).one()
        t = utcnow() - timedelta(hours=2)
        db.add(TapOut(id=out_id, rider_id=rider.id, station_id=4, operator_id=1, pass_jti="y" + out_id[:10], tapped_at=t,
                      received_at=t, status="orphan", reason="no_tap_in"))
        db.commit()
    flags = client.get("/api/operator/flags", headers=_operator(client)).json()["flags"]
    assert any(f["trip_id"] == out_id and f["reasons"] == ["exit_without_entry"] for f in flags)


def test_the_held_maximum_must_fit_inside_the_overdraft(client):
    poor = _rider(client, topup=20)   # 20 - 80 = -60, beyond the KES 50 overdraft
    ok = _rider(client, topup=40)     # 40 - 80 = -40, allowed
    d = _tap(client, CENTRAL, _pass(client, poor))
    a = _tap(client, CENTRAL, _pass(client, ok))
    assert (d["status"], d["reason"]) == ("declined", "insufficient_funds")
    assert (a["status"], a["balance"]) == ("open", -40)
    assert _balance(client, poor) == 20


# ------------------------------------------------------------------ pass checks
def test_replayed_pass_is_rejected_for_entry_and_for_exit(client):
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    assert _tap(client, CENTRAL, qr, "in")["status"] == "open"
    again = _tap(client, MAKADARA, qr, "in")
    assert (again["status"], again["reason"]) == ("rejected", "replayed_pass")
    assert _tap(client, GITHURAI, qr, "out")["status"] == "settled"
    second_exit = _tap(client, RUIRU, qr, "out")
    assert (second_exit["status"], second_exit["reason"]) == ("rejected", "replayed_pass")
    assert _balance(client, token) == 500 - 45


def test_stale_and_forged_passes(client):
    token = _rider(client, topup=500)
    old = _tap(client, CENTRAL, _pass(client, token), when=datetime.now(timezone.utc) - timedelta(hours=3))
    assert (old["status"], old["reason"]) == ("rejected", "stale_pass")
    assert _tap(client, CENTRAL, "x" * 40)["reason"] == "invalid_pass"
    assert _tap(client, CENTRAL, "x" * 40, "out")["reason"] == "invalid_pass"
    assert client.post("/api/taps/sync", json={"taps": []}).status_code == 401
    assert _balance(client, token) == 500


def test_direction_defaults_to_boarding_for_older_devices(client):
    token = _rider(client, topup=100)
    body = {"taps": [{"tap_id": uuid.uuid4().hex, "pass_token": _pass(client, token), "tapped_at": _iso()}]}
    assert client.post("/api/taps/sync", json=body, headers=K[FEEDER]).json()["results"][0]["direction"] == "in"


# ------------------------------------------------------------------ operator
def test_open_journeys_are_not_revenue_until_settled_then_pay_out(client):
    h = _operator(client)
    before = client.get("/api/operator/summary", headers=h).json()
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    _tap(client, CENTRAL, qr, "in")
    mid = client.get("/api/operator/summary", headers=h).json()
    assert mid["open_journeys"] == before["open_journeys"] + 1
    assert mid["unpaid_revenue"] == before["unpaid_revenue"]  # still only a hold
    _tap(client, THIKA, qr, "out")
    after = client.get("/api/operator/summary", headers=h).json()
    assert after["unpaid_revenue"] == before["unpaid_revenue"] + 80
    assert after["open_journeys"] == before["open_journeys"]
    payout = client.post("/api/operator/payouts/run", headers=h).json()
    assert payout["gross"] == after["unpaid_revenue"] and payout["gross"] == payout["fee"] + payout["net"]
    assert client.post("/api/operator/payouts/run", headers=h).status_code == 409
    assert client.get("/api/operator/payouts", headers=h).json()["payouts"][0]["id"] == payout["id"]
    assert client.get("/api/operator/summary", headers=_auth(_rider(client))).status_code == 403


def test_fraud_flags_and_demand_on_seeded_history(client):
    from app.db import SessionLocal
    from app.seed import seed_history

    with SessionLocal() as db:
        info = seed_history(db, riders=30, days=10)
    assert info["journeys"] > 100 and info["in_progress"] == 2
    h = _operator(client)
    summary = client.get("/api/operator/summary", headers=h).json()
    flags = client.get("/api/operator/flags", headers=h).json()["flags"]
    reasons = {r for f in flags for r in f["reasons"]}
    assert {"double_tap", "impossible_travel", "rapid_burst", "missed_tap_out"} <= reasons
    assert len(summary["daily"]) == 7 and len(summary["hourly_profile"]) == 24 and summary["forecast_peak_hours"]
    assert summary["open_journeys"] >= 2


# ------------------------------------------------------------------ upgrading an older database
def test_old_database_is_upgraded_in_place(tmp_path):
    from sqlalchemy import create_engine, inspect, text

    from app.db import upgrade_schema

    engine = create_engine(f"sqlite:///{tmp_path}/old.db")
    with engine.begin() as conn:  # the trips table as it was before distance fares
        conn.execute(text("CREATE TABLE trips (id VARCHAR(64) PRIMARY KEY, station_id INTEGER, operator_id INTEGER, "
                          "tapped_at DATETIME, status VARCHAR(12), fare INTEGER)"))
        conn.execute(text("INSERT INTO trips VALUES ('t1', 1, 1, '2026-01-01 08:00:00', 'charged', 50)"))
    added = upgrade_schema(engine)
    assert sorted(added) == ["trips.exit_at", "trips.exit_station_id", "trips.exit_tap_id", "trips.hold"]
    assert upgrade_schema(engine) == []  # running it again changes nothing
    cols = {c["name"] for c in inspect(engine).get_columns("trips")}
    assert {"hold", "exit_station_id", "exit_at", "exit_tap_id"} <= cols
    with engine.begin() as conn:
        assert conn.execute(text("SELECT hold FROM trips WHERE id='t1'")).scalar() == 0  # old rows keep working
