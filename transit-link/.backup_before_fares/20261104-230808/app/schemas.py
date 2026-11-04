"""Request bodies (pydantic). Responses are plain dicts to keep the MVP small.

Linked to: routers/*. Phone numbers are normalised through mpesa.normalize_phone.
"""
import re
from datetime import datetime

from pydantic import BaseModel, Field, field_validator

from .mpesa import normalize_phone


class _PhoneMixin(BaseModel):
    phone: str

    @field_validator("phone")
    @classmethod
    def _phone(cls, v: str) -> str:
        return normalize_phone(v)


class RegisterIn(_PhoneMixin):
    name: str = Field(min_length=2, max_length=80)
    pin: str

    @field_validator("pin")
    @classmethod
    def _pin(cls, v: str) -> str:
        if not re.fullmatch(r"\d{4,8}", v):
            raise ValueError("PIN must be 4 to 8 digits.")
        return v


class LoginIn(_PhoneMixin):
    pin: str


class OperatorLoginIn(BaseModel):
    username: str
    password: str


class TopupIn(BaseModel):
    amount: int = Field(gt=0)
    phone: str | None = None

    @field_validator("phone")
    @classmethod
    def _phone(cls, v):
        return normalize_phone(v) if v else None


class TapIn(BaseModel):
    tap_id: str = Field(min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    pass_token: str = Field(min_length=20, max_length=2000)
    tapped_at: datetime


class SyncIn(BaseModel):
    taps: list[TapIn] = Field(max_length=500)
