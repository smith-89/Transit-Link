<#
.SYNOPSIS
    Transit Link patch: distance-based fares (tap-in and tap-out) with refunds.

.DESCRIPTION
    Updates an existing Transit Link project (the first bundle plus the new UI). It adds a fare table,
    exit scans, refunds, a Boarding/Alighting switch on gate screens, "In journeys now" and two new
    flags on the operator dashboard, tests and docs. Start with docs/FARES.md.

    Existing files that differ are copied to .backup_before_fares\ in the project folder before they
    are overwritten. Your .env file and database are not touched. The database upgrades itself the
    next time the app starts.

.PARAMETER Target
    The Transit Link project folder (the one that contains app\ and web\). Default: .\transit-link

.EXAMPLE
    .\transit-link-fares.ps1 -Target .\transit-link
    cd transit-link ; uvicorn app.main:app --reload

.NOTES
    Needs PowerShell 5.1 or newer. Demo data only: fares and stations are not official.
#>
param([string]$Target = "transit-link")

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$root = if ([System.IO.Path]::IsPathRooted($Target)) { $Target } else { Join-Path (Get-Location).Path $Target }
$root = [System.IO.Path]::GetFullPath($root)
$backup = Join-Path $root (".backup_before_fares\" + (Get-Date -Format "yyyyMMdd-HHmmss"))

if (-not (Test-Path (Join-Path $root "app\main.py"))) {
    throw "'$root' does not look like a Transit Link project (app\main.py not found). Use -Target to point at your project folder."
}

function Write-BundleFile([string]$RelPath, [string]$Content) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $RelPath))
    $new = $Content + "`n"
    if (Test-Path $full) {
        $old = [System.IO.File]::ReadAllText($full)
        if ($old -ne $new) {
            $copy = Join-Path $backup $RelPath
            $copyDir = Split-Path $copy -Parent
            if (-not (Test-Path $copyDir)) { New-Item -ItemType Directory -Path $copyDir -Force | Out-Null }
            Copy-Item $full $copy -Force
        }
    }
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $new, $utf8)
    Write-Host "  wrote $RelPath"
}

Write-Host "Applying the distance-fare patch to $root" -ForegroundColor Cyan
$script:count = 0

# ---------------------------------------------------------------------------
# docs/FARES.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/FARES.md' @'
# Distance fares: boarding, alighting and settlement

The first version charged one flat fare for the station where a rider boarded. This version prices a
journey by where it starts and where it ends, and still works when gates are offline.

## How a fare is worked out

| Station type | Boarding scan | Alighting scan |
| --- | --- | --- |
| **Distance** (has rows in the fare table) | The **maximum** fare from that station is held (debited) and the trip is `open` | The exact fare for origin to here is found, the difference is **refunded**, the trip becomes `charged` |
| **Flat** (no rows, for example the feeder stop) | The flat fare is charged at once, trip is `charged` | Ignored (`flat_fare`): nothing to settle |

Why hold the maximum? The gate cannot know where the rider is going, and the rider may never tap out.
Holding the most they could owe means the operator is never short, and the exit scan returns the
difference. This is the same idea used by systems that charge a maximum fare when a rider skips a tap-out.

```mermaid
sequenceDiagram
    participant R as Rider
    participant G1 as Gate at origin
    participant S as Server
    participant G2 as Gate at destination
    R->>G1: shows QR pass
    G1->>S: tap in (direction "in"), synced now or later
    S->>S: debit maximum fare from this station, trip = open
    R->>G2: shows QR pass at the other end
    G2->>S: tap out (direction "out")
    S->>S: look up price(origin, here), refund the difference, trip = charged
```

## Demo fare table (KES)

Priced by number of stops between stations. These are demo values, not official fares.

| Stops apart | 1 | 2 | 3 | 4 |
| --- | --- | --- | --- | --- |
| Fare | 30 | 45 | 60 | 80 |

Stations in order: Nairobi Central, Makadara, Githurai, Ruiru, Thika. Fares are the same in both
directions. The maximum from each station (what is held at boarding): Central 80, Makadara 60,
Githurai 45, Ruiru 60, Thika 80.

Worked example. A rider with KES 500 boards at Nairobi Central (KES 80 held, balance 420) and leaves at
Githurai (fare 45, KES 35 refunded, balance 455). The operator's revenue for the journey is KES 45.

## Rules and edge cases

| Situation | What happens |
| --- | --- |
| Rider never taps out | The held maximum is kept. The trip closes as `charged` with reason `no_tap_out` when the rider next boards, or after `OPEN_TRIP_HOURS` (default 6). The operator sees a `missed_tap_out` flag. |
| Tap out at the station where they boarded | Journey `cancelled`, fully refunded. |
| Exit scan syncs before the boarding scan (two devices, different sync order) | Stored as `orphan`. It is matched automatically when the boarding scan arrives. |
| Exit scan with no boarding scan at all | Stays `orphan`. After an hour it is flagged `exit_without_entry` (the rider may have boarded without tapping). Nothing is charged. |
| Same pass used twice in the same direction | The second scan is rejected as `replayed_pass`. One pass may be used once to board **and** once to exit. |
| Balance too low | The held maximum must fit inside the overdraft (KES 50). Otherwise the boarding scan is `declined`. |
| Station pair missing from the fare table | The held maximum is kept (`no_fare_for_pair`). |
| Open journeys and revenue | An open journey is a hold, not revenue. It counts toward revenue and payouts only after it settles or closes. |

## What the person at the gate does

Distance gates show a **Boarding / Alighting** switch. A gate at a station entrance stays on Boarding,
a gate at an exit stays on Alighting, and a single handheld device can be switched as needed. The choice
is saved on the device, stored with every tap, and survives reloads and offline use. Flat-fare gates show no switch.

## Changing the fares

Fares live in the `fares` table (one row per direction). For the MVP, edit them with a database tool or a
small script. An admin screen is on the roadmap.

```sql
UPDATE fares SET price = 50 WHERE from_station_id = 1 AND to_station_id = 3;
```

## Upgrading an existing database

Start the app as usual. On start-up it adds the new columns to `trips`, creates the `tap_outs` and `fares`
tables, builds the demo fare table if it is empty, and adds the extra demo gate devices. Older trips keep
working. For a clean demo run `python -m app.seed --reset --history`.

## Not included yet

Daily fare capping, peak and off-peak prices, zones, concessions, transfers between operators, and an
inspector mode for on-board checks.

## Tests

`tests/test_flow.py` covers boarding and alighting at different stations, both directions, the maximum
hold and refund, cancel, missed tap-out, late-arriving entry scans, replay protection for entry and exit,
the overdraft rule, flat-fare stops, operator revenue and payouts, the new fraud flags and the database upgrade.
'@
$script:count++

# ---------------------------------------------------------------------------
# app/analytics.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/analytics.py' @'
"""Numbers for the operator dashboard.

Linked to: routers/operator (GET /operator/summary), models, config.
Everything is bucketed in Nairobi time. Aggregation happens in Python over the last
14 days of trips so the same code runs on SQLite and Postgres.
"""
from collections import Counter, defaultdict
from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .config import settings
from .models import Station, Trip
from .timeutil import utcnow


def _local(dt: datetime) -> datetime:
    return dt + timedelta(hours=settings.local_utc_offset_hours)


def summary(db: Session, operator_id: int, now: datetime | None = None) -> dict:
    now = now or utcnow()
    today = _local(now).date()
    trips = list(db.scalars(select(Trip).where(Trip.operator_id == operator_id, Trip.tapped_at >= now - timedelta(days=14))))
    stations = {s.id: s.name for s in db.scalars(select(Station))}

    charged = [t for t in trips if t.status == "charged"]
    today_charged = [t for t in charged if _local(t.tapped_at).date() == today]

    # last 7 local days, oldest first, zeros included
    days = [today - timedelta(days=i) for i in range(6, -1, -1)]
    per_day = {d: [0, 0] for d in days}
    for t in charged:
        d = _local(t.tapped_at).date()
        if d in per_day:
            per_day[d][0] += 1
            per_day[d][1] += t.fare

    by_station: dict[int, list[int]] = defaultdict(lambda: [0, 0])
    for t in charged:
        if _local(t.tapped_at).date() >= days[0]:
            by_station[t.station_id][0] += 1
            by_station[t.station_id][1] += t.fare

    # average trips per local hour of day: a simple demand profile and peak forecast
    hour_totals: Counter = Counter()
    for t in charged:
        hour_totals[_local(t.tapped_at).hour] += 1
    observed_days = max(1, len({_local(t.tapped_at).date() for t in charged}))
    hourly = [round(hour_totals[h] / observed_days, 1) for h in range(24)]
    peaks = [h for h, v in sorted(enumerate(hourly), key=lambda p: -p[1])[:3] if v > 0]

    unpaid = db.scalar(
        select(func.coalesce(func.sum(Trip.fare), 0)).where(
            Trip.operator_id == operator_id, Trip.status == "charged", Trip.payout_id.is_(None)
        )
    )

    open_journeys = db.scalar(select(func.count()).select_from(Trip).where(Trip.operator_id == operator_id, Trip.status == "open"))

    return {
        "open_journeys": open_journeys,
        "today": {
            "trips": len(today_charged),
            "revenue": sum(t.fare for t in today_charged),
            "riders": len({t.rider_id for t in today_charged}),
            "declined": sum(1 for t in trips if t.status == "declined" and _local(t.tapped_at).date() == today),
        },
        "unpaid_revenue": unpaid,
        "daily": [{"date": d.isoformat(), "trips": per_day[d][0], "revenue": per_day[d][1]} for d in days],
        "by_station": sorted(
            ({"station": stations.get(sid, f"#{sid}"), "trips": v[0], "revenue": v[1]} for sid, v in by_station.items()),
            key=lambda r: -r["trips"],
        ),
        "hourly_profile": hourly,
        "forecast_peak_hours": sorted(peaks),
    }
'@
$script:count++

# ---------------------------------------------------------------------------
# app/config.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/config.py' @'
"""Settings, read once from environment variables (and an optional .env file).

Linked to: every other module imports `settings` from here. Nothing here
imports from the rest of the app, so it is the root of the dependency tree.
"""
import os

try:  # .env support is optional
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:  # pragma: no cover
    pass


def _int(name: str, default: int) -> int:
    return int(os.getenv(name, str(default)))


def _float(name: str, default: float) -> float:
    return float(os.getenv(name, str(default)))


class Settings:
    def __init__(self) -> None:
        self.database_url = os.getenv("DATABASE_URL", "sqlite:///./transit_link.db")
        self.jwt_secret = os.getenv("JWT_SECRET", "dev-secret-change-me")
        self.auto_seed = os.getenv("AUTO_SEED", "1") == "1"

        # Money is stored as whole Kenya shillings (M-Pesa STK amounts are integers).
        self.overdraft_limit = _int("OVERDRAFT_LIMIT", 50)
        self.platform_fee_pct = _float("PLATFORM_FEE_PCT", 2.0)
        self.min_topup = _int("MIN_TOPUP", 10)
        self.max_topup = _int("MAX_TOPUP", 10000)

        # QR passes and offline taps
        self.pass_ttl_seconds = _int("PASS_TTL_SECONDS", 120)
        self.tap_tolerance_seconds = _int("TAP_TOLERANCE_SECONDS", 300)
        self.access_token_hours = _int("ACCESS_TOKEN_HOURS", 12)

        # Distance fares: how long a journey may stay open before it is closed at the maximum fare
        self.open_trip_hours = _int("OPEN_TRIP_HOURS", 6)

        # Reporting buckets use Nairobi time (UTC+3, no daylight saving)
        self.local_utc_offset_hours = _int("LOCAL_UTC_OFFSET_HOURS", 3)

        # M-Pesa Daraja
        self.mpesa_mode = os.getenv("MPESA_MODE", "mock")  # mock | live
        self.mpesa_env = os.getenv("MPESA_ENV", "sandbox")  # sandbox | production
        self.mpesa_consumer_key = os.getenv("MPESA_CONSUMER_KEY", "")
        self.mpesa_consumer_secret = os.getenv("MPESA_CONSUMER_SECRET", "")
        self.mpesa_shortcode = os.getenv("MPESA_SHORTCODE", "174379")
        self.mpesa_passkey = os.getenv("MPESA_PASSKEY", "")
        self.callback_base_url = os.getenv("CALLBACK_BASE_URL", "").rstrip("/")
        self.callback_secret = os.getenv("CALLBACK_SECRET", "change-me-too")

        self.cors_origins = [o for o in os.getenv("CORS_ORIGINS", "").split(",") if o]


settings = Settings()
'@
$script:count++

# ---------------------------------------------------------------------------
# app/db.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/db.py' @'
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
'@
$script:count++

# ---------------------------------------------------------------------------
# app/fares.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/fares.py' @'
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
'@
$script:count++

# ---------------------------------------------------------------------------
# app/fraud.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/fraud.py' @'
"""Suspicious-trip detection: transparent rules first, a small ML model second.

Linked to: routers/operator (GET /operator/flags), models, config.
Rules (explainable, always on):
  double_tap         same rider, same station, under 2 minutes after their last trip
  impossible_travel  same rider, DIFFERENT station, under 5 minutes after their last trip
  rapid_burst        4 or more trips by one rider inside an hour
  missed_tap_out     journey closed at the maximum fare because the rider never tapped out
  exit_without_entry an exit scan an hour or more old that no entry scan has matched
Model (optional, needs scikit-learn and 60+ trips):
  IsolationForest over [log gap since last trip, trips in last hour, local hour of day].
  Anything the rules did not already catch but the model scores as an outlier is
  reported as model_outlier. Flags are leads for a human to review, not verdicts.
"""
import math
from collections import deque
from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import settings
from .models import TapOut, Trip
from .timeutil import utcnow

try:
    import numpy as np
    from sklearn.ensemble import IsolationForest
except ImportError:  # the rules still work without scikit-learn
    np = None
    IsolationForest = None

DOUBLE_TAP_SECONDS = 120
IMPOSSIBLE_TRAVEL_SECONDS = 300
BURST_COUNT = 4
BURST_WINDOW_SECONDS = 3600
MIN_TRAIN_ROWS = 60
ORPHAN_GRACE_MINUTES = 60
WEEK = 7 * 86400


def scan(db: Session, operator_id: int, days: int = 14) -> list[dict]:
    since = utcnow() - timedelta(days=days)
    trips = list(
        db.scalars(
            select(Trip)
            .where(
                Trip.operator_id == operator_id,
                Trip.rider_id.is_not(None),
                Trip.status.in_(("charged", "declined")),
                Trip.tapped_at >= since,
            )
            .order_by(Trip.rider_id, Trip.tapped_at)
        )
    )

    rows: list[tuple[Trip, list[str]]] = []
    features: list[list[float]] = []
    prev: Trip | None = None
    window: deque = deque()

    for t in trips:
        if prev is None or prev.rider_id != t.rider_id:
            prev, window = None, deque()
        gap = (t.tapped_at - prev.tapped_at).total_seconds() if prev else None
        while window and (t.tapped_at - window[0]).total_seconds() > BURST_WINDOW_SECONDS:
            window.popleft()
        window.append(t.tapped_at)

        reasons: list[str] = []
        if gap is not None:
            if gap < DOUBLE_TAP_SECONDS and prev.station_id == t.station_id:
                reasons.append("double_tap")
            elif gap < IMPOSSIBLE_TRAVEL_SECONDS and prev.station_id != t.station_id:
                reasons.append("impossible_travel")
        if len(window) >= BURST_COUNT:
            reasons.append("rapid_burst")
        if t.reason == "no_tap_out":
            reasons.append("missed_tap_out")

        local_hour = (t.tapped_at + timedelta(hours=settings.local_utc_offset_hours)).hour
        features.append([math.log1p(min(gap if gap is not None else WEEK, WEEK)), len(window), local_hour])
        rows.append((t, reasons))
        prev = t

    scores: list[float | None] = [None] * len(rows)
    if IsolationForest is not None and len(rows) >= MIN_TRAIN_ROWS:
        x = np.array(features, dtype=float)
        model = IsolationForest(n_estimators=100, contamination=0.02, random_state=42).fit(x)
        labels = model.predict(x)
        raw = -model.score_samples(x)  # higher = more unusual
        for i, (label, score) in enumerate(zip(labels, raw)):
            scores[i] = round(float(score), 3)
            if label == -1 and not rows[i][1]:
                rows[i][1].append("model_outlier")

    flagged = [
        {
            "trip_id": t.id,
            "rider_id": t.rider_id,
            "station_id": t.station_id,
            "tapped_at": t.tapped_at.isoformat() + "Z",
            "fare": t.fare,
            "status": t.status,
            "reasons": reasons,
            "score": scores[i],
        }
        for i, (t, reasons) in enumerate(rows)
        if reasons
    ]
    # exit scans that never found an entry scan (someone may have boarded without tapping in)
    grace = utcnow() - timedelta(minutes=ORPHAN_GRACE_MINUTES)
    for o in db.scalars(
        select(TapOut).where(
            TapOut.operator_id == operator_id,
            TapOut.status == "orphan",
            TapOut.rider_id.is_not(None),
            TapOut.tapped_at >= since,
            TapOut.tapped_at <= grace,
        )
    ):
        flagged.append(
            {
                "trip_id": o.id,
                "rider_id": o.rider_id,
                "station_id": o.station_id,
                "tapped_at": o.tapped_at.isoformat() + "Z",
                "fare": 0,
                "status": "orphan",
                "reasons": ["exit_without_entry"],
                "score": None,
            }
        )
    flagged.sort(key=lambda f: f["tapped_at"], reverse=True)
    return flagged
'@
$script:count++

# ---------------------------------------------------------------------------
# app/models.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/models.py' @'
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


class Fare(Base):
    """Price of a journey from one station to another (one row per direction).
    A station that has outgoing rows uses distance fares: the maximum is held at tap-in and
    the exact fare is settled at tap-out. A station with no rows charges Station.fare flat."""

    __tablename__ = "fares"
    __table_args__ = (UniqueConstraint("from_station_id", "to_station_id", name="uq_fare_pair"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    from_station_id: Mapped[int] = mapped_column(ForeignKey("stations.id"), index=True)
    to_station_id: Mapped[int] = mapped_column(ForeignKey("stations.id"))
    price: Mapped[int] = mapped_column(Integer)  # KES


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
    status: Mapped[str] = mapped_column(String(12))  # open | charged | declined | rejected | cancelled
    reason: Mapped[str | None] = mapped_column(String(40), nullable=True)
    payout_id: Mapped[int | None] = mapped_column(ForeignKey("payouts.id"), nullable=True)
    # distance fares: `hold` is what was debited at tap-in, `fare` is the amount actually kept
    hold: Mapped[int] = mapped_column(Integer, default=0)
    exit_station_id: Mapped[int | None] = mapped_column(ForeignKey("stations.id"), nullable=True)
    exit_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    exit_tap_id: Mapped[str | None] = mapped_column(String(64), nullable=True)


class TapOut(Base):
    """One exit scan. Kept separately so a pass can be used once to enter and once to leave."""

    __tablename__ = "tap_outs"
    id: Mapped[str] = mapped_column(String(64), primary_key=True)  # tap id from the device
    rider_id: Mapped[int | None] = mapped_column(ForeignKey("riders.id"), nullable=True, index=True)
    validator_id: Mapped[int | None] = mapped_column(ForeignKey("validators.id"), nullable=True)
    station_id: Mapped[int] = mapped_column(ForeignKey("stations.id"))
    operator_id: Mapped[int] = mapped_column(ForeignKey("operators.id"), index=True)
    pass_jti: Mapped[str] = mapped_column(String(64), default="", index=True)
    tapped_at: Mapped[datetime] = mapped_column(DateTime, index=True)
    received_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    # settled | cancelled | orphan (no tap-in found yet) | ignored (flat-fare station) | rejected
    status: Mapped[str] = mapped_column(String(12))
    reason: Mapped[str | None] = mapped_column(String(40), nullable=True)
    trip_id: Mapped[str | None] = mapped_column(ForeignKey("trips.id"), nullable=True)
    final_fare: Mapped[int] = mapped_column(Integer, default=0)
    refund: Mapped[int] = mapped_column(Integer, default=0)
'@
$script:count++

# ---------------------------------------------------------------------------
# app/routers/operator.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/routers/operator.py' @'
"""Operator dashboard API.

Linked to: analytics (summary), fraud (flags), payouts (run), models, security.
Every query is scoped to the logged-in operator's own id.
"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import analytics, fraud, payouts, trips
from ..db import get_db
from ..models import Operator, Payout, Station
from ..security import current_operator

router = APIRouter(prefix="/operator", tags=["operator"])


def _close_stale(db: Session) -> None:
    """Journeys still open after OPEN_TRIP_HOURS are closed at the held maximum fare."""
    if trips.close_stale(db):
        db.commit()


def _payout_json(p: Payout) -> dict:
    return {
        "id": p.id,
        "trips": p.trips_count,
        "gross": p.gross,
        "fee": p.fee,
        "net": p.net,
        "status": p.status,
        "created_at": p.created_at.isoformat() + "Z",
    }


@router.get("/summary")
def summary(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    _close_stale(db)
    return {"operator": op.name, **analytics.summary(db, op.id)}


@router.get("/flags")
def flags(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    _close_stale(db)
    stations = {s.id: s.name for s in db.scalars(select(Station))}
    items = fraud.scan(db, op.id)
    for item in items:
        item["station"] = stations.get(item["station_id"], "?")
    return {"flags": items[:100]}


@router.get("/payouts")
def list_payouts(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    rows = db.scalars(select(Payout).where(Payout.operator_id == op.id).order_by(Payout.id.desc()).limit(20))
    return {"payouts": [_payout_json(p) for p in rows]}


@router.post("/payouts/run")
def run_payout(op: Operator = Depends(current_operator), db: Session = Depends(get_db)):
    trips.close_stale(db)
    payout = payouts.run_payout(db, op.id)
    if payout is None:
        raise HTTPException(409, "Nothing to pay out yet. No unpaid trips.")
    db.commit()
    return _payout_json(payout)
'@
$script:count++

# ---------------------------------------------------------------------------
# app/routers/taps.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/routers/taps.py' @'
"""Validator endpoints: fetch device config and sync offline taps (boarding and alighting).

Linked to: trips.process_tap, security.current_validator, models.
"""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from .. import fares, trips
from ..db import get_db
from ..models import Operator, Station, Validator
from ..schemas import SyncIn
from ..security import current_validator
from ..timeutil import to_naive_utc

router = APIRouter(tags=["validator"])


@router.get("/validator/config")
def validator_config(validator: Validator = Depends(current_validator), db: Session = Depends(get_db)):
    station = db.get(Station, validator.station_id)
    operator = db.get(Operator, validator.operator_id)
    top = fares.max_fare(db, station.id)
    return {
        "validator": validator.name,
        "operator": operator.name,
        "station": station.name,
        # "distance": boarding holds the maximum fare and alighting settles the exact one
        # "flat": one fixed fare charged at boarding, no exit scan needed
        "mode": "distance" if top is not None else "flat",
        "fare": top if top is not None else station.fare,
    }


@router.post("/taps/sync")
def sync_taps(body: SyncIn, validator: Validator = Depends(current_validator), db: Session = Depends(get_db)):
    """Process a batch of taps in the order they happened. Safe to re-send."""
    ordered = sorted(body.taps, key=lambda t: to_naive_utc(t.tapped_at))
    results = [
        trips.process_tap(db, validator, t.tap_id, t.pass_token, to_naive_utc(t.tapped_at), t.direction) for t in ordered
    ]
    db.commit()
    return {"results": results}
'@
$script:count++

# ---------------------------------------------------------------------------
# app/routers/wallet.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/routers/wallet.py' @'
"""Rider wallet view and the QR pass.

Linked to: ledger (balance, history), security (create_pass_token), models.
The QR pass is a signed token that expires in minutes, so a screenshot is useless.
"""
from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import ledger
from ..db import get_db
from ..models import Rider, Station, Trip
from ..security import create_pass_token, current_rider

router = APIRouter(tags=["wallet"])


@router.get("/wallet")
def wallet(rider: Rider = Depends(current_rider), db: Session = Depends(get_db)):
    entries = ledger.history(db, rider.id)
    trip_ids = [e.ref for e in entries if e.kind in ("fare", "refund")]
    trips = {t.id: t for t in db.scalars(select(Trip).where(Trip.id.in_(trip_ids)))} if trip_ids else {}
    stations = {s.id: s.name for s in db.scalars(select(Station))}
    items = []
    for e in entries:
        label = "M-Pesa top-up" if e.kind == "topup" else e.kind.capitalize()
        trip = trips.get(e.ref)
        if e.kind == "fare" and trip:
            origin = stations.get(trip.station_id, "station")
            label = f"Fare held from {origin}" if trip.hold else f"Fare from {origin}"
        elif e.kind == "refund" and trip:
            label = f"Refund: {stations.get(trip.station_id, 'station')} to {stations.get(trip.exit_station_id, 'exit')}"
        items.append({"label": label, "amount": e.amount, "kind": e.kind, "at": e.created_at.isoformat() + "Z", "ref": e.ref})
    return {"name": rider.name, "phone": rider.phone, "balance": ledger.balance(db, rider.id), "history": items}


@router.get("/pass")
def qr_pass(rider: Rider = Depends(current_rider)):
    token, ttl = create_pass_token(rider.id)
    return {"token": token, "expires_in": ttl}
'@
$script:count++

# ---------------------------------------------------------------------------
# app/schemas.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/schemas.py' @'
"""Request bodies (pydantic). Responses are plain dicts to keep the MVP small.

Linked to: routers/*. Phone numbers are normalised through mpesa.normalize_phone.
"""
import re
from datetime import datetime
from typing import Literal

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
    direction: Literal["in", "out"] = "in"  # boarding or alighting


class SyncIn(BaseModel):
    taps: list[TapIn] = Field(max_length=500)
'@
$script:count++

# ---------------------------------------------------------------------------
# app/seed.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/seed.py' @'
"""Demo data. Run:  python -m app.seed [--history] [--reset]

Linked to: models, ledger, fares, security (hash_secret), db. main.py calls ensure_demo()
on start-up when AUTO_SEED=1.

  core     2 operators, 6 boarding points, a fare table for the rail line, 6 gate devices and
           1 demo rider (safe to repeat; also tops up older databases with the fare table)
  history  40 simulated riders and 14 days of commuter journeys with injected anomalies, a few
           missed tap-outs and two journeys still in progress, so the dashboard has something to show

All names, stations and fares are DEMO values, not official Kenya Railways data.
Demo logins are printed at the end. Change or remove them before any public deployment.
"""
import random
import sys
import uuid
from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from . import fares, ledger
from .config import settings
from .db import Base, SessionLocal, engine, init_db
from .models import Fare, Operator, Rider, Station, Trip, Validator
from .security import hash_secret
from .timeutil import utcnow

DEMO_RIDER = {"phone": "254712345678", "name": "Demo Rider", "pin": "1234"}
DEMO_OPERATORS = [
    {"name": "Demo Commuter Rail", "username": "rail", "password": "demo1234"},
    {"name": "Demo Feeder Sacco", "username": "sacco", "password": "demo1234"},
]
# (name, flat fare KES, operator index). Rail stations also get a distance fare table (below);
# their flat fare is only a fallback. The feeder stop stays flat.
DEMO_STATIONS = [
    ("Nairobi Central", 80, 0),
    ("Makadara", 60, 0),
    ("Githurai", 45, 0),
    ("Ruiru", 60, 0),
    ("Thika", 80, 0),
    ("Githurai Matatu Stage", 30, 1),
]
RAIL_STATIONS = [name for name, _, op in DEMO_STATIONS if op == 0]
HOP_PRICES = {1: 30, 2: 45, 3: 60, 4: 80}  # KES by number of stops travelled
DEMO_VALIDATORS = [
    {"name": "Rail gate 1 (Nairobi Central)", "api_key": "demo-validator-key-1", "station": 0, "operator": 0},
    {"name": "Feeder matatu 1 (Githurai stage)", "api_key": "demo-validator-key-2", "station": 5, "operator": 1},
    {"name": "Rail gate 2 (Makadara)", "api_key": "demo-validator-key-3", "station": 1, "operator": 0},
    {"name": "Rail gate 3 (Githurai)", "api_key": "demo-validator-key-4", "station": 2, "operator": 0},
    {"name": "Rail gate 4 (Ruiru)", "api_key": "demo-validator-key-5", "station": 3, "operator": 0},
    {"name": "Rail gate 5 (Thika)", "api_key": "demo-validator-key-6", "station": 4, "operator": 0},
]


def seed_core(db: Session) -> bool:
    if db.scalar(select(Operator.id).limit(1)):
        return False
    for o in DEMO_OPERATORS:
        db.add(Operator(name=o["name"], username=o["username"], password_hash=hash_secret(o["password"])))
    db.flush()
    for i, (name, fare, _) in enumerate(DEMO_STATIONS):
        db.add(Station(name=name, order_index=i, fare=fare))
    db.flush()
    rider = Rider(phone=DEMO_RIDER["phone"], name=DEMO_RIDER["name"], pin_hash=hash_secret(DEMO_RIDER["pin"]))
    db.add(rider)
    db.flush()
    ledger.post(db, rider.id, 500, "topup", "SEED-DEMO-TOPUP")
    db.commit()
    return True


def ensure_fares(db: Session) -> int:
    """Create the rail fare table if missing (also upgrades databases made before distance fares)."""
    if db.scalar(select(Fare.id).limit(1)):
        return 0
    stations = {s.name: s.id for s in db.scalars(select(Station))}
    ids = [stations[n] for n in RAIL_STATIONS if n in stations]
    if len(ids) < 2:
        return 0
    added = fares.set_pair_fares(db, ids, HOP_PRICES)
    db.commit()
    return added


def ensure_validators(db: Session) -> int:
    """Add any demo gate devices that are missing (matched by device key)."""
    stations = {s.name: s.id for s in db.scalars(select(Station))}
    operators = {o.username: o.id for o in db.scalars(select(Operator))}
    added = 0
    for v in DEMO_VALIDATORS:
        if db.scalar(select(Validator.id).where(Validator.api_key == v["api_key"])):
            continue
        station = stations.get(DEMO_STATIONS[v["station"]][0])
        operator = operators.get(DEMO_OPERATORS[v["operator"]]["username"])
        if station and operator:
            db.add(Validator(name=v["name"], api_key=v["api_key"], operator_id=operator, station_id=station))
            added += 1
    db.commit()
    return added


def seed_history(db: Session, riders: int = 40, days: int = 14, seed: int = 7) -> dict:
    rng = random.Random(seed)
    rail = db.scalar(select(Operator).where(Operator.username == "rail"))
    stations = [s for s in db.scalars(select(Station).order_by(Station.order_index)) if s.name in RAIL_STATIONS]
    if rail is None or len(stations) < 5:
        raise RuntimeError("Run seed_core first.")
    ensure_fares(db)
    price = {(f.from_station_id, f.to_station_id): f.price for f in db.scalars(select(Fare))}
    pin_hash = hash_secret("0000")  # one hash reused: demo riders all use PIN 0000
    now = utcnow()
    offset = timedelta(hours=settings.local_utc_offset_hours)
    made, anomalies = 0, 0

    def journey(rider: Rider, origin: Station, when, dest: Station | None = None, **extra) -> Trip:
        """A completed journey: charged the exact fare, with an exit scan 20-70 minutes later."""
        dest = dest or max((s for s in stations if s.id != origin.id), key=lambda s: price.get((origin.id, s.id), 0))
        fare = price[(origin.id, dest.id)]
        trip = Trip(
            id=uuid.uuid4().hex, rider_id=rider.id, validator_id=None, station_id=origin.id, operator_id=rail.id,
            pass_jti="seed-" + uuid.uuid4().hex[:12], tapped_at=when, received_at=when, fare=fare, hold=0,
            status="charged", exit_station_id=dest.id, exit_at=when + timedelta(minutes=rng.randint(20, 70)),
            exit_tap_id=uuid.uuid4().hex, **extra,
        )
        db.add(trip)
        db.flush()
        ledger.post(db, rider.id, -fare, "fare", trip.id)
        return trip

    for n in range(riders):
        rider = Rider(phone=f"2547000{n:05d}", name=f"Sim Rider {n + 1}", pin_hash=pin_hash)
        db.add(rider)
        db.flush()
        ledger.post(db, rider.id, 4000, "topup", f"SEED-TOPUP-{rider.id}")
        home, work = rng.sample(stations, 2)
        for d in range(days, -1, -1):  # d=0 is today (only trips already in the past)
            day_local = (now + offset - timedelta(days=d)).replace(hour=0, minute=0, second=0, microsecond=0)
            if day_local.weekday() >= 5 and rng.random() < 0.8:
                continue  # few weekend trips
            for origin, dest, hour_mu in ((home, work, 7.2), (work, home, 17.8)):
                if rng.random() < 0.15:
                    continue
                hour = min(max(rng.gauss(hour_mu, 0.7), 5.0), 22.0)
                when = day_local + timedelta(hours=hour) - offset  # back to UTC
                if when > now:
                    continue
                journey(rider, origin, when, dest)
                made += 1

    # injected anomalies the rules and the model should surface
    victims = list(db.scalars(select(Rider).where(Rider.phone.like("2547000%")).limit(9)))
    for i, rider in enumerate(victims[:6]):
        base = now - timedelta(days=rng.randint(1, 5), hours=rng.randint(0, 3))
        if i % 3 == 0:  # same rider, same station, seconds apart
            journey(rider, stations[0], base, stations[1])
            journey(rider, stations[0], base + timedelta(seconds=25), stations[1])
        elif i % 3 == 1:  # two different stations a minute apart
            journey(rider, stations[1], base, stations[2])
            journey(rider, stations[4], base + timedelta(seconds=70), stations[3])
        else:  # burst: many taps in half an hour
            for k in range(6):
                journey(rider, stations[2], base + timedelta(minutes=5 * k), stations[3])
        anomalies += 1

    # three riders who never tapped out: closed at the maximum fare
    missed = 0
    for rider in victims[6:9]:
        origin = stations[1]
        top = max(price[(origin.id, s.id)] for s in stations if s.id != origin.id)
        when = now - timedelta(days=1, hours=rng.randint(1, 4))
        trip = Trip(
            id=uuid.uuid4().hex, rider_id=rider.id, station_id=origin.id, operator_id=rail.id,
            pass_jti="seed-" + uuid.uuid4().hex[:12], tapped_at=when, received_at=when, fare=top, hold=top,
            status="charged", reason="no_tap_out",
        )
        db.add(trip)
        db.flush()
        ledger.post(db, rider.id, -top, "fare", trip.id)
        missed += 1

    # two journeys in progress right now (maximum fare held, waiting for a tap-out)
    in_progress = 0
    for rider in list(db.scalars(select(Rider).where(Rider.phone.like("2547000%")).offset(10).limit(2))):
        origin = stations[0]
        top = max(price[(origin.id, s.id)] for s in stations if s.id != origin.id)
        when = now - timedelta(minutes=12)
        trip = Trip(
            id=uuid.uuid4().hex, rider_id=rider.id, station_id=origin.id, operator_id=rail.id,
            pass_jti="seed-" + uuid.uuid4().hex[:12], tapped_at=when, received_at=when, fare=top, hold=top, status="open",
        )
        db.add(trip)
        db.flush()
        ledger.post(db, rider.id, -top, "fare", trip.id)
        in_progress += 1
    db.commit()
    return {"riders": riders, "journeys": made, "anomaly_groups": anomalies, "missed_tap_outs": missed, "in_progress": in_progress}


def ensure_demo() -> bool:
    init_db()
    with SessionLocal() as db:
        created = seed_core(db)
        ensure_fares(db)
        ensure_validators(db)
        return created


def main(argv: list[str]) -> None:
    if "--reset" in argv:
        Base.metadata.drop_all(engine)
    init_db()
    with SessionLocal() as db:
        created = seed_core(db)
        print("Core demo data created." if created else "Core demo data already present.")
        fare_rows, gates = ensure_fares(db), ensure_validators(db)
        if fare_rows:
            print(f"Fare table created ({fare_rows} station pairs).")
        if created or gates:
            print(f"Gate devices ready ({len(DEMO_VALIDATORS)}).")
        if "--history" in argv:
            if db.scalar(select(Rider.id).where(Rider.phone.like("2547000%")).limit(1)):
                print("History already present. Use --reset to rebuild.")
            else:
                print("History:", seed_history(db))
    print("\nDemo logins")
    print("  Rider      phone 0712345678   PIN 1234")
    print("  Operator   rail / demo1234    (also: sacco / demo1234)")
    print("  Gates      Account = device ID, no passcode:")
    for v in DEMO_VALIDATORS:
        print(f"             {v['api_key']}  {v['name']}")


if __name__ == "__main__":
    main(sys.argv[1:])
'@
$script:count++

# ---------------------------------------------------------------------------
# app/trips.py
# ---------------------------------------------------------------------------
Write-BundleFile 'app/trips.py' @'
"""Tap processing: turns a scanned QR pass into a journey, charged by distance.

Linked to: security (decode_pass_token), ledger (debits and refunds), fares (price table),
models, routers/taps (calls process_tap for every tap), fraud and analytics (read trips).

Two kinds of tap, chosen on the gate device ("in" = boarding, "out" = alighting):

  TAP-IN   Station has distance fares -> the MAXIMUM fare from that station is debited at once
           and the trip is `open`. Station is flat-fare -> the flat fare is charged and the trip
           is `charged` straight away (no tap-out needed).
  TAP-OUT  The rider's open trip is found, the exact fare for origin -> here is looked up, and the
           difference is refunded: trip becomes `charged` with the final fare.

Checks on every tap, in this order (the first failure wins):
  already seen this tap id?  -> return the stored result (retries are safe)
  pass signature valid?      -> else rejected / invalid_pass
  tap time inside pass window?   -> else rejected / stale_pass
  pass already used (same direction)? -> else rejected / replayed_pass
  rider exists?              -> else rejected / unknown_rider

Edge cases handled:
  - missed tap-out: the open trip is closed at the held maximum fare when the rider next taps in,
    or after OPEN_TRIP_HOURS (see close_stale). Flagged `missed_tap_out`.
  - tap-out arrives before its tap-in (two devices syncing in a different order): stored as
    `orphan`, then matched automatically when the tap-in arrives.
  - tap-out at the station you entered: journey is `cancelled` and fully refunded.
  - a pass can be used once to enter AND once to leave, so a short journey works.
"""
from datetime import datetime, timedelta

import jwt
from sqlalchemy import select
from sqlalchemy.orm import Session

from . import fares, ledger
from .config import settings
from .models import Rider, Station, TapOut, Trip, Validator
from .security import decode_pass_token
from .timeutil import from_epoch, utcnow


def _station_name(db: Session, station_id: int | None) -> str | None:
    if station_id is None:
        return None
    station = db.get(Station, station_id)
    return station.name if station else None


def _result(db, direction, tap_id, status, reason=None, fare=0, refund=0, duplicate=False, balance=None, origin=None, destination=None):
    return {
        "tap_id": tap_id,
        "direction": direction,
        "status": status,
        "reason": reason,
        "fare": fare,
        "refund": refund,
        "duplicate": duplicate,
        "balance": balance,
        "from_station": _station_name(db, origin),
        "to_station": _station_name(db, destination),
    }


def _check_pass(db: Session, pass_token: str, tapped_at: datetime, tap_id: str, replay_model):
    """Validate a pass. Returns (rider or None, pass id, failure reason or None)."""
    try:
        claims = decode_pass_token(pass_token)
    except jwt.PyJWTError:
        return None, "", "invalid_pass"
    jti = claims["jti"]
    rider = db.get(Rider, int(claims["sub"]))
    window = timedelta(seconds=settings.tap_tolerance_seconds)
    if not (from_epoch(claims["iat"]) - window <= tapped_at <= from_epoch(claims["exp"]) + window):
        return rider, jti, "stale_pass"
    if db.scalar(select(replay_model.id).where(replay_model.pass_jti == jti, replay_model.id != tap_id).limit(1)):
        return rider, jti, "replayed_pass"
    if rider is None:
        return None, jti, "unknown_rider"
    return rider, jti, None


def process_tap(db: Session, validator: Validator, tap_id: str, pass_token: str, tapped_at: datetime, direction: str = "in") -> dict:
    for model in (Trip, TapOut):
        existing = db.get(model, tap_id)
        if existing is not None:
            return _duplicate(db, existing)
    if direction == "out":
        return _tap_out(db, validator, tap_id, pass_token, tapped_at)
    return _tap_in(db, validator, tap_id, pass_token, tapped_at)


def _duplicate(db: Session, row) -> dict:
    balance = ledger.balance(db, row.rider_id) if row.rider_id else None
    if isinstance(row, Trip):
        return _result(db, "in", row.id, row.status, row.reason, row.fare, 0, True, balance, row.station_id, row.exit_station_id)
    origin = db.get(Trip, row.trip_id).station_id if row.trip_id else None
    return _result(db, "out", row.id, row.status, row.reason, row.final_fare, row.refund, True, balance, origin, row.station_id)


# ---------------------------------------------------------------- tap-in
def _tap_in(db: Session, validator: Validator, tap_id: str, pass_token: str, tapped_at: datetime) -> dict:
    station = db.get(Station, validator.station_id)
    trip = Trip(
        id=tap_id,
        validator_id=validator.id,
        station_id=station.id,
        operator_id=validator.operator_id,
        tapped_at=tapped_at,
        received_at=utcnow(),
        fare=0,
        hold=0,
        status="rejected",
    )
    rider, jti, reason = _check_pass(db, pass_token, tapped_at, tap_id, Trip)
    trip.pass_jti = jti
    trip.rider_id = rider.id if rider else None

    if reason is not None:
        trip.reason = reason
    else:
        close_open_trips(db, rider.id, before=tapped_at)  # earlier journeys the rider never tapped out of
        top = fares.max_fare(db, station.id)
        amount = top if top is not None else station.fare
        if ledger.balance(db, rider.id) - amount < -settings.overdraft_limit:
            trip.status, trip.reason = "declined", "insufficient_funds"
        else:
            trip.fare = amount
            if top is not None:
                trip.hold, trip.status = amount, "open"  # settled at tap-out
            else:
                trip.status = "charged"  # flat fare, final immediately
            ledger.post(db, rider.id, -amount, "fare", tap_id)

    db.add(trip)
    db.flush()
    if trip.status == "open":
        _match_orphan(db, trip)
    balance = ledger.balance(db, rider.id) if rider else None
    return _result(db, "in", tap_id, trip.status, trip.reason, trip.fare, 0, False, balance, trip.station_id, trip.exit_station_id)


# ---------------------------------------------------------------- tap-out
def _tap_out(db: Session, validator: Validator, tap_id: str, pass_token: str, tapped_at: datetime) -> dict:
    out = TapOut(
        id=tap_id,
        validator_id=validator.id,
        station_id=validator.station_id,
        operator_id=validator.operator_id,
        tapped_at=tapped_at,
        received_at=utcnow(),
        status="rejected",
    )
    rider, jti, reason = _check_pass(db, pass_token, tapped_at, tap_id, TapOut)
    out.pass_jti = jti
    out.rider_id = rider.id if rider else None
    origin = None

    if reason is not None:
        out.reason = reason
        db.add(out)
    elif not fares.in_network(db, out.station_id):
        out.status, out.reason = "ignored", "flat_fare"  # nothing to settle at a flat-fare stop
        db.add(out)
    else:
        trip = db.scalar(
            select(Trip)
            .where(
                Trip.rider_id == rider.id,
                Trip.operator_id == out.operator_id,
                Trip.status == "open",
                Trip.tapped_at <= tapped_at,
                Trip.tapped_at >= tapped_at - timedelta(hours=settings.open_trip_hours),
            )
            .order_by(Trip.tapped_at.desc())
            .limit(1)
        )
        db.add(out)
        if trip is None:
            out.status, out.reason = "orphan", "no_tap_in"  # may be matched when the tap-in syncs
        else:
            origin = trip.station_id
            db.flush()
            _settle(db, trip, out)

    db.flush()
    balance = ledger.balance(db, rider.id) if rider else None
    return _result(db, "out", tap_id, out.status, out.reason, out.final_fare, out.refund, False, balance, origin, out.station_id)


def _settle(db: Session, trip: Trip, out: TapOut) -> None:
    """Close an open trip using an exit scan. Refunds whatever was held above the real fare."""
    if trip.station_id == out.station_id:
        final, trip.status, out.status, out.reason = 0, "cancelled", "cancelled", "same_station"
        trip.reason = "same_station"
    else:
        exact = fares.price(db, trip.station_id, out.station_id)
        if exact is None:  # pair missing from the table: keep the held maximum
            final, trip.reason, out.reason = trip.hold, "no_fare_for_pair", "no_fare_for_pair"
        else:
            final = min(exact, trip.hold)
        trip.status, out.status = "charged", "settled"
    refund = trip.hold - final
    trip.fare = final
    trip.exit_station_id, trip.exit_at, trip.exit_tap_id = out.station_id, out.tapped_at, out.id
    out.trip_id, out.final_fare, out.refund = trip.id, final, refund
    if refund > 0:
        ledger.post(db, trip.rider_id, refund, "refund", trip.id)  # (kind, ref) is unique: refunded once
    db.flush()


def _match_orphan(db: Session, trip: Trip) -> None:
    """A tap-in arrived late: attach the earliest exit scan that was waiting for it."""
    orphan = db.scalar(
        select(TapOut)
        .where(
            TapOut.rider_id == trip.rider_id,
            TapOut.operator_id == trip.operator_id,
            TapOut.status == "orphan",
            TapOut.tapped_at > trip.tapped_at,
            TapOut.tapped_at <= trip.tapped_at + timedelta(hours=settings.open_trip_hours),
        )
        .order_by(TapOut.tapped_at)
        .limit(1)
    )
    if orphan is not None:
        orphan.reason = None
        _settle(db, trip, orphan)


# ---------------------------------------------------------------- open journeys that never closed
def close_open_trips(db: Session, rider_id: int, before: datetime) -> int:
    """Close a rider's earlier open trips at the held maximum fare (they never tapped out)."""
    rows = db.scalars(select(Trip).where(Trip.rider_id == rider_id, Trip.status == "open", Trip.tapped_at < before))
    count = 0
    for trip in rows:
        trip.status, trip.reason = "charged", "no_tap_out"
        count += 1
    return count


def close_stale(db: Session, now: datetime | None = None) -> int:
    """Close every journey still open after OPEN_TRIP_HOURS at its held maximum fare.
    Called before the operator dashboard and payouts read their numbers."""
    cutoff = (now or utcnow()) - timedelta(hours=settings.open_trip_hours)
    count = 0
    for trip in db.scalars(select(Trip).where(Trip.status == "open", Trip.tapped_at < cutoff)):
        trip.status, trip.reason = "charged", "no_tap_out"
        count += 1
    db.flush()
    return count
'@
$script:count++

# ---------------------------------------------------------------------------
# web/operator/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/operator/app.js' @'
/* Operator dashboard. Calls: GET /operator/summary, /operator/flags, /operator/payouts,
   POST /operator/payouts/run. Phones: one view at a time with the pill nav. Desktop: everything at once. */
var session = Session.require('operator');
var token = session && session.token;
var data = null;
var tab = 'revenue';
var selDay = null; // null = pick the busiest day
var timer = null;

var REASON_TEXT = {
  double_tap: 'Charged twice at one point within 2 minutes',
  impossible_travel: 'Two different points within 5 minutes',
  rapid_burst: '4 or more trips in one hour',
  model_outlier: 'Unusual pattern (anomaly model)',
  missed_tap_out: 'Never tapped out: charged the maximum fare',
  exit_without_entry: 'Exit scan with no matching boarding scan',
};

function isDesktop() { return window.matchMedia('(min-width: 1000px)').matches; }

function setView(name) {
  if (isDesktop()) {
    var el = $('v-' + name);
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return;
  }
  document.querySelectorAll('.view').forEach(function (v) { v.classList.toggle('active', v.id === 'v-' + name); });
  document.querySelectorAll('.pillnav button').forEach(function (b) {
    if (b.getAttribute('data-view') === name) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
  });
  window.scrollTo({ top: 0 });
}

function openMenu(on) {
  show($('sheet-back'), on);
  if (on) $('sheet-close').focus(); else $('menu-btn').focus();
}

function li(left, right, extra) {
  var el = document.createElement('li');
  el.append(left, right);
  if (extra) el.appendChild(extra);
  return el;
}

function div(cls, html) {
  var d = document.createElement('div');
  if (cls) d.className = cls;
  if (html !== undefined) d.innerHTML = html;
  return d;
}

function esc(s) { var d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

function renderChart() {
  var days = data.summary.daily;
  var values = days.map(function (d) { return d[tab]; });
  var total = values.reduce(function (a, b) { return a + b; }, 0);
  if (selDay === null) selDay = values.lastIndexOf(Math.max.apply(null, values));
  $('chart-total').innerHTML = (tab === 'revenue' ? '<small>KES</small>' : '') + kes(total);
  barChart($('chart'), {
    labels: days.map(function (d) { return dayShort(d.date + 'T12:00:00Z'); }),
    values: values,
    selected: selDay,
    fmt: function (v) { return (tab === 'revenue' ? 'KES ' : '') + kes(v) + (tab === 'trips' ? ' trips' : ''); },
    onSelect: function (i) { selDay = i; renderChart(); },
  });
}

function render() {
  var s = data.summary;
  $('op-name').textContent = s.operator;
  $('sheet-name').textContent = s.operator;
  $('rev').textContent = kes(s.today.revenue);
  $('rev-delta').textContent = s.today.trips + ' trips · ' + s.today.riders + ' riders';
  $('t-unpaid').textContent = kes(s.unpaid_revenue);
  $('t-riders').textContent = kes(s.today.riders);
  $('t-declined').textContent = kes(s.today.declined);
  $('t-open').textContent = kes(s.open_journeys);
  renderChart();

  // demand by hour, with the busiest hours solid
  barChart($('hourly'), {
    labels: s.hourly_profile.map(function (_, h) { return String(h); }),
    values: s.hourly_profile,
    highlight: s.forecast_peak_hours,
    fmt: function (v) { return v + ' trips on a typical day'; },
    compact: true, labelEvery: 3,
  });
  $('peaks').textContent = s.forecast_peak_hours.length
    ? 'Expect the busiest hours around ' + s.forecast_peak_hours.map(function (h) { return String(h).padStart(2, '0') + ':00'; }).join(', ') + ' (Nairobi time, solid bars).'
    : 'Not enough trips yet to show a pattern.';

  // boarding points
  var ul = $('stations');
  ul.innerHTML = '';
  var top = Math.max.apply(null, [1].concat(s.by_station.map(function (r) { return r.trips; })));
  s.by_station.forEach(function (r) {
    var meter = div('meter thin on-dark');
    meter.innerHTML = '<i style="width:' + Math.round((r.trips / top) * 100) + '%"></i>';
    ul.appendChild(li(div('', '<div style="font-size:1.1rem">' + esc(r.station) + '</div><div class="muted small">KES ' + kes(r.revenue) + '</div>'), div('big', kes(r.trips) + ' <span class="muted small">trips</span>'), meter));
  });
  show($('stations-empty'), s.by_station.length === 0);

  // flags
  var fl = $('flags');
  fl.innerHTML = '';
  data.flags.slice(0, 40).forEach(function (f) {
    var tags = f.reasons.map(function (r) { return '<span class="tag">' + esc(REASON_TEXT[r] || r) + '</span>'; }).join('');
    var left = div('', tags + '<div class="flag-meta">Rider #' + f.rider_id + ' · ' + esc(f.station) + ' · ' + whenFull(f.tapped_at) + '</div>');
    var right = div('muted small', f.score !== null ? 'score ' + f.score : '');
    fl.appendChild(li(left, right));
  });
  show($('flags-empty'), data.flags.length === 0);

  // payouts
  var pl = $('payouts');
  pl.innerHTML = '';
  data.payouts.forEach(function (p) {
    pl.appendChild(li(div('', '<div style="font-size:1.1rem">' + whenFull(p.created_at) + '</div><div class="muted small">' + p.trips + ' trips · fee KES ' + kes(p.fee) + '</div>'), div('big', '<small class="muted" style="font-size:.5em">KES</small> ' + kes(p.net))));
  });
  show($('payouts-empty'), data.payouts.length === 0);
}

async function load() {
  var r;
  try {
    r = await Promise.all([
      api('/operator/summary', { token: token }),
      api('/operator/flags', { token: token }),
      api('/operator/payouts', { token: token }),
    ]);
  } catch (err) {
    if (err.status === 401 || err.status === 403) Session.signOut();
    return; // offline or server error: keep what is on screen and retry on the next refresh
  }
  data = { summary: r[0], flags: r[1].flags, payouts: r[2].payouts };
  render();
}

function payoutMsg(text, kind) { say($('payout-msg'), text, kind); say($('payout-msg2'), text, kind); }

async function runPayout() {
  document.querySelectorAll('.payout-btn').forEach(function (b) { b.disabled = true; });
  try {
    var p = await api('/operator/payouts/run', { method: 'POST', token: token });
    payoutMsg('Simulated payout of KES ' + kes(p.net) + ' for ' + p.trips + ' trips (fee KES ' + kes(p.fee) + '). No real money moved.', 'ok');
    load();
  } catch (err) {
    payoutMsg(err.message, 'err');
  } finally {
    document.querySelectorAll('.payout-btn').forEach(function (b) { b.disabled = false; });
  }
}

function start() {
  mountIcons();
  document.querySelectorAll('[data-view]').forEach(function (b) { b.onclick = function () { setView(b.getAttribute('data-view')); }; });
  document.querySelectorAll('[data-go]').forEach(function (b) { b.onclick = function () { setView(b.getAttribute('data-go')); }; });
  document.querySelectorAll('[data-tab]').forEach(function (c) {
    c.onclick = function () {
      tab = c.getAttribute('data-tab');
      selDay = null;
      document.querySelectorAll('[data-tab]').forEach(function (x) { x.setAttribute('aria-pressed', x === c ? 'true' : 'false'); });
      if (data) renderChart();
    };
  });
  document.querySelectorAll('.payout-btn').forEach(function (b) { b.onclick = runPayout; });
  $('refresh').onclick = load;
  $('menu-btn').onclick = function () { openMenu(true); };
  $('sheet-close').onclick = function () { openMenu(false); };
  $('sheet-back').onclick = function (e) { if (e.target === $('sheet-back')) openMenu(false); };
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') openMenu(false); });
  $('signout').onclick = Session.signOut;
  load();
  timer = setInterval(function () { if (!document.hidden) load(); }, 15000);
}

if (session) start();
'@
$script:count++

# ---------------------------------------------------------------------------
# web/operator/index.html
# ---------------------------------------------------------------------------
Write-BundleFile 'web/operator/index.html' @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Operator · Transit Link</title>
  <meta name="theme-color" content="#1c2120">
  <link rel="stylesheet" href="../shared/theme.css">
  <style>
    .ogrid { display: block; }
    .ogrid .col > * + * { margin-top: 18px; }
    .card h2 { font-size: 1.35rem; font-weight: 400; letter-spacing: -.02em; }
    .flag-meta { font-size: .95rem; color: var(--muted); }
    .greeting { font-size: 1.1rem; color: var(--muted); }
    @media (min-width: 1000px) {
      .ogrid { display: grid; grid-template-columns: minmax(0, 1.2fr) minmax(0, 1fr); gap: 28px; align-items: start; }
    }
  </style>
</head>
<body>
  <div class="page wide">
    <header class="appbar">
      <button class="icon-btn" id="menu-btn" type="button" aria-label="Open menu" aria-haspopup="true"><span data-icon="dots"></span></button>
      <div class="mid greeting" id="op-name"></div>
      <button class="icon-btn" id="refresh" type="button" aria-label="Refresh"><span data-icon="refresh"></span></button>
    </header>

    <div class="ogrid">
      <div class="col">
        <section class="view active" id="v-overview" aria-label="Overview">
          <div class="label">Revenue today (KES)</div>
          <div class="row wrap" style="align-items:flex-end;gap:12px;margin-top:8px">
            <div class="display xl" id="rev">0</div>
            <span class="delta" id="rev-delta" style="margin-bottom:8px"></span>
          </div>
          <div class="row" style="margin:22px 0 12px">
            <button class="icon-btn lg" type="button" data-go="demand" aria-label="See demand"><span data-icon="chart"></span></button>
            <button class="icon-btn lg" type="button" data-go="flags" aria-label="See suspicious trips"><span data-icon="alert"></span></button>
            <button class="btn btn-white grow payout-btn" type="button" style="height:58px"><span data-icon="cash" data-size="22"></span> Run payout</button>
          </div>
          <div id="payout-msg" class="note hidden" role="status" style="margin-bottom:14px"></div>

          <div class="card card-lime">
            <div class="row spread">
              <div class="chips" role="group" aria-label="Chart type">
                <button class="chip" type="button" data-tab="revenue" aria-pressed="true">Revenue</button>
                <button class="chip" type="button" data-tab="trips" aria-pressed="false">Trips</button>
              </div>
              <span class="small muted">Last 7 days</span>
            </div>
            <div class="small muted" style="margin-top:18px">Total</div>
            <div class="display lg" id="chart-total" style="margin-top:4px">0</div>
            <div id="chart"></div>
          </div>

          <div class="tiles" style="margin-top:14px">
            <div class="tile glass"><span class="icon-btn dark sm" data-icon="cash" data-size="20"></span><div class="k">Unpaid to operator</div><div class="v" id="t-unpaid">0</div></div>
            <div class="tile lime"><span class="icon-btn dark sm" data-icon="user" data-size="20"></span><div class="k">Riders today</div><div class="v" id="t-riders">0</div></div>
            <div class="tile white"><span class="icon-btn dark sm" data-icon="alert" data-size="20"></span><div class="k">Declined today</div><div class="v" id="t-declined">0</div></div>
            <div class="tile glass"><span class="icon-btn dark sm" data-icon="train" data-size="20"></span><div class="k">In journeys now</div><div class="v" id="t-open">0</div></div>
          </div>
        </section>

        <section class="view" id="v-flags" aria-label="Suspicious trips">
          <div class="card card-glass">
            <h2>Suspicious trips</h2>
            <p class="muted small" style="margin:6px 0 12px">Leads to review, not verdicts. Found by simple rules plus an anomaly model.</p>
            <ul class="rows" id="flags"></ul>
            <div class="empty hidden" id="flags-empty">Nothing suspicious in the last 14 days.</div>
          </div>
        </section>
      </div>

      <div class="col">
        <section class="view" id="v-demand" aria-label="Demand">
          <div class="card card-white">
            <h2>Typical demand by hour</h2>
            <p class="muted small" id="peaks" style="margin-top:6px"></p>
            <div id="hourly" style="margin-top:6px"></div>
          </div>
          <div class="card card-glass" style="margin-top:18px">
            <h2>Boarding points</h2>
            <ul class="rows" id="stations" style="margin-top:8px"></ul>
            <div class="empty hidden" id="stations-empty">No trips yet.</div>
          </div>
        </section>

        <section class="view" id="v-payouts" aria-label="Payouts">
          <div class="card card-glass">
            <div class="row spread wrap" style="margin-bottom:8px">
              <div><h2>Payouts</h2><p class="muted small">Simulated. No real money moves.</p></div>
              <button class="btn btn-white btn-sm payout-btn" type="button">Run payout</button>
            </div>
            <div id="payout-msg2" class="note hidden" role="status"></div>
            <ul class="rows" id="payouts"></ul>
            <div class="empty hidden" id="payouts-empty">No payouts yet.</div>
          </div>
        </section>
      </div>
    </div>
  </div>

  <nav class="pillnav" aria-label="Main">
    <button type="button" data-view="overview" aria-label="Overview" aria-current="page"><span data-icon="grid"></span></button>
    <button type="button" data-view="demand" aria-label="Demand"><span data-icon="chart"></span></button>
    <button type="button" data-view="flags" aria-label="Suspicious trips"><span data-icon="alert"></span></button>
    <button type="button" data-view="payouts" aria-label="Payouts"><span data-icon="cash"></span></button>
  </nav>

  <div class="sheet-back hidden" id="sheet-back">
    <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="sheet-name">
      <div class="row spread"><div><div id="sheet-name" style="font-size:1.4rem;font-weight:500;letter-spacing:-.02em"></div><div class="muted small">Operator dashboard</div></div>
        <button class="icon-btn dark sm" id="sheet-close" type="button" aria-label="Close"><span data-icon="plus" data-size="20" style="display:block;transform:rotate(45deg)"></span></button></div>
      <button class="btn btn-black btn-block" id="signout" type="button" style="margin-top:20px"><span data-icon="logout" data-size="20"></span> Sign out</button>
    </div>
  </div>

  <script src="../shared/api.js"></script>
  <script src="../shared/ui.js"></script>
  <script src="app.js"></script>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/rider/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/rider/app.js' @'
/* Rider app. Calls: GET /wallet, GET /pass, POST /topups, GET /topups/{id},
   POST /dev/mpesa/confirm/{checkout_request_id} (demo mode only).
   Phones show one view at a time with the pill nav; desktop shows every view at once. */
var PASS_REFRESH = 60;     // seconds between new QR codes
var session = Session.require('rider');
var token = session && session.token;
var wallet = null;
var tab = 'spent';
var selDay = null; // null = pick the busiest day
var qr = null;
var passLeft = PASS_REFRESH;
var pollTimer = null;
var currentTopup = null;

function isDesktop() { return window.matchMedia('(min-width: 1000px)').matches; }

/* ---------- navigation ---------- */
function setView(name) {
  if (isDesktop()) {
    var el = $('v-' + name);
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return;
  }
  document.querySelectorAll('.view').forEach(function (v) { v.classList.toggle('active', v.id === 'v-' + name); });
  document.querySelectorAll('.pillnav button').forEach(function (b) {
    if (b.getAttribute('data-view') === name) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
  });
  window.scrollTo({ top: 0 });
}

function openMenu(on) {
  show($('sheet-back'), on);
  if (on) $('sheet-close').focus(); else $('menu-btn').focus();
}

/* ---------- wallet ---------- */
function weekData(history) {
  var days = [];
  var now = Date.now();
  for (var i = 6; i >= 0; i--) {
    var iso = new Date(now - i * 86400000).toISOString();
    days.push({ key: dayKey(iso), label: dayShort(iso), spent: 0, added: 0 });
  }
  var idx = {};
  days.forEach(function (d, i) { idx[d.key] = i; });
  history.forEach(function (h) {
    var k = dayKey(h.at);
    if (!(k in idx)) return;
    var d = days[idx[k]];
    if (h.kind === 'refund') d.spent -= h.amount;   // a fare refund reduces what you spent
    else if (h.amount < 0) d.spent += -h.amount;
    else d.added += h.amount;
  });
  return days;
}

function txnItem(h) {
  var inn = h.amount > 0;
  var li = document.createElement('li');
  li.className = 'txn';
  var amt = document.createElement('div');
  amt.className = 'amt';
  amt.innerHTML = '<small>KES</small>' + kes(Math.abs(h.amount));
  var what = document.createElement('div');
  what.className = 'what';
  var dot = document.createElement('i');
  dot.className = 'dot' + (inn ? ' in' : '');
  var text = document.createElement('span');
  text.textContent = h.label;
  var sr = document.createElement('span');
  sr.className = 'sr-only';
  sr.textContent = inn ? ' (added)' : ' (spent)';
  what.append(dot, text, sr);
  var side = document.createElement('div');
  side.className = 'side';
  var b = document.createElement('span');
  b.className = 'icon-btn dark sm';
  b.innerHTML = icon(inn ? 'plus' : 'up', 18);
  var when = document.createElement('div');
  when.className = 'when';
  when.textContent = whenShort(h.at);
  side.append(b, when);
  li.append(amt, what, side);
  return li;
}

function fillList(ul, emptyEl, items) {
  ul.innerHTML = '';
  items.forEach(function (h) { ul.appendChild(txnItem(h)); });
  show(emptyEl, items.length === 0);
}

function renderChart() {
  var days = weekData(wallet.history);
  var values = days.map(function (d) { return d[tab]; });
  var total = values.reduce(function (a, b) { return a + b; }, 0);
  if (selDay === null) selDay = values.lastIndexOf(Math.max.apply(null, values));
  $('chart-total').innerHTML = '<small>KES</small>' + (tab === 'added' && total ? '+' : '') + kes(total);
  barChart($('chart'), {
    labels: days.map(function (d) { return d.label; }),
    values: values,
    selected: selDay,
    fmt: function (v) { return 'KES ' + kes(v); },
    onSelect: function (i) { selDay = i; renderChart(); },
  });
  var net = days.reduce(function (a, d) { return a + d.added - d.spent; }, 0);
  var any = days.some(function (d) { return d.added || d.spent; });
  $('delta').textContent = any ? (net > 0 ? '+' : (net < 0 ? '-' : '')) + 'KES ' + kes(Math.abs(net)) + ' this week' : 'No activity this week';
}

function render() {
  var w = wallet;
  $('balance').textContent = kes(w.balance);
  $('greeting').textContent = 'Hi, ' + w.name.split(' ')[0];
  $('pass-name').textContent = w.name;
  $('sheet-name').textContent = w.name;
  $('sheet-phone').textContent = '+' + w.phone.replace(/^(\d{3})(\d{3})(\d{3})(\d{3})$/, '$1 $2 $3 $4');
  if (w.balance < 0) say($('neg-note'), 'Your balance is KES ' + kes(Math.abs(w.balance)) + ' below zero. Top up to keep riding.', 'err');
  else say($('neg-note'), '');
  renderChart();
  fillList($('recent'), $('recent-empty'), w.history.slice(0, 3));
  fillList($('all'), $('all-empty'), w.history);
  $('count').textContent = w.history.length ? 'Latest ' + w.history.length : '';
}

async function loadWallet() {
  try {
    wallet = await api('/wallet', { token: token });
  } catch (err) {
    if (err.status === 401 || err.status === 403) return Session.signOut();
    say($('neg-note'), "Can't reach the server. Showing your last known balance.", 'err');
    return;
  }
  render();
}

/* ---------- QR pass: a signed code that is replaced every minute ---------- */
function paintTimer() {
  var m = Math.floor(passLeft / 60), s = passLeft % 60;
  $('pass-timer').textContent = m + ':' + String(s).padStart(2, '0');
  $('pass-meter').style.width = Math.max(0, Math.min(100, (passLeft / PASS_REFRESH) * 100)) + '%';
}

async function refreshPass() {
  try {
    var p = await api('/pass', { token: token });
    if (typeof QRCode === 'undefined') {
      $('pass-note').textContent = "The QR library didn't load. Check your connection and reload.";
      return;
    }
    if (!qr) qr = new QRCode($('qr'), { text: p.token, width: 210, height: 210, correctLevel: QRCode.CorrectLevel.M });
    else { qr.clear(); qr.makeCode(p.token); }
    passLeft = PASS_REFRESH;
    $('pass-note').textContent = 'Hold this code up to the scanner.';
  } catch (err) {
    if (err.status === 401 || err.status === 403) return Session.signOut();
    passLeft = 15;
    $('pass-note').textContent = "You're offline. Reconnect to get a fresh code.";
  }
  paintTimer();
}

setInterval(function () {
  if (!token || document.hidden) return;
  passLeft -= 1;
  if (passLeft <= 0) { passLeft = PASS_REFRESH; refreshPass(); }
  paintTimer();
}, 1000);

/* ---------- top-up ---------- */
function setAmount(v) {
  $('amount').value = v;
  document.querySelectorAll('[data-amt]').forEach(function (c) { c.setAttribute('aria-pressed', c.getAttribute('data-amt') === String(v) ? 'true' : 'false'); });
}

async function onTopup(e) {
  e.preventDefault();
  var btn = $('topup-btn');
  btn.disabled = true;
  show($('confirm-btn'), false);
  try {
    var body = { amount: parseInt($('amount').value.replace(/,/g, ''), 10) };
    if (isNaN(body.amount)) throw new Error('Enter an amount in shillings.');
    if ($('topup-phone').value.trim()) body.phone = $('topup-phone').value;
    currentTopup = await api('/topups', { method: 'POST', body: body, token: token });
    if (currentTopup.mode === 'mock') {
      say($('topup-msg'), 'Demo mode: no real M-Pesa prompt is sent. Tap "Approve on phone" to simulate entering your PIN.');
      show($('confirm-btn'), true);
    } else {
      say($('topup-msg'), 'Check your phone and enter your M-Pesa PIN.');
      pollTopup();
    }
  } catch (err) {
    say($('topup-msg'), err.message, 'err');
  } finally {
    btn.disabled = false;
  }
}

async function onConfirm() {
  try {
    finishTopup(await api('/dev/mpesa/confirm/' + currentTopup.checkout_request_id, { method: 'POST', token: token }));
  } catch (err) { say($('topup-msg'), err.message, 'err'); }
}

function pollTopup() {
  clearInterval(pollTimer);
  var tries = 0;
  pollTimer = setInterval(async function () {
    tries += 1;
    try {
      var res = await api('/topups/' + currentTopup.id, { token: token });
      if (res.status !== 'pending') finishTopup(res);
    } catch (_) { /* keep trying */ }
    if (tries > 30) { clearInterval(pollTimer); say($('topup-msg'), 'Still waiting. If you paid, your balance will update shortly.'); }
  }, 2000);
}

async function finishTopup(res) {
  clearInterval(pollTimer);
  show($('confirm-btn'), false);
  if (res.status === 'success') {
    say($('topup-msg'), 'Added KES ' + kes(res.amount) + '. M-Pesa receipt ' + res.receipt + '.', 'ok');
    await loadWallet();
  } else {
    say($('topup-msg'), 'The top-up did not go through' + (res.message ? ': ' + res.message : '.') + ' You were not charged.', 'err');
  }
}

/* ---------- start ---------- */
function start() {
  mountIcons();
  document.querySelectorAll('[data-view]').forEach(function (b) { b.onclick = function () { setView(b.getAttribute('data-view')); }; });
  document.querySelectorAll('[data-go]').forEach(function (b) { b.onclick = function () { setView(b.getAttribute('data-go')); }; });
  document.querySelectorAll('[data-tab]').forEach(function (c) {
    c.onclick = function () {
      tab = c.getAttribute('data-tab');
      selDay = null;
      document.querySelectorAll('[data-tab]').forEach(function (x) { x.setAttribute('aria-pressed', x === c ? 'true' : 'false'); });
      if (wallet) renderChart();
    };
  });
  document.querySelectorAll('[data-amt]').forEach(function (c) { c.onclick = function () { setAmount(c.getAttribute('data-amt')); }; });
  $('amount').oninput = function () { setAmount($('amount').value); };
  $('topup-form').onsubmit = onTopup;
  $('confirm-btn').onclick = onConfirm;
  $('pass-shortcut').onclick = function () { setView('pass'); };
  $('refresh').onclick = function () { loadWallet(); refreshPass(); };
  $('menu-btn').onclick = function () { openMenu(true); };
  $('sheet-close').onclick = function () { openMenu(false); };
  $('sheet-back').onclick = function (e) { if (e.target === $('sheet-back')) openMenu(false); };
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') openMenu(false); });
  $('signout').onclick = Session.signOut;
  loadWallet();
  refreshPass();
}

if (session) start();
'@
$script:count++

# ---------------------------------------------------------------------------
# web/validator/app.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/validator/app.js' @'
/* Validator (gate scanner). Scans rider QR passes, queues every tap on the device (IndexedDB)
   and syncs the queue to POST /taps/sync whenever a connection exists.
   The gate decision never waits for the network: a readable, unexpired pass is accepted and
   queued. The SERVER decides charge / decline / reject when the batch arrives.
   The device key comes from the sign-in session, so there is no setup screen. */
var session = Session.require('validator');
var STORE = 'taps';
var simulateOffline = false;
var syncing = false;
var stream = null;
var lastText = '';
var lastAt = 0;
var recent = []; // latest sync results, newest first
var mode = (session && session.cfg && session.cfg.mode) || 'flat'; // 'distance' or 'flat'
var direction = localStorage.getItem('tl_dir') === 'out' ? 'out' : 'in';

/* ---------- IndexedDB queue ---------- */
var dbp = new Promise(function (resolve, reject) {
  var req = indexedDB.open('tl-validator', 1);
  req.onupgradeneeded = function () { req.result.createObjectStore(STORE, { keyPath: 'tap_id' }); };
  req.onsuccess = function () { resolve(req.result); };
  req.onerror = function () { reject(req.error); };
});
function putTap(tap) {
  return dbp.then(function (db) {
    return new Promise(function (res, rej) {
      var tx = db.transaction(STORE, 'readwrite');
      tx.objectStore(STORE).put(tap);
      tx.oncomplete = function () { res(); };
      tx.onerror = function () { rej(tx.error); };
    });
  });
}
function allTaps() {
  return dbp.then(function (db) {
    return new Promise(function (res, rej) {
      var req = db.transaction(STORE, 'readonly').objectStore(STORE).getAll();
      req.onsuccess = function () { res(req.result); };
      req.onerror = function () { rej(req.error); };
    });
  });
}
function deleteTaps(ids) {
  return dbp.then(function (db) {
    return new Promise(function (res, rej) {
      var tx = db.transaction(STORE, 'readwrite');
      ids.forEach(function (id) { tx.objectStore(STORE).delete(id); });
      tx.oncomplete = function () { res(); };
      tx.onerror = function () { rej(tx.error); };
    });
  });
}

/* ---------- helpers ---------- */
function newId() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  return 'tap-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
}

/* Read the pass payload WITHOUT verifying the signature (the server verifies it). */
function readPass(text) {
  var parts = text.trim().split('.');
  if (parts.length !== 3) return null;
  try {
    var b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    var p = JSON.parse(atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4)));
    return p && p.typ === 'pass' && p.exp ? p : null;
  } catch (_) { return null; }
}

function lamp(kind, title, sub) {
  $('lamp').className = 'lamp' + (kind ? ' ' + kind : '');
  $('lamp-title').textContent = title;
  $('lamp-sub').textContent = sub || '';
}

function beep(ok) {
  try {
    var ctx = new (window.AudioContext || window.webkitAudioContext)();
    var o = ctx.createOscillator();
    o.frequency.value = ok ? 880 : 220;
    o.connect(ctx.destination);
    o.start();
    o.stop(ctx.currentTime + (ok ? 0.12 : 0.3));
  } catch (_) { /* sound is optional */ }
  if (navigator.vibrate) navigator.vibrate(ok ? 60 : [80, 60, 80]);
}

function isOnline() { return navigator.onLine && !simulateOffline; }

/* Flat-fare stops only ever board, whatever the switch says. */
function scanDirection() { return mode === 'distance' ? direction : 'in'; }

function paintDirection() {
  document.querySelectorAll('[data-dir]').forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-dir') === direction ? 'true' : 'false'); });
  lamp('', direction === 'out' ? 'Ready for exits' : 'Ready', direction === 'out' ? "Scanning riders who are getting off. Point the camera at their QR code." : "Start the camera and point it at a rider's QR code.");
}

async function refreshStatus() {
  var pill = $('net-pill');
  pill.textContent = isOnline() ? 'Online' : 'Offline';
  pill.className = 'pill' + (isOnline() ? '' : ' off');
  var n = (await allTaps()).length;
  $('queue-pill').textContent = n + ' waiting';
}

/* ---------- accepting a scan ---------- */
async function onScan(text) {
  var now = Date.now();
  if (text === lastText && now - lastAt < 4000) return; // same code still in view
  lastText = text;
  lastAt = now;

  var pass = readPass(text);
  if (!pass) {
    lamp('stop', 'Not a Transit Link pass', 'Ask the rider to open their app.');
    return beep(false);
  }
  if (now / 1000 > pass.exp + 30) {
    lamp('warn', 'Pass expired', 'Ask the rider to wait for the code to refresh.');
    return beep(false);
  }
  var dir = scanDirection();
  await putTap({ tap_id: newId(), pass_token: text.trim(), tapped_at: new Date().toISOString(), direction: dir });
  var where = isOnline() ? 'Sending to the server.' : 'Saved on this device, will sync when online.';
  if (dir === 'out') lamp('go', 'Thank you', 'Exit scan read. ' + where);
  else lamp('go', 'Go ahead', 'Pass read. ' + where);
  beep(true);
  await refreshStatus();
  syncNow();
}

async function onManual() {
  var text = $('manual').value.trim();
  if (text) { await onScan(text); $('manual').value = ''; }
}

/* ---------- camera ---------- */
async function startCamera() {
  if (typeof jsQR === 'undefined') {
    return say($('cam-msg'), 'The scanner library did not load. Connect once to download it, or paste a pass below.', 'err');
  }
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
  } catch (err) {
    return say($('cam-msg'), 'Camera blocked or unavailable. Allow camera access (the page must be on HTTPS or localhost), or paste a pass below.', 'err');
  }
  say($('cam-msg'), '');
  var video = $('video');
  video.srcObject = stream;
  await video.play();
  $('cam-btn').lastChild.textContent = ' Stop camera';
  tick();
}

function stopCamera() {
  if (stream) stream.getTracks().forEach(function (t) { t.stop(); });
  stream = null;
  $('cam-btn').lastChild.textContent = ' Start camera';
}

function tick() {
  if (!stream) return;
  var video = $('video');
  if (video.readyState === video.HAVE_ENOUGH_DATA && video.videoWidth) {
    var scale = Math.min(1, 640 / video.videoWidth);
    var canvas = $('canvas');
    canvas.width = Math.round(video.videoWidth * scale);
    canvas.height = Math.round(video.videoHeight * scale);
    var ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    var img = ctx.getImageData(0, 0, canvas.width, canvas.height);
    var code = jsQR(img.data, img.width, img.height, { inversionAttempts: 'dontInvert' });
    if (code && code.data) onScan(code.data);
  }
  setTimeout(function () { requestAnimationFrame(tick); }, 120);
}

/* ---------- sync ---------- */
var REASONS = {
  no_tap_in: 'No boarding scan found yet',
  flat_fare: 'This stop has a flat fare',
  same_station: 'Same station: fare refunded',
  no_fare_for_pair: 'No fare for this trip: maximum kept',
  insufficient_funds: 'Balance too low',
  replayed_pass: 'Pass already used',
  stale_pass: 'Pass was not valid at that time',
  invalid_pass: 'Not a valid pass',
  unknown_rider: 'Unknown rider',
};

var SMALL = function (t) { return '<span style="font-size:.55em">' + t + '</span>'; };

/* Turn one server result into what the gate screen shows. */
function describe(r) {
  var id8 = r.tap_id.slice(0, 8);
  if (r.direction === 'out') {
    if (r.status === 'settled') return { ok: true, icon: 'check', amt: '<small>KES</small>' + kes(r.fare), text: 'Exit · ' + (r.from_station || '?') + ' to ' + r.to_station + (r.refund ? ' · KES ' + kes(r.refund) + ' refunded' : '') };
    if (r.status === 'cancelled') return { ok: true, icon: 'check', amt: SMALL('Cancelled'), text: 'Same station · KES ' + kes(r.refund) + ' refunded' };
    if (r.status === 'orphan') return { ok: true, wait: true, icon: 'clock', amt: SMALL('Waiting'), text: 'Exit saved, waiting for the boarding scan' };
    if (r.status === 'ignored') return { ok: true, icon: 'check', amt: SMALL('No exit needed'), text: REASONS[r.reason] || 'Flat fare' };
    return { ok: false, icon: 'alert', amt: SMALL('Rejected'), text: REASONS[r.reason] || r.reason };
  }
  if (r.status === 'open') return { ok: true, icon: 'check', amt: '<small>KES</small>' + kes(r.fare), text: 'Boarded · up to KES ' + kes(r.fare) + ' held' };
  if (r.status === 'charged') return { ok: true, icon: 'check', amt: '<small>KES</small>' + kes(r.fare), text: 'Charged · tap ' + id8 };
  if (r.status === 'declined') return { ok: false, warn: true, icon: 'alert', amt: SMALL('Declined'), text: REASONS[r.reason] || r.reason };
  return { ok: false, icon: 'alert', amt: SMALL('Rejected'), text: REASONS[r.reason] || r.reason };
}

function renderLog() {
  var ul = $('log');
  ul.innerHTML = '';
  recent.slice(0, 6).forEach(function (r) {
    var d = describe(r);
    var li = document.createElement('li');
    li.className = 'txn';
    var amt = document.createElement('div');
    amt.className = 'amt';
    amt.innerHTML = d.amt;
    var what = document.createElement('div');
    what.className = 'what';
    var dot = document.createElement('i');
    dot.className = 'dot' + (d.ok ? ' in' : '');
    var text = document.createElement('span');
    text.textContent = d.text;
    what.append(dot, text);
    var side = document.createElement('div');
    side.className = 'side';
    var b = document.createElement('span');
    b.className = 'icon-btn dark sm';
    b.innerHTML = icon(d.icon, 18);
    side.appendChild(b);
    li.append(amt, what, side);
    ul.appendChild(li);
  });
  show($('log-empty'), recent.length === 0);
}

async function syncNow() {
  if (syncing || !isOnline()) return;
  var queued = (await allTaps()).sort(function (a, b) { return a.tapped_at.localeCompare(b.tapped_at); }).slice(0, 200);
  if (!queued.length) return;
  syncing = true;
  try {
    var res = await api('/taps/sync', { method: 'POST', body: { taps: queued }, headers: { 'X-Validator-Key': session.key } });
    await deleteTaps(res.results.map(function (r) { return r.tap_id; }));
    res.results.forEach(function (r) { recent.unshift(r); });
    renderLog();
    var bad = res.results.find(function (r) { return !describe(r).ok && !r.duplicate; });
    if (bad) lamp(bad.status === 'declined' ? 'warn' : 'stop', bad.status === 'declined' ? 'Declined after sync' : 'Rejected after sync', describe(bad).text);
    else if (res.results.some(function (r) { return describe(r).wait; })) lamp('warn', 'Exit saved', 'Waiting for the matching boarding scan to sync from another gate.');
    else lamp('go', 'Synced', res.results.length + ' tap(s) processed.');
  } catch (err) {
    if (err.status === 401) { lamp('stop', 'Device not recognised', 'Sign out and sign in again.'); }
    /* network errors: keep the queue and retry later */
  } finally {
    syncing = false;
    refreshStatus();
  }
}

/* ---------- start ---------- */
function showConfig(cfg) {
  mode = cfg.mode || 'flat';
  $('station').textContent = cfg.station;
  $('operator').textContent = cfg.operator + ' · ' + cfg.validator;
  var distance = mode === 'distance';
  $('fare').innerHTML = '<small>' + (distance ? 'up to KES' : 'KES') + '</small>' + kes(cfg.fare);
  $('fare-label').textContent = distance ? 'Maximum fare from this point' : 'Fare per ride';
  show($('fare-note'), distance);
  show($('dir-wrap'), distance);
  paintDirection();
}

function start() {
  mountIcons();
  showConfig(session.cfg); // cached at sign-in, so the screen works with no connection
  $('cam-btn').onclick = function () { return stream ? stopCamera() : startCamera(); };
  $('sync-btn').onclick = syncNow;
  document.querySelectorAll('[data-dir]').forEach(function (b) {
    b.onclick = function () { direction = b.getAttribute('data-dir'); localStorage.setItem('tl_dir', direction); paintDirection(); };
  });
  $('manual-btn').onclick = onManual;
  $('offline-sw').onchange = function (e) { simulateOffline = e.target.checked; refreshStatus(); if (isOnline()) syncNow(); };
  $('signout').onclick = async function () {
    var waiting = (await allTaps()).length;
    if (waiting && !confirm(waiting + ' taps have not synced yet. They stay on this device but cannot sync until you sign in again. Sign out anyway?')) return;
    stopCamera();
    Session.signOut();
  };
  window.addEventListener('online', function () { refreshStatus(); syncNow(); });
  window.addEventListener('offline', refreshStatus);
  setInterval(function () { refreshStatus(); syncNow(); }, 10000);
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(function () {});
  refreshStatus();
  syncNow();
  // refresh the cached station and fare whenever we are online
  api('/validator/config', { headers: { 'X-Validator-Key': session.key } }).then(function (cfg) {
    session.cfg = cfg;
    Session.set(session);
    showConfig(cfg);
  }).catch(function (err) {
    if (err.status === 401) { Session.clear(); go('/login/'); }
  });
}

if (session) start();
'@
$script:count++

# ---------------------------------------------------------------------------
# web/validator/index.html
# ---------------------------------------------------------------------------
Write-BundleFile 'web/validator/index.html' @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Gate · Transit Link</title>
  <meta name="theme-color" content="#1c2120">
  <link rel="stylesheet" href="../shared/theme.css">
  <link rel="stylesheet" href="../shared/site.css">
  <style>
    .vgrid { display: block; }
    .vgrid .col > * + * { margin-top: 16px; }
    .vgrid .col + .col { margin-top: 16px; }
    .card h2 { font-size: 1.35rem; font-weight: 400; letter-spacing: -.02em; }
    details.card summary { cursor: pointer; font-size: 1.1rem; list-style: none; display: flex; justify-content: space-between; align-items: center; }
    details.card summary::-webkit-details-marker { display: none; }
    .toggle { display: flex; align-items: center; gap: 12px; cursor: pointer; }
    .toggle input { width: 22px; height: 22px; accent-color: var(--lime); }
    .dir { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
    .dir .chip { height: 58px; font-size: 1.1rem; }
    @media (min-width: 1000px) {
      .vgrid { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(0, 1fr); gap: 28px; align-items: start; }
      .vgrid .col + .col { margin-top: 0; }
    }
  </style>
</head>
<body>
  <div class="page wide" style="padding-bottom:48px">
    <header class="appbar">
      <a class="brand" href="/" style="font-size:1.05rem"><span class="mark" data-star="26" style="color:var(--lime);display:grid"></span>Gate</a>
      <div class="row">
        <span id="net-pill" class="pill">Online</span>
        <span id="queue-pill" class="pill">0 waiting</span>
        <button class="icon-btn sm" id="signout" type="button" aria-label="Sign out"><span data-icon="logout" data-size="20"></span></button>
      </div>
    </header>

    <div class="vgrid">
      <div class="col">
        <div id="lamp" class="lamp" role="status" aria-live="polite">
          <h1 id="lamp-title">Ready</h1>
          <div id="lamp-sub" class="muted">Start the camera and point it at a rider's QR code.</div>
        </div>

        <div id="dir-wrap" class="card card-glass hidden">
          <div class="muted small" style="margin-bottom:10px">This device is scanning for</div>
          <div class="dir" role="group" aria-label="Scan type">
            <button class="chip" type="button" data-dir="in" aria-pressed="true">Boarding</button>
            <button class="chip" type="button" data-dir="out" aria-pressed="false">Alighting</button>
          </div>
        </div>

        <div class="viewfinder"><video id="video" playsinline muted></video></div>
        <canvas id="canvas" class="hidden"></canvas>
        <div class="row">
          <button class="btn btn-white grow" id="cam-btn" type="button"><span data-icon="scan" data-size="22"></span> Start camera</button>
          <button class="btn btn-ghost grow" id="sync-btn" type="button"><span data-icon="refresh" data-size="20"></span> Sync now</button>
        </div>
        <div id="cam-msg" class="note hidden"></div>
      </div>

      <div class="col">
        <div class="card card-white">
          <div class="row spread" style="align-items:flex-start">
            <div><div class="muted small">Boarding point</div><h2 id="station" style="font-size:1.7rem;font-weight:500;letter-spacing:-.03em"></h2><div class="muted small" id="operator"></div></div>
            <span class="icon-btn dark sm" data-icon="train" data-size="20"></span>
          </div>
          <div class="display lg" id="fare" style="margin-top:14px"></div>
          <div class="muted small" style="margin-top:4px" id="fare-label">Fare per ride</div>
          <div class="muted small hidden" style="margin-top:8px" id="fare-note">The maximum is held when a rider boards. The exact fare is set when they tap out, and any difference is refunded.</div>
        </div>

        <div class="card card-glass">
          <h2>Latest results</h2>
          <ul class="txns" id="log" style="margin-top:6px"></ul>
          <div class="empty" id="log-empty">Nothing synced yet.</div>
        </div>

        <details class="card card-glass">
          <summary>No camera? Paste a pass <span data-icon="plus" data-size="20"></span></summary>
          <div class="stack" style="margin-top:14px">
            <textarea class="input" id="manual" placeholder="Paste the pass token from the rider app"></textarea>
            <button class="btn btn-lime btn-block" id="manual-btn" type="button">Add pass</button>
          </div>
        </details>

        <label class="card card-glass toggle"><input id="offline-sw" type="checkbox"><span><strong>Simulate offline</strong><span class="muted small" style="display:block">For demos: queue taps on this device without a connection.</span></span></label>
      </div>
    </div>
  </div>

  <script src="https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js" crossorigin="anonymous"></script>
  <script src="../shared/api.js"></script>
  <script src="../shared/ui.js"></script>
  <script src="app.js"></script>
</body>
</html>
'@
$script:count++

# ---------------------------------------------------------------------------
# web/validator/sw.js
# ---------------------------------------------------------------------------
Write-BundleFile 'web/validator/sw.js' @'
/* Service worker: lets the gate screen open with no connection after the first visit.
   Strategy: network first, fall back to the cache. API calls are never intercepted. */
const CACHE = 'tl-validator-v3';
const ASSETS = [
  './',
  './app.js',
  '../shared/theme.css',
  '../shared/site.css',
  '../shared/api.js',
  '../shared/ui.js',
  'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => Promise.all(ASSETS.map(url => {
        const cross = url.startsWith('http');
        return cache.add(new Request(url, cross ? { mode: 'cors' } : {})).catch(() => {});
      })))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.pathname.startsWith('/api/')) return;
  event.respondWith(
    fetch(event.request)
      .then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(event.request, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(event.request, { ignoreSearch: true }))
  );
});
'@
$script:count++

# ---------------------------------------------------------------------------
# tests/test_flow.py
# ---------------------------------------------------------------------------
Write-BundleFile 'tests/test_flow.py' @'
"""End-to-end tests of the MVP showcase flow, including distance fares. Run:  pytest -q

Demo fare table (KES): stops apart -> 1: 30, 2: 45, 3: 60, 4: 80.
Stations: 1 Nairobi Central, 2 Makadara, 3 Githurai, 4 Ruiru, 5 Thika (rail); 6 feeder stop (flat 30).
Gate devices: key-1 Central, key-2 feeder, key-3 Makadara, key-4 Githurai, key-5 Ruiru, key-6 Thika.
"""
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import app

K = {i: {"X-Validator-Key": f"demo-validator-key-{i}"} for i in range(1, 7)}
CENTRAL, FEEDER, MAKADARA, GITHURAI, RUIRU, THIKA = 1, 2, 3, 4, 5, 6  # gate device numbers


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


_phone = iter(range(711100100, 711199999))


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _iso(dt=None):
    return (dt or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z")


def _rider(client, topup=0):
    r = client.post("/api/auth/register", json={"phone": "0" + str(next(_phone)), "name": "Test Rider", "pin": "4321"})
    assert r.status_code == 201, r.text
    token = r.json()["token"]
    if topup:
        t = client.post("/api/topups", json={"amount": topup}, headers=_auth(token)).json()
        done = client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token)).json()
        assert done["status"] == "success"
    return token


def _pass(client, token):
    return client.get("/api/pass", headers=_auth(token)).json()["token"]


def _balance(client, token):
    return client.get("/api/wallet", headers=_auth(token)).json()["balance"]


def _tap(client, gate, qr, direction="in", when=None, tap_id=None):
    body = {"taps": [{"tap_id": tap_id or uuid.uuid4().hex, "pass_token": qr, "tapped_at": _iso(when), "direction": direction}]}
    return client.post("/api/taps/sync", json=body, headers=K[gate]).json()["results"][0]


def _journey(client, token, start, end):
    """Tap in at one gate and out at another with the same pass. Returns (entry, exit)."""
    qr = _pass(client, token)
    return _tap(client, start, qr, "in"), _tap(client, end, qr, "out")


def _operator(client, username="rail"):
    r = client.post("/api/auth/operator/login", json={"username": username, "password": "demo1234"})
    assert r.status_code == 200
    return _auth(r.json()["token"])


# ------------------------------------------------------------------ basics
def test_health_and_static(client):
    assert client.get("/api/health").json()["status"] == "ok"
    for path in ("/", "/login/", "/rider/", "/validator/", "/operator/"):
        assert client.get(path).status_code == 200, path


def test_register_login_validation(client):
    token = _rider(client)
    me = client.get("/api/wallet", headers=_auth(token)).json()
    phone = "0" + str(int(me["phone"][3:]))
    assert client.post("/api/auth/login", json={"phone": phone, "pin": "4321"}).status_code == 200
    assert client.post("/api/auth/login", json={"phone": phone, "pin": "0000"}).status_code == 401
    assert client.post("/api/auth/register", json={"phone": phone, "name": "X Y", "pin": "4321"}).status_code == 409
    assert client.post("/api/auth/register", json={"phone": "12345", "name": "X Y", "pin": "4321"}).status_code == 422
    assert me["balance"] == 0


def test_topup_mock_flow_and_idempotency(client):
    token = _rider(client)
    t = client.post("/api/topups", json={"amount": 300}, headers=_auth(token)).json()
    assert t["status"] == "pending" and t["mode"] == "mock"
    client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token))
    client.post(f"/api/dev/mpesa/confirm/{t['checkout_request_id']}", headers=_auth(token))  # twice
    assert _balance(client, token) == 300
    assert client.post("/api/topups", json={"amount": 5}, headers=_auth(token)).status_code == 422


def test_daraja_callback(client):
    token = _rider(client)
    t = client.post("/api/topups", json={"amount": 200}, headers=_auth(token)).json()
    payload = {"Body": {"stkCallback": {
        "MerchantRequestID": "x", "CheckoutRequestID": t["checkout_request_id"], "ResultCode": 0,
        "ResultDesc": "The service request is processed successfully.",
        "CallbackMetadata": {"Item": [
            {"Name": "Amount", "Value": 200}, {"Name": "MpesaReceiptNumber", "Value": "TESTRCPT01"},
            {"Name": "PhoneNumber", "Value": 254711000003}]},
    }}}
    assert client.post("/api/mpesa/callback/wrong", json=payload).status_code == 404
    assert client.post("/api/mpesa/callback/cb-secret", json=payload).json()["ResultCode"] == 0
    client.post("/api/mpesa/callback/cb-secret", json=payload)  # Daraja may retry
    wallet = client.get("/api/wallet", headers=_auth(token)).json()
    assert wallet["balance"] == 200 and wallet["history"][0]["ref"] == "TESTRCPT01"


# ------------------------------------------------------------------ gate config
def test_gate_config_reports_fare_mode(client):
    rail = client.get("/api/validator/config", headers=K[CENTRAL]).json()
    assert (rail["mode"], rail["fare"], rail["station"]) == ("distance", 80, "Nairobi Central")
    assert client.get("/api/validator/config", headers=K[MAKADARA]).json()["fare"] == 60  # shorter maximum
    feeder = client.get("/api/validator/config", headers=K[FEEDER]).json()
    assert (feeder["mode"], feeder["fare"]) == ("flat", 30)


# ------------------------------------------------------------------ flat-fare stop (feeder)
def test_flat_fare_charges_once_and_exit_scan_is_ignored(client):
    token = _rider(client, topup=100)
    qr = _pass(client, token)
    tap_id = uuid.uuid4().hex
    first = _tap(client, FEEDER, qr, "in", tap_id=tap_id)
    assert (first["status"], first["fare"], first["balance"]) == ("charged", 30, 70)
    again = _tap(client, FEEDER, qr, "in", tap_id=tap_id)
    assert again["duplicate"] is True and again["balance"] == 70
    out = _tap(client, FEEDER, qr, "out")
    assert (out["status"], out["reason"]) == ("ignored", "flat_fare")
    assert _balance(client, token) == 70


# ------------------------------------------------------------------ distance fares
def test_distance_journey_holds_maximum_then_settles_exact_fare(client):
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    entry = _tap(client, CENTRAL, qr, "in")
    assert (entry["status"], entry["fare"], entry["balance"]) == ("open", 80, 420)
    exit_ = _tap(client, GITHURAI, qr, "out")  # same pass may leave as well as enter
    assert (exit_["status"], exit_["fare"], exit_["refund"], exit_["balance"]) == ("settled", 45, 35, 455)
    assert (exit_["from_station"], exit_["to_station"]) == ("Nairobi Central", "Githurai")
    labels = [h["label"] for h in client.get("/api/wallet", headers=_auth(token)).json()["history"]]
    assert "Fare held from Nairobi Central" in labels and "Refund: Nairobi Central to Githurai" in labels


def test_different_boarding_and_exit_points_pay_different_fares(client):
    cases = [  # (board gate, exit gate, held maximum, exact fare)
        (CENTRAL, THIKA, 80, 80),    # whole line: no refund
        (MAKADARA, RUIRU, 60, 45),   # two stops
        (THIKA, MAKADARA, 80, 60),   # reverse direction, three stops
        (GITHURAI, RUIRU, 45, 30),   # one stop
    ]
    for board, leave, held, exact in cases:
        token = _rider(client, topup=500)
        entry, exit_ = _journey(client, token, board, leave)
        assert entry["fare"] == held and exit_["fare"] == exact and exit_["refund"] == held - exact
        assert _balance(client, token) == 500 - exact


def test_exit_at_the_entry_station_cancels_with_full_refund(client):
    token = _rider(client, topup=300)
    entry, exit_ = _journey(client, token, CENTRAL, CENTRAL)
    assert entry["status"] == "open"
    assert (exit_["status"], exit_["reason"], exit_["fare"], exit_["refund"]) == ("cancelled", "same_station", 0, 80)
    assert _balance(client, token) == 300


def test_entry_and_exit_synced_by_two_different_devices(client):
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    now = datetime.now(timezone.utc)
    taps = [  # sent out of order on purpose: the server sorts by tap time
        {"tap_id": uuid.uuid4().hex, "pass_token": qr, "tapped_at": _iso(now), "direction": "out"},
        {"tap_id": uuid.uuid4().hex, "pass_token": qr, "tapped_at": _iso(now - timedelta(minutes=2)), "direction": "in"},
    ]
    # the in-tap and out-tap come from different stations, so use two devices
    r1 = client.post("/api/taps/sync", json={"taps": [taps[1]]}, headers=K[CENTRAL]).json()["results"][0]
    r2 = client.post("/api/taps/sync", json={"taps": [taps[0]]}, headers=K[RUIRU]).json()["results"][0]
    assert r1["status"] == "open" and (r2["status"], r2["fare"]) == ("settled", 60)
    assert _balance(client, token) == 440


def test_exit_that_syncs_before_its_entry_is_matched_later(client):
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    now = datetime.now(timezone.utc)
    early = _tap(client, GITHURAI, qr, "out", when=now)  # exit device synced first
    assert (early["status"], early["reason"]) == ("orphan", "no_tap_in")
    assert _balance(client, token) == 500  # nothing charged yet
    entry = _tap(client, CENTRAL, qr, "in", when=now - timedelta(minutes=3))
    assert entry["status"] == "charged" and entry["fare"] == 45  # settled the moment the entry arrived
    assert _balance(client, token) == 455


def test_missed_tap_out_is_closed_at_the_maximum_fare(client):
    from app.db import SessionLocal
    from app.models import Trip

    token = _rider(client, topup=500)
    now = datetime.now(timezone.utc)
    qr1, qr2 = _pass(client, token), _pass(client, token)
    first = _tap(client, CENTRAL, qr1, "in", when=now - timedelta(minutes=4))
    second = _tap(client, MAKADARA, qr2, "in", when=now)  # boards again without ever tapping out
    assert first["status"] == "open" and second["status"] == "open"
    with SessionLocal() as db:
        trip = db.get(Trip, first["tap_id"])
        assert (trip.status, trip.reason, trip.fare) == ("charged", "no_tap_out", 80)
    assert _balance(client, token) == 500 - 80 - 60


def test_stale_open_journeys_are_closed_and_flagged(client):
    from app.db import SessionLocal
    from app.models import Rider, Trip
    from app.timeutil import utcnow
    from app import ledger

    token = _rider(client, topup=500)
    phone = client.get("/api/wallet", headers=_auth(token)).json()["phone"]
    trip_id = uuid.uuid4().hex
    with SessionLocal() as db:
        rider = db.query(Rider).filter(Rider.phone == phone).one()
        old = utcnow() - timedelta(hours=7)
        db.add(Trip(id=trip_id, rider_id=rider.id, station_id=1, operator_id=1, pass_jti="x" + trip_id[:10], tapped_at=old,
                    received_at=old, fare=80, hold=80, status="open"))
        db.flush()
        ledger.post(db, rider.id, -80, "fare", trip_id)
        db.commit()
    h = _operator(client)
    flags = client.get("/api/operator/flags", headers=h).json()["flags"]  # also closes stale journeys
    assert any(f["trip_id"] == trip_id and "missed_tap_out" in f["reasons"] for f in flags)
    with SessionLocal() as db:
        assert db.get(Trip, trip_id).status == "charged"


def test_exit_without_any_entry_is_flagged_after_an_hour(client):
    from app.db import SessionLocal
    from app.models import Rider, TapOut
    from app.timeutil import utcnow

    token = _rider(client)
    phone = client.get("/api/wallet", headers=_auth(token)).json()["phone"]
    out_id = uuid.uuid4().hex
    with SessionLocal() as db:
        rider = db.query(Rider).filter(Rider.phone == phone).one()
        t = utcnow() - timedelta(hours=2)
        db.add(TapOut(id=out_id, rider_id=rider.id, station_id=4, operator_id=1, pass_jti="y" + out_id[:10], tapped_at=t,
                      received_at=t, status="orphan", reason="no_tap_in"))
        db.commit()
    flags = client.get("/api/operator/flags", headers=_operator(client)).json()["flags"]
    assert any(f["trip_id"] == out_id and f["reasons"] == ["exit_without_entry"] for f in flags)


def test_the_held_maximum_must_fit_inside_the_overdraft(client):
    poor = _rider(client, topup=20)   # 20 - 80 = -60, beyond the KES 50 overdraft
    ok = _rider(client, topup=40)     # 40 - 80 = -40, allowed
    d = _tap(client, CENTRAL, _pass(client, poor))
    a = _tap(client, CENTRAL, _pass(client, ok))
    assert (d["status"], d["reason"]) == ("declined", "insufficient_funds")
    assert (a["status"], a["balance"]) == ("open", -40)
    assert _balance(client, poor) == 20


# ------------------------------------------------------------------ pass checks
def test_replayed_pass_is_rejected_for_entry_and_for_exit(client):
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    assert _tap(client, CENTRAL, qr, "in")["status"] == "open"
    again = _tap(client, MAKADARA, qr, "in")
    assert (again["status"], again["reason"]) == ("rejected", "replayed_pass")
    assert _tap(client, GITHURAI, qr, "out")["status"] == "settled"
    second_exit = _tap(client, RUIRU, qr, "out")
    assert (second_exit["status"], second_exit["reason"]) == ("rejected", "replayed_pass")
    assert _balance(client, token) == 500 - 45


def test_stale_and_forged_passes(client):
    token = _rider(client, topup=500)
    old = _tap(client, CENTRAL, _pass(client, token), when=datetime.now(timezone.utc) - timedelta(hours=3))
    assert (old["status"], old["reason"]) == ("rejected", "stale_pass")
    assert _tap(client, CENTRAL, "x" * 40)["reason"] == "invalid_pass"
    assert _tap(client, CENTRAL, "x" * 40, "out")["reason"] == "invalid_pass"
    assert client.post("/api/taps/sync", json={"taps": []}).status_code == 401
    assert _balance(client, token) == 500


def test_direction_defaults_to_boarding_for_older_devices(client):
    token = _rider(client, topup=100)
    body = {"taps": [{"tap_id": uuid.uuid4().hex, "pass_token": _pass(client, token), "tapped_at": _iso()}]}
    assert client.post("/api/taps/sync", json=body, headers=K[FEEDER]).json()["results"][0]["direction"] == "in"


# ------------------------------------------------------------------ operator
def test_open_journeys_are_not_revenue_until_settled_then_pay_out(client):
    h = _operator(client)
    before = client.get("/api/operator/summary", headers=h).json()
    token = _rider(client, topup=500)
    qr = _pass(client, token)
    _tap(client, CENTRAL, qr, "in")
    mid = client.get("/api/operator/summary", headers=h).json()
    assert mid["open_journeys"] == before["open_journeys"] + 1
    assert mid["unpaid_revenue"] == before["unpaid_revenue"]  # still only a hold
    _tap(client, THIKA, qr, "out")
    after = client.get("/api/operator/summary", headers=h).json()
    assert after["unpaid_revenue"] == before["unpaid_revenue"] + 80
    assert after["open_journeys"] == before["open_journeys"]
    payout = client.post("/api/operator/payouts/run", headers=h).json()
    assert payout["gross"] == after["unpaid_revenue"] and payout["gross"] == payout["fee"] + payout["net"]
    assert client.post("/api/operator/payouts/run", headers=h).status_code == 409
    assert client.get("/api/operator/payouts", headers=h).json()["payouts"][0]["id"] == payout["id"]
    assert client.get("/api/operator/summary", headers=_auth(_rider(client))).status_code == 403


def test_fraud_flags_and_demand_on_seeded_history(client):
    from app.db import SessionLocal
    from app.seed import seed_history

    with SessionLocal() as db:
        info = seed_history(db, riders=30, days=10)
    assert info["journeys"] > 100 and info["in_progress"] == 2
    h = _operator(client)
    summary = client.get("/api/operator/summary", headers=h).json()
    flags = client.get("/api/operator/flags", headers=h).json()["flags"]
    reasons = {r for f in flags for r in f["reasons"]}
    assert {"double_tap", "impossible_travel", "rapid_burst", "missed_tap_out"} <= reasons
    assert len(summary["daily"]) == 7 and len(summary["hourly_profile"]) == 24 and summary["forecast_peak_hours"]
    assert summary["open_journeys"] >= 2


# ------------------------------------------------------------------ upgrading an older database
def test_old_database_is_upgraded_in_place(tmp_path):
    from sqlalchemy import create_engine, inspect, text

    from app.db import upgrade_schema

    engine = create_engine(f"sqlite:///{tmp_path}/old.db")
    with engine.begin() as conn:  # the trips table as it was before distance fares
        conn.execute(text("CREATE TABLE trips (id VARCHAR(64) PRIMARY KEY, station_id INTEGER, operator_id INTEGER, "
                          "tapped_at DATETIME, status VARCHAR(12), fare INTEGER)"))
        conn.execute(text("INSERT INTO trips VALUES ('t1', 1, 1, '2026-01-01 08:00:00', 'charged', 50)"))
    added = upgrade_schema(engine)
    assert sorted(added) == ["trips.exit_at", "trips.exit_station_id", "trips.exit_tap_id", "trips.hold"]
    assert upgrade_schema(engine) == []  # running it again changes nothing
    cols = {c["name"] for c in inspect(engine).get_columns("trips")}
    assert {"hold", "exit_station_id", "exit_at", "exit_tap_id"} <= cols
    with engine.begin() as conn:
        assert conn.execute(text("SELECT hold FROM trips WHERE id='t1'")).scalar() == 0  # old rows keep working
'@
$script:count++

# ---------------------------------------------------------------------------
# .env.example
# ---------------------------------------------------------------------------
Write-BundleFile '.env.example' @'
# Copy to .env and edit. Every value has a safe local default.

# SQLite for local work. For Supabase/Postgres use the psycopg driver prefix:
#   postgresql+psycopg://USER:PASSWORD@HOST:5432/postgres
DATABASE_URL=sqlite:///./transit_link.db

# Signs login tokens and QR passes. CHANGE THIS in any shared deployment.
JWT_SECRET=dev-secret-change-me

# Create demo operators, stations, validators and a demo rider on first start.
AUTO_SEED=1

# M-Pesa: "mock" needs no credentials. "live" talks to Daraja.
MPESA_MODE=mock
MPESA_ENV=sandbox
MPESA_CONSUMER_KEY=
MPESA_CONSUMER_SECRET=
MPESA_SHORTCODE=174379
MPESA_PASSKEY=
# Public HTTPS URL of this API (use ngrok locally). Daraja calls it back here.
CALLBACK_BASE_URL=https://your-public-url.example
# Random string that forms part of the callback URL (Daraja does not sign callbacks).
CALLBACK_SECRET=change-me-too

# Business rules (whole Kenya shillings)
OVERDRAFT_LIMIT=50
PLATFORM_FEE_PCT=2
PASS_TTL_SECONDS=120
TAP_TOLERANCE_SECONDS=300
# A journey with no tap-out is closed at the maximum fare after this many hours
OPEN_TRIP_HOURS=6
LOCAL_UTC_OFFSET_HOURS=3
'@
$script:count++

# ---------------------------------------------------------------------------
# README.md
# ---------------------------------------------------------------------------
Write-BundleFile 'README.md' @'
# Transit Link MVP

An account-based, M-Pesa-first fare system, demonstrated on commuter rail with a matatu feeder.
A rider tops up with M-Pesa, shows a QR pass, a validator scans it (even offline), the ledger
charges the fare once, and the operator sees revenue, demand, suspicious trips and a simulated payout.

> This is a showcase prototype. It holds no real money, uses demo stations and fares (not official
> Kenya Railways data), and ships with demo passwords that must be removed before any public use.

## What is inside

| Part | Where | Tech |
| --- | --- | --- |
| Backend API, ledger, fraud model | `app/` | Python, FastAPI, SQLAlchemy |
| Rider app (top-up, QR pass) | `web/rider/` | Plain HTML and JavaScript |
| Validator (offline scanner) | `web/validator/` | Plain JavaScript, IndexedDB, service worker |
| Operator dashboard | `web/operator/` | Plain JavaScript, inline SVG charts |
| Tests | `tests/` | pytest, 10 end-to-end tests |
| Documentation | `docs/` | Markdown with Mermaid diagrams |

One service serves both the API and the three web apps, so there is a single thing to run and deploy.

## Quick start

Requires Python 3.10 or newer.

```bash
python -m venv .venv
source .venv/bin/activate          # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -r requirements.txt
python -m app.seed --history        # demo data + 14 days of simulated trips
uvicorn app.main:app --reload
```

Open http://localhost:8000 and pick an app. API docs are at http://localhost:8000/docs.

Demo logins (also printed by the seed command):

| Who | Login |
| --- | --- |
| Rider | phone 0712 345 678, PIN 1234 |
| Operator | `rail` / `demo1234` (feeder sacco: `sacco` / `demo1234`) |
| Gate devices | `demo-validator-key-1` to `-6` (Nairobi Central, feeder stop, Makadara, Githurai, Ruiru, Thika); leave the passcode empty |

By default M-Pesa runs in `mock` mode: no credentials needed, and the rider app shows an
"Approve on phone (simulated)" button. See `docs/MPESA.md` to switch to the real Daraja sandbox.

## Run the tests

```bash
pip install pytest
pytest -q
```

## Reading order for the docs

1. `docs/ARCHITECTURE.md` - the big picture and how every module links to the others
2. `docs/DATA_MODEL.md` - tables and the ledger rule
3. `docs/API.md` - every endpoint, who may call it
4. `docs/OFFLINE_SYNC.md` - how the validator works with no connection
5. `docs/MPESA.md`, `docs/FRAUD_MODEL.md` - the two integrations
6. `docs/DEMO_SCRIPT.md` - a 4 minute showcase run
7. `docs/FARES.md` - distance fares: boarding, alighting and refunds
8. `docs/DEPLOY.md`, `docs/ROADMAP.md` - going online and what comes after the MVP
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/API.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/API.md' @'
# API reference

Base path `/api`. Interactive docs: `/docs`. Errors return `{"detail": "..."}` with a plain-language message.

Auth types:
- **Rider / Operator**: `Authorization: Bearer <token>` from the login endpoints (12 hour life).
- **Validator**: `X-Validator-Key: <device key>` header.
- **Callback**: the secret in the URL.

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `GET /health` | none | Status and M-Pesa mode |
| `POST /auth/register` | none | Create a rider `{phone, name, pin}` -> `{token, name}` |
| `POST /auth/login` | none | Rider sign-in `{phone, pin}` |
| `POST /auth/operator/login` | none | Operator sign-in `{username, password}` |
| `GET /wallet` | rider | Balance and last 30 ledger entries |
| `GET /pass` | rider | Signed QR token `{token, expires_in}` (2 minutes by default) |
| `POST /topups` | rider | Start an STK Push `{amount, phone?}` -> topup with `checkout_request_id` and `mode` |
| `GET /topups/{id}` | rider | Poll a top-up (`pending`, `success`, `failed`) |
| `POST /mpesa/callback/{secret}` | secret | Daraja result. Replies `{"ResultCode":0,"ResultDesc":"Accepted"}` |
| `POST /dev/mpesa/confirm/{checkout_request_id}?success=true` | rider | Mock mode only: simulate the PIN entry |
| `GET /validator/config` | validator | Device, operator, station, `mode` (`distance` or `flat`) and the fare (the maximum for distance stations) |
| `POST /taps/sync` | validator | Batch of offline taps (max 500). Safe to re-send |
| `GET /operator/summary` | operator | KPIs, 7-day series, by-station, hourly profile, peak hours |
| `GET /operator/flags` | operator | Suspicious trips with reasons |
| `GET /operator/payouts` | operator | Last 20 payouts |
| `POST /operator/payouts/run` | operator | Simulated payout of all unpaid trips (409 if none) |

## Sync request and response

```json
POST /api/taps/sync
{ "taps": [ { "tap_id": "3f1c...", "pass_token": "<jwt from QR>", "tapped_at": "2026-10-16T05:12:09.000Z" } ] }
```

```json
{ "results": [ { "tap_id": "3f1c...", "status": "charged", "reason": null, "fare": 50, "duplicate": false, "balance": 450 } ] }
```

`duplicate: true` means this tap id was already processed; the original result is returned and
nothing is charged again.

## Distance fares: boarding and alighting

Each tap in `POST /taps/sync` has an optional `direction`: `"in"` (default, so older devices keep working) or `"out"`.

```json
{ "taps": [ { "tap_id": "9c1e...", "pass_token": "<jwt from QR>", "tapped_at": "2026-10-16T05:40:00.000Z", "direction": "out" } ] }
```

Each result adds `direction`, `refund`, `from_station` and `to_station`:

```json
{ "tap_id": "9c1e...", "direction": "out", "status": "settled", "reason": null, "fare": 45, "refund": 35,
  "duplicate": false, "balance": 455, "from_station": "Nairobi Central", "to_station": "Githurai" }
```

| Direction | Status | Meaning |
| --- | --- | --- |
| in | `open` | Maximum fare held, waiting for the exit scan |
| in | `charged` | Flat-fare stop: charged and final |
| in | `declined` / `rejected` | Balance too low, or the pass failed a check |
| out | `settled` | Exact fare found, difference refunded |
| out | `cancelled` | Exited at the boarding station: fully refunded |
| out | `orphan` | No boarding scan yet (reason `no_tap_in`); matched later if it arrives |
| out | `ignored` | Flat-fare stop, nothing to settle |
| out | `rejected` | Pass failed a check |

`GET /operator/summary` also returns `open_journeys`. `GET /wallet` entries now include `kind`
(`topup`, `fare` or `refund`). See `docs/FARES.md` for the rules.
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/DATA_MODEL.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/DATA_MODEL.md' @'
# Data model

```mermaid
erDiagram
    RIDERS ||--o{ WALLET_LEDGER : has
    RIDERS ||--o{ TOPUPS : starts
    RIDERS ||--o{ TRIPS : takes
    OPERATORS ||--o{ VALIDATORS : owns
    OPERATORS ||--o{ TRIPS : earns
    OPERATORS ||--o{ PAYOUTS : receives
    STATIONS ||--o{ VALIDATORS : hosts
    STATIONS ||--o{ TRIPS : boards
    VALIDATORS ||--o{ TRIPS : records
    PAYOUTS ||--o{ TRIPS : settles
```

## The ledger rule

`wallet_ledger` never has rows edited or deleted. Balance = `SUM(amount)` for the rider.
`UNIQUE (kind, ref)` means the same M-Pesa receipt (kind `topup`) or the same tap id (kind `fare`)
can post only once, even if a callback or sync is repeated.

## Tables

| Table | Key columns | Notes |
| --- | --- | --- |
| `riders` | id, phone (unique, `2547XXXXXXXX`), name, pin_hash | PIN stored as salted PBKDF2 |
| `operators` | id, name, username (unique), password_hash | Dashboard login |
| `stations` | id, name, order_index, fare | Boarding points; flat fare per point (KES) |
| `validators` | id, name, api_key (unique), operator_id, station_id | A device fixed to one operator and one point |
| `topups` | id, rider_id, amount, phone, checkout_request_id (unique), status, mpesa_receipt | `pending`, `success` or `failed` |
| `wallet_ledger` | id, rider_id, amount (+/-), kind, ref, created_at | `topup`, `fare` or `adjustment` |
| `trips` | id (tap id from the device), rider_id, validator_id, station_id, operator_id, pass_jti, tapped_at, fare, status, reason, payout_id | `charged`, `declined`, `rejected` |
| `payouts` | id, operator_id, period_start, period_end, trips_count, gross, fee, net, status | Simulated settlement |

## Trip status and reason

| Status | Reason | Meaning | Money moves? |
| --- | --- | --- | --- |
| charged | - | Fare debited once | Yes |
| declined | insufficient_funds | Balance minus fare would pass the overdraft limit | No |
| rejected | invalid_pass | Signature failed or not a pass | No |
| rejected | stale_pass | Tap time outside the pass's validity window | No |
| rejected | replayed_pass | Same pass already used on another tap | No |
| rejected | unknown_rider | Valid signature, rider no longer exists | No |

## Time and money

- All datetimes are stored as naive UTC. Reports convert to Nairobi time (UTC+3, `LOCAL_UTC_OFFSET_HOURS`).
- All money is whole Kenya shillings (integers).

## Distance fare additions

| Table or column | Notes |
| --- | --- |
| `fares` | `from_station_id`, `to_station_id`, `price`. Unique per pair, one row per direction. A station with outgoing rows is a distance station. |
| `tap_outs` | One row per exit scan: id (tap id from the device), rider, station, operator, pass id, tap time, `status` (`settled`, `cancelled`, `orphan`, `ignored`, `rejected`), `reason`, `trip_id`, `final_fare`, `refund` |
| `trips.hold` | Amount debited at boarding (the maximum). `trips.fare` is the amount finally kept. |
| `trips.exit_station_id`, `exit_at`, `exit_tap_id` | Filled in when the journey settles |
| `wallet_ledger.kind = 'refund'` | Credit for the difference at exit, referenced by trip id (unique, so refunded once) |

`trips.status` values are now `open`, `charged`, `declined`, `rejected` and `cancelled`.
Only `charged` trips count as revenue and are paid out. Older databases are upgraded automatically on start-up.
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/DEMO_SCRIPT.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/DEMO_SCRIPT.md' @'
# Showcase script (about 4 minutes)

## Before you start

```bash
python -m app.seed --reset --history
uvicorn app.main:app
```

Open three browser windows: `/rider/`, `/validator/`, `/operator/` (the rider on your phone if you can).
Browsers allow the camera on `localhost` and HTTPS only.

## Run of show

1. **The problem (20 s).** One account for rail and matatus, paid with M-Pesa. Earlier cards failed because
   they were many incompatible cards. This is one account.
2. **Top up (40 s).** Rider app, sign in as 0712 345 678 / 1234. Enter 200, send the prompt, approve (simulated).
   Balance rises. Point out the M-Pesa receipt in the history.
3. **The pass (20 s).** Show the QR and the countdown bar. Explain it is signed and expires, so a screenshot is useless.
4. **Go offline (60 s).** Validator: connect with `demo-validator-key-1`, tick "Simulate offline". Scan the rider's QR
   (or paste the token). The gate says "Go ahead" and the queue shows 1 waiting.
5. **Come back online (40 s).** Untick offline. The queue syncs, the rider's balance drops by one fare. Scan the same
   QR again: it is rejected as a replay, with no second charge.
6. **Operator view (60 s).** Sign in as `rail` / `demo1234`. Show revenue, the busiest hours (highlighted), trips per
   boarding point. Open Suspicious trips and explain the three rules plus the anomaly model. Click Run payout and
   show gross, fee and net. Say clearly that no real money moves.
7. **Close (20 s).** Roadmap: pilot with one rail station pair, add feeders, align with the national system.

## If something goes wrong

| Problem | Fix |
| --- | --- |
| Camera will not start | Use "No camera? Paste a pass". Get a token from `GET /api/pass` in `/docs` (Authorize with the rider token first) |
| Rider balance too low | Top up again in the rider app |
| Dashboard empty | Re-run `python -m app.seed --reset --history` and restart |
| Projector blocks CDN scripts | Open each page once on the venue Wi-Fi first so the browser caches them |

## Distance fare demo (about 2 minutes)

Open two gate windows: sign in with device ID `demo-validator-key-1` (Nairobi Central) and `demo-validator-key-4`
(Githurai), leaving the passcode empty. Set the second gate to **Alighting**.

1. In the rider app (0712 345 678 / 1234), open the Pass tab and copy the token (or use the camera).
2. Gate 1 scans the pass: balance drops by 80 (the maximum is held).
3. Gate 2 scans the same pass: balance rises by 35. The fare was 45.
4. Rider Activity shows "Fare held from Nairobi Central" and "Refund: Nairobi Central to Githurai".
5. Try Thika as the exit (`demo-validator-key-6`): the fare is the full 80, no refund.
6. On the operator dashboard, "In journeys now" counts riders who have boarded but not left, and revenue rises
   only when journeys settle.

Other gates: `-3` Makadara, `-5` Ruiru, `-2` the flat-fare feeder stop (no Boarding/Alighting switch).
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/FRAUD_MODEL.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/FRAUD_MODEL.md' @'
# Suspicious-trip detection

Code: `app/fraud.py`. Endpoint: `GET /api/operator/flags`. Flags are computed on demand from the
last 14 days of the operator's trips; nothing is blocked automatically.

## Rules (always on, easy to explain)

| Flag | Trigger |
| --- | --- |
| `double_tap` | Same rider, same boarding point, under 2 minutes after their previous trip |
| `impossible_travel` | Same rider, a different boarding point, under 5 minutes after their previous trip |
| `rapid_burst` | 4 or more trips by one rider inside one hour |
| `missed_tap_out` | The journey was closed at the maximum fare because the rider never tapped out |
| `exit_without_entry` | An exit scan an hour or more old that no boarding scan has matched |

## Anomaly model (optional)

- Library: scikit-learn `IsolationForest`, 100 trees, contamination 2%.
- Features per trip: log of seconds since the rider's previous trip, trips in the last hour, local hour of day.
- Trained on all of the operator's recent trips each time the endpoint is called; needs at least 60 trips.
- Trips the model scores as outliers but the rules did not catch are labelled `model_outlier`.
- If scikit-learn is not installed, the rules still run.

## Test data

`python -m app.seed --history` creates 40 simulated riders over 14 days of commuter trips (peaks around 07:00 and
18:00) plus six injected anomaly groups (double taps, impossible travel, bursts). The test suite asserts that
all three rule flags appear.

## Limits and good practice

- Simulated data proves the pipeline works, not that the model is accurate on real riders.
- Treat flags as leads for a human to review. False positives are expected (for example, a family sharing a phone).
- Flags show an anonymous rider number, not the phone or name.
- Real use needs a data protection impact assessment under the Kenya Data Protection Act 2019.
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/OFFLINE_SYNC.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/OFFLINE_SYNC.md' @'
# Offline sync

Goal: a gate keeps moving when the network drops, nobody is charged twice, and fraud is still caught.

## On the validator (`web/validator/app.js`)

1. Scan a QR code (camera + jsQR) or paste a token.
2. Check locally that it looks like a pass and has not expired (payload is decoded, **not** verified).
3. Save `{tap_id, pass_token, tapped_at}` to IndexedDB. `tap_id` is a UUID made on the device.
4. Show "Go ahead". No server call is needed for this.
5. When online (browser event, a 10 second timer, or the Sync button) send the queue to `POST /taps/sync`, then delete the taps the server answered.

The service worker (`sw.js`) caches the page and scanner library so the device can open with no
connection after its first visit. The station and fare are cached in `localStorage`.

## On the server (`app/trips.py`)

Each tap is processed in time order:

1. Known `tap_id`? Return the stored result. This is what makes retries safe.
2. Signature valid and typed `pass`? Otherwise `invalid_pass`.
3. Tap time within the pass's `iat`/`exp` plus tolerance (`TAP_TOLERANCE_SECONDS`, default 300)? Otherwise `stale_pass`. A screenshot used later fails here.
4. Same pass token id (`jti`) already on another tap? `replayed_pass`.
5. Balance minus fare no lower than `-OVERDRAFT_LIMIT`? Otherwise `declined`.
6. Else `charged`: one negative ledger row with the tap id as reference.

## Why an overdraft limit

The gate cannot know the balance offline. A small negative allowance (default KES 50) lets a rider
whose balance is slightly short through, and the next top-up recovers it. Beyond the limit the trip
is `declined` and flagged for the operator.

## Known limits of this MVP

| Limit | Mitigation later |
| --- | --- |
| The validator cannot verify the signature offline (it holds no key) | Public-key signed passes (ECDSA) verified in the browser |
| Device clock errors can make a tap look stale | Sync time from the server and record clock drift |
| A lost phone loses its unsynced queue | Encrypt and back up the queue, or use dedicated devices |
| Two validators can accept the same pass before either syncs | Server rejects the second on sync; short pass life limits the window |

## Boarding and alighting scans

The gate stores a `direction` ("in" or "out") with every tap, so exit scans queue offline exactly like boarding scans.
Two gates may sync in any order. If an exit scan arrives before its boarding scan, the server keeps it as an
`orphan` and settles the journey as soon as the boarding scan arrives. A pass may be used once to enter and once to
leave, so short journeys work. See `docs/FARES.md`.
'@
$script:count++

# ---------------------------------------------------------------------------
# docs/UI.md
# ---------------------------------------------------------------------------
Write-BundleFile 'docs/UI.md' @'
# User interface guide

The front end is plain HTML, CSS and JavaScript in `web/`. There is no build step and no framework.
FastAPI serves the folder, so `/` is the landing page and the app screens sit beside it.

## Pages

| URL | Purpose | Files |
| --- | --- | --- |
| `/` | Landing page | `web/index.html`, `shared/site.css` |
| `/login/` | One sign-in and sign-up form for everyone | `web/login/index.html`, `app.js` |
| `/rider/` | Wallet, QR pass, M-Pesa top-up, activity | `web/rider/` |
| `/operator/` | Revenue, demand, suspicious trips, payouts | `web/operator/` |
| `/validator/` | Gate scanner with offline queue | `web/validator/` (also `sw.js`) |
| shared | Theme, API helper and session, icons and chart | `web/shared/theme.css`, `api.js`, `ui.js` |

## Sign-in routing (nothing about account types is shown on the form)

The form has two fields, "Account" and "Passcode". What is typed decides the destination.

| Typed in Account | Passcode | Tried against | Lands on |
| --- | --- | --- | --- |
| A phone number | PIN | `POST /auth/login` | `/rider/` |
| Anything else | Password | `POST /auth/operator/login` | `/operator/` |
| Anything else, or the operator step failed | (empty) | `GET /validator/config` with the value as the device key | `/validator/` |

- Every failed attempt shows the same message, so the screen never reveals which kinds of account exist.
- "Create an account" is for riders only (`POST /auth/register`).
- The result is stored as one `tl_session` in `localStorage`: `{role, token | key, name}`.
- Each protected page calls `Session.require('<role>')` first. Signed-out visitors go to `/login/`; someone
  with the wrong role is sent to their own screen.

Demo logins for the team (they are deliberately not shown anywhere in the UI):

| Who | Account | Passcode |
| --- | --- | --- |
| Rider | 0712 345 678 | 1234 |
| Rider with history | 0700 000 000 | 0000 |
| Operator | rail | demo1234 |
| Operator (feeder) | sacco | demo1234 |
| Gate device | demo-validator-key-1 to -6 (Central, feeder stop, Makadara, Githurai, Ruiru, Thika) | (leave empty) |

A device key works like a password: anyone who has it can sign in as that device. Issue real keys per
device and rotate them if a device is lost.

## Design system

Taken from the supplied reference: dark green backdrop, lime `#DCFFAD`, white `#FFFFFF`, sage `#7B9575`,
ink `#1C2120`, SF Pro Display (falls back to the system font on devices without it), hatched fills,
a floating pill navigation and round icon buttons. All tokens are CSS variables at the top of
`shared/theme.css`.

| Piece | Where |
| --- | --- |
| Buttons (`btn-white`, `btn-lime`, `btn-black`, `btn-ghost`, `icon-btn`) | `theme.css` |
| Cards (`card-white`, `card-lime`, `card-glass`, `card-dark`), tiles | `theme.css` |
| Hatched bar chart with one solid bar and a white tooltip | `ui.js` `barChart()`, bar styles in `theme.css` |
| Hatched progress meter (QR countdown, boarding points) | `.meter` in `theme.css` |
| Icons and the seven-point brand star | `ui.js` (`icon()`, `star()`, `mountIcons()`) |

## Responsive behaviour

- Phones: one view at a time, switched with the floating pill nav (`.view.active`).
- From 1000px wide: the pill nav hides and every view shows at once as a two-column dashboard.
  Round action buttons then scroll to the matching section instead of switching views.
- The layout has been checked for horizontal overflow at 320, 390, 768 and 1280px wide.

## Notes and limits

- The QR pass uses `qrcodejs` and the scanner uses `jsQR`, both loaded from the jsDelivr CDN with pinned versions.
  Open the validator once online so its service worker can cache the scanner for offline use.
- The rider chart is built from the latest 30 wallet entries returned by `GET /wallet`, so very busy
  accounts may show a partial week.
- The camera needs HTTPS or `localhost`.
- Absolute paths such as `/login/` assume the app is served from the site root.
- Sessions are kept in `localStorage` and there is no login throttling yet (see `docs/DEPLOY.md`).
'@
$script:count++


Write-Host ""
Write-Host "Done. $($script:count) files written." -ForegroundColor Green
if (Test-Path $backup) { Write-Host "Previous versions of changed files are in $backup" }
Write-Host "Restart the app:  cd $Target ; uvicorn app.main:app --reload"
Write-Host "The database upgrades itself on start-up. For a clean demo: python -m app.seed --reset --history"
Write-Host "Read docs/FARES.md first. New gate devices: demo-validator-key-3 to -6 (leave the passcode empty)."
