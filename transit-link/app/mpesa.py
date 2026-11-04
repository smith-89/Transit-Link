"""M-Pesa Daraja integration (STK Push) with a mock mode for offline demos.

Linked to: routers/topups (start a push, parse the callback), schemas (phone check).
MPESA_MODE=mock  -> no network; the rider app shows a 'simulate PIN' button.
MPESA_MODE=live  -> real Daraja calls (sandbox or production per MPESA_ENV).
"""
import base64
import re
import secrets
import uuid
from datetime import timedelta

import httpx

from .config import settings
from .timeutil import utcnow


class MpesaError(Exception):
    pass


def normalize_phone(raw: str) -> str:
    """Return 2547XXXXXXXX / 2541XXXXXXXX or raise ValueError."""
    digits = re.sub(r"\D", "", raw or "")
    if digits.startswith("0") and len(digits) == 10:
        digits = "254" + digits[1:]
    elif len(digits) == 9 and digits[0] in "71":
        digits = "254" + digits
    if not re.fullmatch(r"254[17]\d{8}", digits):
        raise ValueError("Enter a Kenyan mobile number such as 0712 345 678.")
    return digits


def _base_url() -> str:
    return "https://api.safaricom.co.ke" if settings.mpesa_env == "production" else "https://sandbox.safaricom.co.ke"


def _access_token() -> str:
    resp = httpx.get(
        f"{_base_url()}/oauth/v1/generate",
        params={"grant_type": "client_credentials"},
        auth=(settings.mpesa_consumer_key, settings.mpesa_consumer_secret),
        timeout=15,
    )
    if resp.status_code != 200:
        raise MpesaError(f"Daraja auth failed ({resp.status_code}). Check consumer key and secret.")
    return resp.json()["access_token"]


def stk_push(phone: str, amount: int, reference: str) -> dict:
    """Start a payment prompt on the rider's phone.

    Returns {"merchant_request_id", "checkout_request_id", "mode"}.
    """
    if settings.mpesa_mode != "live":
        return {
            "merchant_request_id": f"MOCK-M-{uuid.uuid4().hex[:10]}",
            "checkout_request_id": f"ws_CO_MOCK_{uuid.uuid4().hex[:16]}",
            "mode": "mock",
        }
    if not settings.callback_base_url:
        raise MpesaError("CALLBACK_BASE_URL is not set. Daraja needs a public HTTPS URL.")
    timestamp = (utcnow() + timedelta(hours=3)).strftime("%Y%m%d%H%M%S")  # Nairobi time
    password = base64.b64encode(f"{settings.mpesa_shortcode}{settings.mpesa_passkey}{timestamp}".encode()).decode()
    body = {
        "BusinessShortCode": settings.mpesa_shortcode,
        "Password": password,
        "Timestamp": timestamp,
        "TransactionType": "CustomerPayBillOnline",
        "Amount": amount,
        "PartyA": phone,
        "PartyB": settings.mpesa_shortcode,
        "PhoneNumber": phone,
        "CallBackURL": f"{settings.callback_base_url}/api/mpesa/callback/{settings.callback_secret}",
        "AccountReference": reference[:12],
        "TransactionDesc": "Transit Link top-up",
    }
    resp = httpx.post(
        f"{_base_url()}/mpesa/stkpush/v1/processrequest",
        json=body,
        headers={"Authorization": f"Bearer {_access_token()}"},
        timeout=20,
    )
    data = resp.json()
    if resp.status_code != 200 or data.get("ResponseCode") != "0":
        raise MpesaError(data.get("errorMessage") or data.get("ResponseDescription") or "STK push was rejected.")
    return {
        "merchant_request_id": data["MerchantRequestID"],
        "checkout_request_id": data["CheckoutRequestID"],
        "mode": "live",
    }


def parse_callback(payload: dict) -> dict:
    """Flatten Daraja's nested callback into one dict.

    Shape: {"Body": {"stkCallback": {"CheckoutRequestID", "ResultCode", "ResultDesc",
            "CallbackMetadata": {"Item": [{"Name": "...", "Value": ...}, ...]}}}}
    """
    try:
        cb = payload["Body"]["stkCallback"]
        items = {i["Name"]: i.get("Value") for i in cb.get("CallbackMetadata", {}).get("Item", [])}
        return {
            "checkout_request_id": cb["CheckoutRequestID"],
            "result_code": int(cb["ResultCode"]),
            "result_desc": str(cb.get("ResultDesc", ""))[:200],
            "receipt": items.get("MpesaReceiptNumber"),
            "amount": items.get("Amount"),
        }
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("Unrecognised callback payload") from exc


def mock_receipt() -> str:
    return "MOCK" + secrets.token_hex(4).upper()
