"""Configuration settings for K.A.R.E.N. Remote Link Backend Relay."""

from __future__ import annotations
import os
from pathlib import Path
from pydantic import BaseModel

DEFAULT_DATA_DIR = Path.home() / ".karen_remotelink"
DEFAULT_DATA_DIR.mkdir(parents=True, exist_ok=True)


class Settings(BaseModel):
    host: str = os.getenv("KAREN_REMOTE_HOST", "0.0.0.0")
    port: int = int(os.getenv("KAREN_REMOTE_PORT", "8765"))
    db_path: str = os.getenv("KAREN_REMOTE_DB", str(DEFAULT_DATA_DIR / "remotelink.sqlite3"))
    fcm_service_account_path: str | None = os.getenv("KAREN_FCM_CREDENTIALS")
    pairing_code_expiry_seconds: int = int(os.getenv("KAREN_PAIRING_EXPIRY", "300"))
    default_request_timeout_seconds: int = int(os.getenv("KAREN_DEFAULT_TIMEOUT", "120"))
    cleanup_interval_seconds: float = float(os.getenv("KAREN_CLEANUP_INTERVAL", "1.0"))
    server_base_url: str = os.getenv("KAREN_SERVER_BASE_URL", "http://127.0.0.1:8765")


settings = Settings()

