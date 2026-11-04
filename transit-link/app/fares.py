"""Fare lookups for distance-based pricing.

Linked to: trips (hold and settle), routers/taps (device config), seed (demo table).
A station with outgoing rows in `fares` is a distance station. Everything else is flat.
"""
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from .models import Fare


def price(db: Session, origin_id: int, destination_id: int) -> int | None:
    """Fare for origin -> destination, or None if the pair is not in the table."""
    return db.scalar(select(Fare.price).where(Fare.from_station_id == origin_id, Fare.to_station_id == destination_id))


def max_fare(db: Session, origin_id: int) -> int | None:
    """The most a journey starting here can cost. None means the station is flat-fare."""
    return db.scalar(select(func.max(Fare.price)).where(Fare.from_station_id == origin_id))


def in_network(db: Session, station_id: int) -> bool:
    """True if the station appears in the fare table as an origin or a destination."""
    return bool(db.scalar(select(Fare.id).where(or_(Fare.from_station_id == station_id, Fare.to_station_id == station_id)).limit(1)))


def set_pair_fares(db: Session, station_ids: list[int], price_by_hops: dict[int, int]) -> int:
    """Create a symmetric fare for every pair of stations on a line, priced by number of stops.
    Existing pairs are left alone. Returns how many rows were added."""
    added = 0
    for i, a in enumerate(station_ids):
        for j, b in enumerate(station_ids):
            if i == j or price(db, a, b) is not None:
                continue
            hops = abs(i - j)
            db.add(Fare(from_station_id=a, to_station_id=b, price=price_by_hops.get(hops, max(price_by_hops.values()))))
            added += 1
    db.flush()
    return added
