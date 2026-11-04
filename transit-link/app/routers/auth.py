"""Sign-up and sign-in for riders and operators.

Linked to: security (hash/verify, tokens), models (Rider, Operator), schemas.
"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import Operator, Rider
from ..schemas import LoginIn, OperatorLoginIn, RegisterIn
from ..security import create_access_token, hash_secret, verify_secret

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", status_code=201)
def register(body: RegisterIn, db: Session = Depends(get_db)):
    if db.scalar(select(Rider.id).where(Rider.phone == body.phone)):
        raise HTTPException(409, "That phone number already has an account. Sign in instead.")
    rider = Rider(phone=body.phone, name=body.name.strip(), pin_hash=hash_secret(body.pin))
    db.add(rider)
    db.commit()
    return {"token": create_access_token(rider.id, "rider"), "name": rider.name}


@router.post("/login")
def login(body: LoginIn, db: Session = Depends(get_db)):
    rider = db.scalar(select(Rider).where(Rider.phone == body.phone))
    if rider is None or not verify_secret(body.pin, rider.pin_hash):
        raise HTTPException(401, "Phone number or PIN is wrong.")
    return {"token": create_access_token(rider.id, "rider"), "name": rider.name}


@router.post("/operator/login")
def operator_login(body: OperatorLoginIn, db: Session = Depends(get_db)):
    op = db.scalar(select(Operator).where(Operator.username == body.username))
    if op is None or not verify_secret(body.password, op.password_hash):
        raise HTTPException(401, "Username or password is wrong.")
    return {"token": create_access_token(op.id, "operator"), "name": op.name}
