"""The wallet ledger: the single source of truth for rider money.

Linked to: trips (fare debits), routers/topups (credits), routers/wallet (balance),
seed. Rules: rows are only ever added; a balance is the SUM of a rider's rows;
(kind, ref) is unique so the same M-Pesa receipt or trip can never post twice.
"""
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .models import LedgerEntry


def balance(db: Session, rider_id: int) -> int:
    return db.scalar(select(func.coalesce(func.sum(LedgerEntry.amount), 0)).where(LedgerEntry.rider_id == rider_id)) or 0


def post(db: Session, rider_id: int, amount: int, kind: str, ref: str) -> LedgerEntry | None:
    """Add a ledger row. Returns None (and does nothing) if (kind, ref) already exists."""
    exists = db.scalar(select(LedgerEntry.id).where(LedgerEntry.kind == kind, LedgerEntry.ref == ref))
    if exists:
        return None
    entry = LedgerEntry(rider_id=rider_id, amount=amount, kind=kind, ref=ref)
    db.add(entry)
    db.flush()
    return entry


def history(db: Session, rider_id: int, limit: int = 30) -> list[LedgerEntry]:
    return list(
        db.scalars(
            select(LedgerEntry)
            .where(LedgerEntry.rider_id == rider_id)
            .order_by(LedgerEntry.created_at.desc(), LedgerEntry.id.desc())
            .limit(limit)
        )
    )
