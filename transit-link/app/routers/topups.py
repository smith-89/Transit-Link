"""M-Pesa top-ups: start a payment, receive the result, credit the ledger.

Linked to: mpesa (STK push and callback parsing), ledger (credit), models.Topup.
Flow: POST /topups -> STK prompt on phone -> Daraja POSTs /mpesa/callback/{secret}
      -> pending topup becomes success and one ledger credit is posted (once).
"""
import hmac
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import ledger, mpesa
from ..config import settings
from ..db import get_db
from ..models import Rider, Topup
from ..schemas import TopupIn
from ..security import current_rider
from ..timeutil import utcnow

router = APIRouter(tags=["topups"])


def apply_result(db: Session, checkout_request_id: str, result_code: int, result_desc: str, receipt: str | None) -> Topup | None:
    """Settle a pending top-up. Safe to call twice: only a pending top-up changes."""
    topup = db.scalar(select(Topup).where(Topup.checkout_request_id == checkout_request_id))
    if topup is None or topup.status != "pending":
        return topup
    topup.completed_at = utcnow()
    topup.result_desc = result_desc
    if result_code == 0 and receipt:
        topup.status, topup.mpesa_receipt = "success", receipt
        ledger.post(db, topup.rider_id, topup.amount, "topup", receipt)
    else:
        topup.status = "failed"
    db.commit()
    return topup


def _topup_json(t: Topup) -> dict:
    return {"id": t.id, "status": t.status, "amount": t.amount, "receipt": t.mpesa_receipt, "message": t.result_desc}


@router.post("/topups", status_code=201)
def start_topup(body: TopupIn, rider: Rider = Depends(current_rider), db: Session = Depends(get_db)):
    if not settings.min_topup <= body.amount <= settings.max_topup:
        raise HTTPException(422, f"Top up between KES {settings.min_topup} and KES {settings.max_topup}.")
    phone = body.phone or rider.phone
    try:
        push = mpesa.stk_push(phone, body.amount, reference=f"TL{rider.id}")
    except mpesa.MpesaError as exc:
        raise HTTPException(502, str(exc))
    topup = Topup(
        rider_id=rider.id,
        amount=body.amount,
        phone=phone,
        checkout_request_id=push["checkout_request_id"],
        merchant_request_id=push["merchant_request_id"],
    )
    db.add(topup)
    db.commit()
    return {**_topup_json(topup), "mode": push["mode"], "checkout_request_id": topup.checkout_request_id}


@router.get("/topups/{topup_id}")
def topup_status(topup_id: int, rider: Rider = Depends(current_rider), db: Session = Depends(get_db)):
    topup = db.get(Topup, topup_id)
    if topup is None or topup.rider_id != rider.id:
        raise HTTPException(404, "Top-up not found.")
    return _topup_json(topup)


@router.post("/mpesa/callback/{secret}")
async def mpesa_callback(secret: str, request: Request, db: Session = Depends(get_db)):
    """Daraja calls this. The secret in the URL is our only authentication."""
    if not hmac.compare_digest(secret, settings.callback_secret):
        raise HTTPException(404, "Not found")
    try:
        parsed = mpesa.parse_callback(await request.json())
    except ValueError:
        raise HTTPException(400, "Bad callback payload")
    apply_result(db, parsed["checkout_request_id"], parsed["result_code"], parsed["result_desc"], parsed["receipt"])
    return {"ResultCode": 0, "ResultDesc": "Accepted"}  # Daraja expects this acknowledgement


@router.post("/dev/mpesa/confirm/{checkout_request_id}")
def mock_confirm(checkout_request_id: str, success: bool = True, rider: Rider = Depends(current_rider), db: Session = Depends(get_db)):
    """Mock mode only: pretend the rider entered their M-Pesa PIN."""
    if settings.mpesa_mode != "mock":
        raise HTTPException(404, "Not found")
    topup = db.scalar(select(Topup).where(Topup.checkout_request_id == checkout_request_id))
    if topup is None or topup.rider_id != rider.id:
        raise HTTPException(404, "Top-up not found.")
    apply_result(
        db,
        checkout_request_id,
        0 if success else 1032,
        "Simulated success" if success else "Request cancelled by user",
        mpesa.mock_receipt() if success else None,
    )
    return _topup_json(db.get(Topup, topup.id))
