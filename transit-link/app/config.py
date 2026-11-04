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
