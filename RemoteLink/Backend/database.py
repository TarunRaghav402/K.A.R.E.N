"""Database management for K.A.R.E.N. Remote Link Backend Relay."""

from __future__ import annotations
import json
import time
import aiosqlite
from typing import Optional, List, Tuple
from pathlib import Path

from .config import settings
from .models import (
    NotificationRequestRecord,
    DeviceRecord,
    PairingSessionResponse,
)


class Database:
    def __init__(self, db_path: str = settings.db_path) -> None:
        self.db_path = db_path
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)

    async def init_db(self) -> None:
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("PRAGMA journal_mode=WAL;")
            await db.execute("""
                CREATE TABLE IF NOT EXISTS devices (
                    device_id TEXT PRIMARY KEY,
                    device_name TEXT NOT NULL,
                    device_token TEXT NOT NULL,
                    fcm_token TEXT,
                    paired_at REAL NOT NULL,
                    last_seen_at REAL NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0
                );
            """)

            await db.execute("""
                CREATE TABLE IF NOT EXISTS pairing_sessions (
                    session_id TEXT PRIMARY KEY,
                    pairing_code TEXT NOT NULL UNIQUE,
                    qr_payload TEXT NOT NULL,
                    mac_id TEXT NOT NULL,
                    mac_name TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    is_paired INTEGER NOT NULL DEFAULT 0,
                    paired_device_id TEXT
                );
            """)

            await db.execute("""
                CREATE TABLE IF NOT EXISTS notification_requests (
                    request_id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    title TEXT NOT NULL,
                    message TEXT NOT NULL,
                    details TEXT,
                    actions_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    sent_at REAL,
                    delivered_at REAL,
                    responded_at REAL,
                    expires_at REAL NOT NULL,
                    outcome TEXT,
                    reply_text TEXT,
                    responder_device_id TEXT
                );
            """)

            await db.execute("CREATE INDEX IF NOT EXISTS idx_requests_status ON notification_requests(status);")
            await db.execute("CREATE INDEX IF NOT EXISTS idx_pairing_code ON pairing_sessions(pairing_code);")
            await db.commit()

    # ─── Pairing ─────────────────────────────────────────────────────────────

    async def create_pairing_session(
        self, session_id: str, code: str, qr_payload: str, mac_id: str, mac_name: str, expires_at: float
    ) -> PairingSessionResponse:
        now = time.time()
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                """
                INSERT INTO pairing_sessions (session_id, pairing_code, qr_payload, mac_id, mac_name, created_at, expires_at, is_paired)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0);
                """,
                (session_id, code, qr_payload, mac_id, mac_name, now, expires_at),
            )
            await db.commit()
        return PairingSessionResponse(
            session_id=session_id,
            pairing_code=code,
            qr_payload=qr_payload,
            mac_id=mac_id,
            mac_name=mac_name,
            expires_at=expires_at,
            is_paired=False,
        )

    async def get_pairing_session(self, session_id: str) -> Optional[PairingSessionResponse]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute("SELECT * FROM pairing_sessions WHERE session_id = ?;", (session_id,))
            row = await cursor.fetchone()
            if not row:
                return None
            return PairingSessionResponse(
                session_id=row["session_id"],
                pairing_code=row["pairing_code"],
                qr_payload=row["qr_payload"],
                mac_id=row["mac_id"],
                mac_name=row["mac_name"],
                expires_at=row["expires_at"],
                is_paired=bool(row["is_paired"]),
                paired_device_id=row["paired_device_id"],
            )

    async def get_pairing_session_by_code(self, code: str) -> Optional[PairingSessionResponse]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                "SELECT * FROM pairing_sessions WHERE pairing_code = ? AND expires_at > ?;",
                (code.strip().upper(), time.time()),
            )
            row = await cursor.fetchone()
            if not row:
                return None
            return PairingSessionResponse(
                session_id=row["session_id"],
                pairing_code=row["pairing_code"],
                qr_payload=row["qr_payload"],
                mac_id=row["mac_id"],
                mac_name=row["mac_name"],
                expires_at=row["expires_at"],
                is_paired=bool(row["is_paired"]),
                paired_device_id=row["paired_device_id"],
            )

    async def complete_pairing_session(self, session_id: str, device_id: str) -> bool:
        async with aiosqlite.connect(self.db_path) as db:
            cursor = await db.execute(
                """
                UPDATE pairing_sessions
                SET is_paired = 1, paired_device_id = ?
                WHERE session_id = ? AND is_paired = 0;
                """,
                (device_id, session_id),
            )
            await db.commit()
            return cursor.rowcount > 0

    # ─── Devices ─────────────────────────────────────────────────────────────

    async def register_device(
        self, device_id: str, device_name: str, device_token: str, fcm_token: Optional[str] = None
    ) -> DeviceRecord:
        now = time.time()
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                """
                INSERT INTO devices (device_id, device_name, device_token, fcm_token, paired_at, last_seen_at, revoked)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(device_id) DO UPDATE SET
                    device_name = excluded.device_name,
                    device_token = excluded.device_token,
                    fcm_token = COALESCE(excluded.fcm_token, devices.fcm_token),
                    last_seen_at = excluded.last_seen_at,
                    revoked = 0;
                """,
                (device_id, device_name, device_token, fcm_token, now, now),
            )
            await db.commit()
        return DeviceRecord(
            device_id=device_id,
            device_name=device_name,
            device_token=device_token,
            fcm_token=fcm_token,
            paired_at=now,
            last_seen_at=now,
            revoked=False,
        )

    async def get_device(self, device_id: str) -> Optional[DeviceRecord]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute("SELECT * FROM devices WHERE device_id = ?;", (device_id,))
            row = await cursor.fetchone()
            if not row:
                return None
            return DeviceRecord(
                device_id=row["device_id"],
                device_name=row["device_name"],
                device_token=row["device_token"],
                fcm_token=row["fcm_token"],
                paired_at=row["paired_at"],
                last_seen_at=row["last_seen_at"],
                revoked=bool(row["revoked"]),
            )

    async def get_active_devices(self) -> List[DeviceRecord]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute("SELECT * FROM devices WHERE revoked = 0;")
            rows = await cursor.fetchall()
            return [
                DeviceRecord(
                    device_id=r["device_id"],
                    device_name=r["device_name"],
                    device_token=r["device_token"],
                    fcm_token=r["fcm_token"],
                    paired_at=r["paired_at"],
                    last_seen_at=r["last_seen_at"],
                    revoked=bool(r["revoked"]),
                )
                for r in rows
            ]

    async def update_device_last_seen(self, device_id: str) -> None:
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("UPDATE devices SET last_seen_at = ? WHERE device_id = ?;", (time.time(), device_id))
            await db.commit()

    async def revoke_device(self, device_id: str) -> bool:
        async with aiosqlite.connect(self.db_path) as db:
            cursor = await db.execute("UPDATE devices SET revoked = 1 WHERE device_id = ?;", (device_id,))
            await db.commit()
            return cursor.rowcount > 0

    # ─── Requests ────────────────────────────────────────────────────────────

    async def create_request(
        self,
        request_id: str,
        req_type: str,
        title: str,
        message: str,
        details: Optional[str],
        actions: List[str],
        timeout_seconds: int,
    ) -> NotificationRequestRecord:
        now = time.time()
        expires_at = now + timeout_seconds
        actions_json = json.dumps(actions)
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                """
                INSERT INTO notification_requests (
                    request_id, type, title, message, details, actions_json,
                    status, created_at, sent_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'SENT', ?, ?, ?);
                """,
                (request_id, req_type, title, message, details, actions_json, now, now, expires_at),
            )
            await db.commit()

        return NotificationRequestRecord(
            request_id=request_id,
            type=req_type,
            title=title,
            message=message,
            details=details,
            actions=actions,
            status="SENT",
            created_at=now,
            sent_at=now,
            expires_at=expires_at,
        )

    async def get_request(self, request_id: str) -> Optional[NotificationRequestRecord]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute("SELECT * FROM notification_requests WHERE request_id = ?;", (request_id,))
            row = await cursor.fetchone()
            if not row:
                return None
            return self._row_to_request(row)

    async def get_pending_requests(self) -> List[NotificationRequestRecord]:
        now = time.time()
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                """
                SELECT * FROM notification_requests
                WHERE status IN ('SENT', 'DELIVERED', 'WAITING') AND expires_at > ?
                ORDER BY created_at ASC;
                """,
                (now,),
            )
            rows = await cursor.fetchall()
            return [self._row_to_request(r) for r in rows]

    async def mark_request_delivered(self, request_id: str, device_id: str) -> bool:
        now = time.time()
        async with aiosqlite.connect(self.db_path) as db:
            cursor = await db.execute(
                """
                UPDATE notification_requests
                SET status = 'DELIVERED', delivered_at = ?
                WHERE request_id = ? AND status = 'SENT';
                """,
                (now, request_id),
            )
            await db.commit()
            return cursor.rowcount > 0

    async def mark_request_responded(
        self, request_id: str, outcome: str, reply_text: Optional[str], device_id: str
    ) -> Tuple[bool, Optional[NotificationRequestRecord], Optional[str]]:
        """Atomically responds to a request. Prevents duplicate responses and expired submissions."""
        now = time.time()
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute("SELECT * FROM notification_requests WHERE request_id = ?;", (request_id,))
            row = await cursor.fetchone()
            if not row:
                return False, None, "Request not found."

            current_status = row["status"]
            expires_at = row["expires_at"]

            if current_status == "RESPONDED":
                return False, self._row_to_request(row), "Request has already been responded to (duplicate prevented)."

            if current_status == "CANCELLED":
                return False, self._row_to_request(row), "Request was cancelled by Mac."

            if now > expires_at or current_status == "EXPIRED":
                # Mark as expired if not already
                await db.execute(
                    "UPDATE notification_requests SET status = 'EXPIRED', outcome = 'EXPIRED' WHERE request_id = ?;",
                    (request_id,),
                )
                await db.commit()
                return False, None, "Request has expired."

            if current_status not in ("SENT", "DELIVERED", "WAITING"):
                return False, None, f"Cannot respond to request in '{current_status}' state."

            # Update atomically
            cursor = await db.execute(
                """
                UPDATE notification_requests
                SET status = 'RESPONDED', outcome = ?, reply_text = ?, responder_device_id = ?, responded_at = ?
                WHERE request_id = ? AND status IN ('SENT', 'DELIVERED', 'WAITING');
                """,
                (outcome, reply_text, device_id, now, request_id),
            )
            await db.commit()

            if cursor.rowcount == 0:
                return False, None, "Concurrent conflict updating request."

            cursor = await db.execute("SELECT * FROM notification_requests WHERE request_id = ?;", (request_id,))
            updated_row = await cursor.fetchone()
            return True, self._row_to_request(updated_row), None

    async def mark_request_cancelled(self, request_id: str) -> Tuple[bool, Optional[NotificationRequestRecord]]:
        now = time.time()
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                """
                UPDATE notification_requests
                SET status = 'CANCELLED', outcome = 'CANCELLED', responded_at = ?
                WHERE request_id = ? AND status IN ('SENT', 'DELIVERED', 'WAITING');
                """,
                (now, request_id),
            )
            await db.commit()
            if cursor.rowcount == 0:
                return False, None

            cursor = await db.execute("SELECT * FROM notification_requests WHERE request_id = ?;", (request_id,))
            row = await cursor.fetchone()
            return True, self._row_to_request(row)

    async def expire_pending_requests(self, now: float) -> List[NotificationRequestRecord]:
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                """
                SELECT * FROM notification_requests
                WHERE status IN ('SENT', 'DELIVERED', 'WAITING') AND expires_at <= ?;
                """,
                (now,),
            )
            rows = await cursor.fetchall()
            if not rows:
                return []

            req_ids = [r["request_id"] for r in rows]
            placeholders = ",".join("?" for _ in req_ids)
            await db.execute(
                f"""
                UPDATE notification_requests
                SET status = 'EXPIRED', outcome = 'EXPIRED', responded_at = ?
                WHERE request_id IN ({placeholders});
                """,
                (now, *req_ids),
            )
            await db.commit()

            # Return updated records
            cursor = await db.execute(
                f"SELECT * FROM notification_requests WHERE request_id IN ({placeholders});", req_ids
            )
            updated_rows = await cursor.fetchall()
            return [self._row_to_request(r) for r in updated_rows]

    def _row_to_request(self, row: aiosqlite.Row) -> NotificationRequestRecord:
        actions = []
        try:
            actions = json.loads(row["actions_json"])
        except Exception:
            actions = ["APPROVE", "DENY"]

        return NotificationRequestRecord(
            request_id=row["request_id"],
            type=row["type"],
            title=row["title"],
            message=row["message"],
            details=row["details"],
            actions=actions,
            status=row["status"],
            created_at=row["created_at"],
            sent_at=row["sent_at"],
            delivered_at=row["delivered_at"],
            responded_at=row["responded_at"],
            expires_at=row["expires_at"],
            outcome=row["outcome"],
            reply_text=row["reply_text"],
            responder_device_id=row["responder_device_id"],
        )

