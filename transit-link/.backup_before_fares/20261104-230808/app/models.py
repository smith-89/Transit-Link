"""Database tables. See docs/DATA_MODEL.md for the diagram.

Linked to: ledger, trips, payouts, fraud, analytics, seed and all routers.
Design rule: balances are NEVER stored. A rider's balance is the sum of their
wallet_ledger rows, which only ever receive new rows.
"""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base
from .timeutil import utcnow


class Rider(Base):
    __tablename__ = "riders"
    id: Mapped[int] = mapped_column(primary_key=True)
    phone: Mapped[str] = mapped_column(String(15), unique=True, index=True)  # 2547XXXXXXXX
    name: Mapped[str] = mapped_column(String(80))
    pin_hash: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Operator(Base):
    __tablename__ = "operators"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    username: Mapped[str] = mapped_column(String(40), unique=True)
    password_hash: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Station(Base):
    """A boarding point. MVP fares are flat per boarding station (tap-in only)."""

    __tablename__ = "stations"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    order_index: Mapped[int] = mapped_column(Integer, default=0)
    fare: Mapped[int] = mapped_column(Integer, default=50)  # KES


class Validator(Base):
    """A scanning device (phone or laptop) fixed to one operator and one station."""

    __tablename__ = "validators"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    api_key: Mapped[str] = mapped_column(String(64), unique=True)
    operator_id: Mapped[int] = mapped_column(ForeignKey("operators.id"))
    station_id: Mapped[int] = mapped_column(ForeignKey("stations.id"))


class Topup(Base):
    __tablename__ = "topups"
    id: Mapped[int] = mapped_column(primary_key=True)
    rider_id: Mapped[int] = mapped_column(ForeignKey("riders.id"), index=True)
    amount: Mapped[int] = mapped_column(Integer)
    phone: Mapped[str] = mapped_column(String(15))
    checkout_request_id: Mapped[str] = mapped_column(String(80), unique=True)
    merchant_request_id: Mapped[str | None] = mapped_column(String(80), nullable=True)
    status: Mapped[str] = mapped_column(String(10), default="pending")  # pending|success|failed
    mpesa_receipt: Mapped[str | None] = mapped_column(String(30), nullable=True)
    result_desc: Mapped[str | None] = mapped_column(String(200), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class LedgerEntry(Base):
    __tablename__ = "wallet_ledger"
    __table_args__ = (UniqueConstraint("kind", "ref", name="uq_ledger_kind_ref"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    rider_id: Mapped[int] = mapped_column(ForeignKey("riders.id"), index=True)
    amount: Mapped[int] = mapped_column(Integer)  # +credit / -debit
    kind: Mapped[str] = mapped_column(String(20))  # topup | fare | adjustment
    ref: Mapped[str] = mapped_column(String(80))  # M-Pesa receipt or trip id
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Payout(Base):
    __tablename__ = "payouts"
    id: Mapped[int] = mapped_column(primary_key=True)
    operator_id: Mapped[int] = mapped_column(ForeignKey("operators.id"), index=True)
    period_start: Mapped[datetime] = mapped_column(DateTime)
    period_end: Mapped[datetime] = mapped_column(DateTime)
    trips_count: Mapped[int] = mapped_column(Integer)
    gross: Mapped[int] = mapped_column(Integer)
    fee: Mapped[int] = mapped_column(Integer)
    net: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(20), default="simulated_paid")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Trip(Base):
    """One scan. The id is generated on the validator, which makes sync idempotent."""

    __tablename__ = "trips"
    __table_args__ = (Index("ix_trips_op_time", "operator_id", "tapped_at"),)
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    rider_id: Mapped[int | None] = mapped_column(ForeignKey("riders.id"), nullable=True, index=True)
    validator_id: Mapped[int | None] = mapped_column(ForeignKey("validators.id"), nullable=True)
    station_id: Mapped[int] = mapped_column(ForeignKey("stations.id"))
    operator_id: Mapped[int] = mapped_column(ForeignKey("operators.id"))
    pass_jti: Mapped[str] = mapped_column(String(64), default="", index=True)
    tapped_at: Mapped[datetime] = mapped_column(DateTime, index=True)
    received_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    fare: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[str] = mapped_column(String(12))  # charged | declined | rejected
    reason: Mapped[str | None] = mapped_column(String(40), nullable=True)
    payout_id: Mapped[int | None] = mapped_column(ForeignKey("payouts.id"), nullable=True)
