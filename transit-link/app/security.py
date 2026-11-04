"""Password hashing, JWTs (login tokens and QR passes) and auth dependencies.

Linked to: routers/* (Depends), trips (decode_pass_token), seed (hash_secret).
Two kinds of signed token exist, told apart by the `typ` claim:
  access - proves who is logged in (rider or operator), lasts hours
  pass   - the short-lived QR code a rider shows at a validator, lasts minutes
Validators do not log in; they send their device key in the X-Validator-Key header.
"""
import hashlib
import hmac
import secrets
from datetime import timedelta

import jwt
from fastapi import Depends, Header, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import settings
from .db import get_db
from .models import Operator, Rider, Validator
from .timeutil import utcnow

ALGO = "HS256"
bearer = HTTPBearer(auto_error=False)


# ---- passwords / PINs -------------------------------------------------------
def hash_secret(secret: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", secret.encode(), bytes.fromhex(salt), 120_000)
    return f"pbkdf2_sha256${salt}${digest.hex()}"


def verify_secret(secret: str, stored: str) -> bool:
    try:
        _, salt, expected = stored.split("$")
        digest = hashlib.pbkdf2_hmac("sha256", secret.encode(), bytes.fromhex(salt), 120_000)
    except ValueError:
        return False
    return hmac.compare_digest(digest.hex(), expected)


# ---- tokens -----------------------------------------------------------------
def _epoch(dt) -> int:
    from datetime import timezone

    return int(dt.replace(tzinfo=timezone.utc).timestamp())


def create_access_token(subject: int, role: str) -> str:
    now = utcnow()
    payload = {
        "sub": str(subject),
        "role": role,
        "typ": "access",
        "iat": _epoch(now),
        "exp": _epoch(now + timedelta(hours=settings.access_token_hours)),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=ALGO)


def create_pass_token(rider_id: int) -> tuple[str, int]:
    now = utcnow()
    ttl = settings.pass_ttl_seconds
    payload = {
        "sub": str(rider_id),
        "typ": "pass",
        "jti": secrets.token_hex(8),
        "iat": _epoch(now),
        "exp": _epoch(now + timedelta(seconds=ttl)),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=ALGO), ttl


def decode_pass_token(token: str) -> dict:
    """Verify the signature but NOT the expiry.

    Offline taps are synced later, so 'now' is the wrong clock. The caller checks
    that the tap time falls inside the pass's own validity window instead.
    Raises jwt.PyJWTError when the token is forged or is not a pass.
    """
    claims = jwt.decode(
        token,
        settings.jwt_secret,
        algorithms=[ALGO],
        options={"verify_exp": False, "require": ["sub", "jti", "iat", "exp"]},
    )
    if claims.get("typ") != "pass":
        raise jwt.InvalidTokenError("not a pass token")
    return claims


def _access_claims(creds: HTTPAuthorizationCredentials | None) -> dict:
    if creds is None:
        raise HTTPException(401, "Sign in first.")
    try:
        claims = jwt.decode(creds.credentials, settings.jwt_secret, algorithms=[ALGO])
    except jwt.PyJWTError:
        raise HTTPException(401, "Your session expired. Sign in again.")
    if claims.get("typ") != "access":
        raise HTTPException(401, "Invalid session token.")
    return claims


# ---- FastAPI dependencies -----------------------------------------------------
def current_rider(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer), db: Session = Depends(get_db)
) -> Rider:
    claims = _access_claims(creds)
    rider = db.get(Rider, int(claims["sub"])) if claims.get("role") == "rider" else None
    if rider is None:
        raise HTTPException(403, "Rider access only.")
    return rider


def current_operator(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer), db: Session = Depends(get_db)
) -> Operator:
    claims = _access_claims(creds)
    operator = db.get(Operator, int(claims["sub"])) if claims.get("role") == "operator" else None
    if operator is None:
        raise HTTPException(403, "Operator access only.")
    return operator


def current_validator(
    x_validator_key: str | None = Header(default=None), db: Session = Depends(get_db)
) -> Validator:
    if not x_validator_key:
        raise HTTPException(401, "Missing X-Validator-Key header.")
    validator = db.scalar(select(Validator).where(Validator.api_key == x_validator_key))
    if validator is None:
        raise HTTPException(401, "Unknown validator key.")
    return validator
