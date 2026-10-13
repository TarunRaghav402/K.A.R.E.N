"""
SQLite-backed memory store (approval-gated).
Schema:
  memories(id TEXT PK, content TEXT, approved INTEGER, created_at TEXT, deleted INTEGER)
Only approved=1 rows are returned to the LLM. Users can view/delete via the Swift UI.
"""

from __future__ import annotations
import asyncio
import json
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path

DB_PATH = Path.home() / "Library" / "Application Support" / "KAREN" / "memory.sqlite"


class Memory:
    def __init__(self, db_path: Path = DB_PATH):
        self.db_path = db_path
        self._conn: sqlite3.Connection | None = None

    def _connect(self) -> sqlite3.Connection:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(self.db_path), check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("""
            CREATE TABLE IF NOT EXISTS memories (
                id         TEXT PRIMARY KEY,
                content    TEXT NOT NULL,
                approved   INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                deleted    INTEGER NOT NULL DEFAULT 0
            )
        """)
        conn.commit()
        return conn

    @property
    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            self._conn = self._connect()
        return self._conn

    def propose(self, content: str) -> str:
        """Add a memory in unapproved state; returns its id."""
        mid = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        self.conn.execute(
            "INSERT INTO memories(id,content,approved,created_at,deleted) VALUES(?,?,0,?,0)",
            (mid, content, now),
        )
        self.conn.commit()
        return mid

    def approve(self, mid: str) -> None:
        self.conn.execute("UPDATE memories SET approved=1 WHERE id=?", (mid,))
        self.conn.commit()

    def delete(self, mid: str) -> None:
        self.conn.execute("UPDATE memories SET deleted=1 WHERE id=?", (mid,))
        self.conn.commit()

    def list_approved(self) -> list[dict]:
        rows = self.conn.execute(
            "SELECT id,content,created_at FROM memories WHERE approved=1 AND deleted=0 ORDER BY created_at DESC"
        ).fetchall()
        return [dict(r) for r in rows]

    def list_pending(self) -> list[dict]:
        rows = self.conn.execute(
            "SELECT id,content,created_at FROM memories WHERE approved=0 AND deleted=0"
        ).fetchall()
        return [dict(r) for r in rows]

    def context_block(self) -> str:
        rows = self.list_approved()
        if not rows:
            return ""
        lines = "\n".join(f"- {r['content']}" for r in rows[:20])
        return f"[User memory]\n{lines}"
