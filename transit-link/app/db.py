"""Database engine, session factory and the FastAPI session dependency.

Linked to: models (Base), every router (get_db), seed/main (init_db).
SQLite is used by default; set DATABASE_URL to use Postgres/Supabase.
"""
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import settings

_connect_args = {"check_same_thread": False} if settings.database_url.startswith("sqlite") else {}
engine = create_engine(settings.database_url, connect_args=_connect_args, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# Columns added after the first release. create_all() creates new TABLES but never adds
# columns to an existing table, so older databases are upgraded here (safe to run repeatedly).
_ADDED_COLUMNS = {
    "trips": [
        ("hold", "INTEGER NOT NULL DEFAULT 0"),
        ("exit_station_id", "INTEGER"),
        ("exit_at", "TIMESTAMP"),
        ("exit_tap_id", "VARCHAR(64)"),
    ],
}


def upgrade_schema(bind=None) -> list[str]:
    """Add any missing columns to existing tables. Returns the columns it added."""
    from sqlalchemy import inspect, text

    bind = bind or engine
    inspector = inspect(bind)
    added: list[str] = []
    with bind.begin() as conn:
        for table, columns in _ADDED_COLUMNS.items():
            if not inspector.has_table(table):
                continue
            existing = {c["name"] for c in inspector.get_columns(table)}
            for name, ddl in columns:
                if name not in existing:
                    conn.execute(text(f"ALTER TABLE {table} ADD COLUMN {name} {ddl}"))
                    added.append(f"{table}.{name}")
    return added


def init_db() -> None:
    from . import models  # noqa: F401  (registers the tables)

    Base.metadata.create_all(engine)
    upgrade_schema()
