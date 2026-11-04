"""End-to-end tests of the MVP showcase flow. Run:  pytest -q"""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import app

KEY1 = {"X-Validator-Key": "demo-validator-key-1"}


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _iso(dt=None):
    return (dt or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z")


def _new_rider(client, phone, topup=0):
    r = client.post("/api/auth/register", json={"phone": phone, "name": "Test Rider", "pin": "4321"})
    assert r.status_code == 201, r.text
    token = r.json()["token"]
    if topup:
        t = client.post("/api/topups", json={"amount": topup}, headers=_auth(token)).json()
        done = client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token)).json()
        assert done["status"] == "success"
    return token


def _tap(client, token, tap_id, when=None):
    qr = client.get("/api/pass", headers=_auth(token)).json()["token"]
    body = {"taps": [{"tap_id": tap_id, "pass_token": qr, "tapped_at": _iso(when)}]}
    return client.post("/api/taps/sync", json=body, headers=KEY1).json()["results"][0], qr


def test_health_and_static(client):
    assert client.get("/api/health").json()["status"] == "ok"
    assert client.get("/rider/").status_code == 200
    assert client.get("/validator/").status_code == 200
    assert client.get("/operator/").status_code == 200


def test_register_login_validation(client):
    token = _new_rider(client, "0711000001")
    assert client.post("/api/auth/login", json={"phone": "0711000001", "pin": "4321"}).status_code == 200
    assert client.post("/api/auth/login", json={"phone": "0711000001", "pin": "0000"}).status_code == 401
    assert client.post("/api/auth/register", json={"phone": "0711000001", "name": "X Y", "pin": "4321"}).status_code == 409
    assert client.post("/api/auth/register", json={"phone": "12345", "name": "X Y", "pin": "4321"}).status_code == 422
    assert client.get("/api/wallet", headers=_auth(token)).json()["balance"] == 0


def test_topup_mock_flow_and_idempotency(client):
    token = _new_rider(client, "0711000002")
    t = client.post("/api/topups", json={"amount": 300}, headers=_auth(token)).json()
    assert t["status"] == "pending" and t["mode"] == "mock"
    client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token))
    client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token))  # twice
    assert client.get("/api/wallet", headers=_auth(token)).json()["balance"] == 300
    assert client.post("/api/topups", json={"amount": 5}, headers=_auth(token)).status_code == 422


def test_daraja_callback(client):
    token = _new_rider(client, "0711000003")
    t = client.post("/api/topups", json={"amount": 200}, headers=_auth(token)).json()
    payload = {
        "Body": {
            "stkCallback": {
                "MerchantRequestID": "x",
                "CheckoutRequestID": t["checkout_request_id"],
                "ResultCode": 0,
                "ResultDesc": "The service request is processed successfully.",
                "CallbackMetadata": {
                    "Item": [
                        {"Name": "Amount", "Value": 200},
                        {"Name": "MpesaReceiptNumber", "Value": "TESTRCPT01"},
                        {"Name": "PhoneNumber", "Value": 254711000003},
                    ]
                },
            }
        }
    }
    assert client.post("/api/mpesa/callback/wrong", json=payload).status_code == 404
    assert client.post("/api/mpesa/callback/cb-secret", json=payload).json()["ResultCode"] == 0
    client.post("/api/mpesa/callback/cb-secret", json=payload)  # Daraja may retry
    wallet = client.get("/api/wallet", headers=_auth(token)).json()
    assert wallet["balance"] == 200
    assert wallet["history"][0]["ref"] == "TESTRCPT01"


def test_tap_charges_once_and_sync_is_idempotent(client):
    token = _new_rider(client, "0711000004", topup=500)
    res, qr = _tap(client, token, "tap-aaaaaaaa-0001")
    assert res["status"] == "charged" and res["fare"] == 50 and res["balance"] == 450
    again = client.post(
        "/api/taps/sync",
        json={"taps": [{"tap_id": "tap-aaaaaaaa-0001", "pass_token": qr, "tapped_at": _iso()}]},
        headers=KEY1,
    ).json()["results"][0]
    assert again["duplicate"] is True and again["balance"] == 450


def test_replayed_pass_is_rejected(client):
    token = _new_rider(client, "0711000005", topup=500)
    first, qr = _tap(client, token, "tap-bbbbbbbb-0001")
    assert first["status"] == "charged"
    second = client.post(
        "/api/taps/sync",
        json={"taps": [{"tap_id": "tap-bbbbbbbb-0002", "pass_token": qr, "tapped_at": _iso()}]},
        headers=KEY1,
    ).json()["results"][0]
    assert second["status"] == "rejected" and second["reason"] == "replayed_pass"
    assert client.get("/api/wallet", headers=_auth(token)).json()["balance"] == 450


def test_stale_and_forged_passes(client):
    token = _new_rider(client, "0711000006", topup=500)
    old, _ = _tap(client, token, "tap-cccccccc-0001", when=datetime.now(timezone.utc) - timedelta(hours=3))
    assert old["status"] == "rejected" and old["reason"] == "stale_pass"
    forged = client.post(
        "/api/taps/sync",
        json={"taps": [{"tap_id": "tap-cccccccc-0002", "pass_token": "x" * 40, "tapped_at": _iso()}]},
        headers=KEY1,
    ).json()["results"][0]
    assert forged["reason"] == "invalid_pass"
    assert client.post("/api/taps/sync", json={"taps": []}).status_code == 401


def test_offline_overdraft_limit(client):
    token = _new_rider(client, "0711000007", topup=60)
    ok, _ = _tap(client, token, "tap-dddddddd-0001")  # 60 -> 10
    ok2, _ = _tap(client, token, "tap-dddddddd-0002")  # 10 -> -40, within the KES 50 overdraft
    no, _ = _tap(client, token, "tap-dddddddd-0003")  # -40 -> -90, beyond the limit
    assert (ok["status"], ok2["status"], no["status"]) == ("charged", "charged", "declined")
    assert no["reason"] == "insufficient_funds"
    assert client.get("/api/wallet", headers=_auth(token)).json()["balance"] == -40


def test_operator_summary_payout_and_scope(client):
    login = client.post("/api/auth/operator/login", json={"username": "rail", "password": "demo1234"})
    assert login.status_code == 200
    h = _auth(login.json()["token"])
    summary = client.get("/api/operator/summary", headers=h).json()
    assert summary["today"]["trips"] >= 1 and summary["unpaid_revenue"] > 0
    unpaid = summary["unpaid_revenue"]
    payout = client.post("/api/operator/payouts/run", headers=h).json()
    assert payout["gross"] == unpaid and payout["gross"] == payout["fee"] + payout["net"]
    assert client.post("/api/operator/payouts/run", headers=h).status_code == 409
    assert client.get("/api/operator/payouts", headers=h).json()["payouts"][0]["id"] == payout["id"]
    # a rider token must not open operator endpoints
    rider_token = _new_rider(client, "0711000008")
    assert client.get("/api/operator/summary", headers=_auth(rider_token)).status_code == 403


def test_fraud_flags_on_seeded_history(client):
    from app.db import SessionLocal
    from app.seed import seed_history

    with SessionLocal() as db:
        info = seed_history(db, riders=30, days=10)
    assert info["normal_trips"] > 100
    h = _auth(client.post("/api/auth/operator/login", json={"username": "rail", "password": "demo1234"}).json()["token"])
    flags = client.get("/api/operator/flags", headers=h).json()["flags"]
    reasons = {r for f in flags for r in f["reasons"]}
    assert {"double_tap", "impossible_travel", "rapid_burst"} <= reasons
    summary = client.get("/api/operator/summary", headers=h).json()
    assert len(summary["daily"]) == 7 and len(summary["hourly_profile"]) == 24
    assert summary["forecast_peak_hours"]
