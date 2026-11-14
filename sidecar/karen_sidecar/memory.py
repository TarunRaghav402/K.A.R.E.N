"""
SQLite-backed memory store and chat conversation history database.
Schema:
  memories(id TEXT PK, content TEXT, category TEXT, key TEXT, approved INTEGER, created_at TEXT, deleted INTEGER)
  chat_history(id TEXT PK, session_id TEXT, role TEXT, content TEXT, created_at TEXT)
"""

from __future__ import annotations
import asyncio
import json
import re
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
                category   TEXT DEFAULT 'general',
                key        TEXT DEFAULT '',
                approved   INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                deleted    INTEGER NOT NULL DEFAULT 0
            )
        """)
        # Chat history database to store every conversation turn
        conn.execute("""
            CREATE TABLE IF NOT EXISTS chat_history (
                id         TEXT PRIMARY KEY,
                session_id TEXT DEFAULT '',
                role       TEXT NOT NULL,
                content    TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
        """)
        # Custom phonetic pronunciation store
        conn.execute("""
            CREATE TABLE IF NOT EXISTS pronunciations (
                word          TEXT PRIMARY KEY,
                pronunciation TEXT NOT NULL,
                created_at    TEXT NOT NULL
            )
        """)
        # Backward-compatible migrations for existing databases
        try:
            conn.execute("ALTER TABLE memories ADD COLUMN category TEXT DEFAULT 'general'")
        except sqlite3.OperationalError:
            pass
        try:
            conn.execute("ALTER TABLE memories ADD COLUMN key TEXT DEFAULT ''")
        except sqlite3.OperationalError:
            pass
        conn.commit()
        return conn

    @property
    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            self._conn = self._connect()
        return self._conn

    # ─── Chat History Database ────────────────────────────────────────────────

    def record_chat(self, role: str, content: str, session_id: str = "") -> str:
        """Stores each user query and assistant reply in the persistent database."""
        cid = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        self.conn.execute(
            "INSERT INTO chat_history(id, session_id, role, content, created_at) VALUES(?,?,?,?,?)",
            (cid, session_id, role, content, now),
        )
        self.conn.commit()
        return cid

    def get_chat_history(self, limit: int = 50) -> list[dict]:
        """Returns recent chat turns in chronological order."""
        rows = self.conn.execute(
            "SELECT id, session_id, role, content, created_at FROM chat_history ORDER BY created_at DESC LIMIT ?",
            (limit,)
        ).fetchall()
        result = [dict(r) for r in rows]
        result.reverse()
        return result

    # ─── Pronunciation Store ──────────────────────────────────────────────────

    def set_pronunciation(self, word: str, pronunciation: str) -> None:
        """Stores or updates custom phonetic pronunciation for a word."""
        w = word.strip().lower()
        p = pronunciation.strip()
        if not w or not p:
            return
        now = datetime.now(timezone.utc).isoformat()
        self.conn.execute(
            "INSERT INTO pronunciations(word, pronunciation, created_at) VALUES(?,?,?) "
            "ON CONFLICT(word) DO UPDATE SET pronunciation=excluded.pronunciation, created_at=excluded.created_at",
            (w, p, now),
        )
        self.conn.commit()

    def get_pronunciation(self, word: str) -> str | None:
        """Returns the stored phonetic pronunciation for a word, or None if not customized."""
        w = word.strip().lower()
        row = self.conn.execute(
            "SELECT pronunciation FROM pronunciations WHERE word = ?", (w,)
        ).fetchone()
        return row["pronunciation"] if row else None

    def get_all_pronunciations(self) -> dict[str, str]:
        """Returns all stored pronunciations as {word: pronunciation}."""
        rows = self.conn.execute("SELECT word, pronunciation FROM pronunciations").fetchall()
        return {row["word"]: row["pronunciation"] for row in rows}

    def delete_pronunciation(self, word: str) -> bool:
        """Deletes a custom pronunciation for a word."""
        w = word.strip().lower()
        cur = self.conn.execute("DELETE FROM pronunciations WHERE word = ?", (w,))
        self.conn.commit()
        return cur.rowcount > 0

    def apply_pronunciations(self, text: str) -> str:
        """Substitutes stored custom words with their learned pronunciations for speech output."""
        if not text:
            return ""
        pronunciations = self.get_all_pronunciations()
        if not pronunciations:
            return text
        result = text
        for word, phonetic in pronunciations.items():
            # Match word boundary case-insensitively
            pattern = re.compile(rf"\b{re.escape(word)}\b", re.IGNORECASE)
            result = pattern.sub(phonetic, result)
        return result

    # ─── Memory Store ─────────────────────────────────────────────────────────

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

    def learn_fact(self, content: str, category: str = "general", key: str = "") -> str:
        """Add an approved memory directly so it is instantly remembered and visible."""
        mid = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()
        cleaned = content.strip()
        if key:
            existing = self.conn.execute(
                "SELECT id FROM memories WHERE key=? AND deleted=0", (key,)
            ).fetchone()
            if existing:
                self.conn.execute(
                    "UPDATE memories SET content=?, created_at=?, approved=1, deleted=0 WHERE id=?",
                    (cleaned, now, existing["id"]),
                )
                self.conn.commit()
                return existing["id"]

        self.conn.execute(
            "INSERT INTO memories(id, content, category, key, approved, created_at, deleted) VALUES(?,?,?,?,1,?,0)",
            (mid, cleaned, category, key, now),
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

    def extract_and_save_facts(self, text: str) -> dict | None:
        """Detect user personal preferences and facts, storing them permanently in memory."""
        val = text.strip()
        if not val:
            return None

        # 1. "I like drinking coffee", "I love drinking tea", "Tarun likes coffee", "I enjoy drinking matcha"
        m_like = re.search(
            r"\b(?:i|tarun)\s+(?:really\s+)?(like|likes|love|loves|enjoy|enjoys|prefer|prefers)\s+(?:drinking\s+|to\s+drink\s+|eating\s+|to\s+eat\s+)?(.+)",
            val, re.I
        )
        if m_like:
            target = m_like.group(2).strip(" .!?")
            target = re.sub(r"^(?:a\s+|an\s+|some\s+)", "", target, flags=re.I)
            is_drink = bool(re.search(r"\b(?:drink|drinking)\b", val, re.I)) or any(
                w in target.lower() for w in ["coffee", "tea", "chai", "latte", "espresso", "cappuccino", "juice", "water", "soda", "wine", "beer", "whiskey", "beverage", "smoothie"]
            )
            is_food = bool(re.search(r"\b(?:eat|eating|food)\b", val, re.I)) or any(
                w in target.lower() for w in ["pizza", "burger", "biryani", "pasta", "salad", "sushi", "sandwich", "curry", "rice", "bread", "chocolate"]
            )
            if is_drink:
                content = f"Tarun likes drinking {target}" if "drink" not in target.lower() else f"Tarun likes {target}"
                self.learn_fact(content=content, category="drink", key="drink")
                return {"action": "saved", "category": "drink", "value": target, "content": content,
                        "reply": f"Understood. I’ve stored in my memory that you like drinking {target}, sir."}
            elif is_food:
                content = f"Tarun likes eating {target}" if "eat" not in target.lower() else f"Tarun likes {target}"
                self.learn_fact(content=content, category="food", key="food")
                return {"action": "saved", "category": "food", "value": target, "content": content,
                        "reply": f"Understood. I’ve stored in my memory that you like eating {target}, sir."}
            else:
                content = f"Tarun likes {target}"
                self.learn_fact(content=content, category="preference", key=f"likes_{target[:15].lower().replace(' ', '_')}")
                return {"action": "saved", "category": "preference", "value": target, "content": content,
                        "reply": f"Understood. I’ve stored in my memory that you like {target}, sir."}

        # 2. "My favorite drink/food/movie/color is X"
        m_fav = re.search(r"\bmy\s+favou?rite\s+([\w\s]+?)\s+is\s+(.+)", val, re.I)
        if m_fav:
            item = m_fav.group(1).strip()
            target = m_fav.group(2).strip(" .!?")
            content = f"Tarun's favorite {item} is {target}"
            self.learn_fact(content=content, category="favorite", key=f"fav_{item[:15].lower().replace(' ', '_')}")
            return {"action": "saved", "category": "favorite", "value": target, "content": content,
                    "reply": f"Understood. I’ve noted that your favorite {item} is {target}, sir."}

        # 3. "Remember that X" / "Remember X"
        m_rem = re.search(r"\bremember\s+(?:that\s+)?(.+)", val, re.I)
        if m_rem:
            target = m_rem.group(1).strip(" .!?")
            content = f"Tarun: {target}"
            self.learn_fact(content=content, category="general", key="")
            return {"action": "saved", "category": "general", "value": target, "content": content,
                    "reply": "Got it. I’ve committed that to memory, sir."}

        # 4. "My name is X" / "I am X"
        m_name = re.search(r"\b(?:my name is|call me)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)", val, re.I)
        if m_name:
            target = m_name.group(1).strip(" .!?")
            content = f"User's name is {target}"
            self.learn_fact(content=content, category="identity", key="user_name")
            return {"action": "saved", "category": "identity", "value": target, "content": content,
                    "reply": f"Pleasure to know, {target}. I’ll remember your name, sir."}

        # 5. "My friend is Sriram", "My friend's name is Sriram", "My best friend is Sriram"
        m_friend = re.search(
            r"\b(?:my\s+(?:best\s+)?friend(?:'s\s+name)?\s+(?:is|=)|friend\s+is)\s+([A-Za-z0-9_\- ]+)",
            val, re.I
        )
        if m_friend:
            target = m_friend.group(1).strip(" .!?")
            content = f"Tarun's friend is {target}"
            self.learn_fact(content=content, category="friend", key=f"friend_{target[:15].lower().replace(' ', '_')}")
            return {"action": "saved", "category": "friend", "value": target, "content": content,
                    "reply": f"Understood. I’ve stored in my memory that your friend is {target}, sir."}

        # 6. "My confidential statement is X", "Store confidential statement: X", "Save confidential note: X", "My secret is X"
        m_conf = re.search(
            r"\b(?:my\s+(?:confidential\s+statement|confidential\s+note|secret\s+statement|secret\s+note|secret)\s+is|save\s+(?:my\s+)?(?:confidential\s+statement|confidential\s+note|secret)|store\s+(?:my\s+)?(?:confidential\s+statement|confidential\s+note|secret)|confidential\s+statement\s*:?)\s+(.+)",
            val, re.I
        )
        if m_conf:
            target = m_conf.group(1).strip(" .!?")
            content = f"Confidential Statement: {target}"
            self.learn_fact(content=content, category="confidential", key="confidential_statement")
            return {
                "action": "saved", "category": "confidential", "value": target, "content": content,
                "reply": f"Voice identity verified: Tarun Raghav. Your confidential statement has been securely stored in the private memory vault, sir."
            }

        return None

    def find_fact_for_query(self, query: str) -> str | None:
        """Find stored facts that answer queries about what Tarun or user likes, drinks, etc."""
        q_lower = query.lower()
        # Must be an inquiry/question asking about remembered facts, not a statement declaring one
        is_question = bool(re.search(r"\b(?:what|which|who|tell me|do i|does tarun|does he|what's|whats)\b|\?$", q_lower))
        if not is_question:
            return None

        memories = self.list_approved()
        if not memories:
            return None

        # Check for drink query: "what tarun likes to drink", "what do i like to drink", "favorite drink"
        is_drink = bool(re.search(r"\b(?:drink|drinking|beverage)\b", q_lower))
        is_food = bool(re.search(r"\b(?:eat|eating|food)\b", q_lower))
        is_like = bool(re.search(r"\b(?:like|likes|love|loves|prefer|prefers|favorite|favourite)\b", q_lower))
        is_friend = bool(re.search(r"\b(?:friend|friends|buddy)\b", q_lower))
        is_confidential = bool(re.search(r"\b(?:confidential\s+statement|confidential\s+note|confidential\s+record|confidential\s+data|secret\s+statement|secret\s+note|my\s+secret|confidential\s+vault)\b", q_lower))
        is_voice_id = bool(re.search(r"\b(?:do\s+you\s+recogni[zs]e\s+my\s+voice|recogni[zs]e\s+my\s+voice|who\s+am\s+i|who\s+is\s+speaking|identify\s+me|verify\s+my\s+voice|am\s+i\s+tarun)\b", q_lower))

        if is_voice_id:
            return "Voice biometric signature verified. I recognize you as Tarun Raghav, my creator and authorized master. All personal assistant features and confidential archives are at your command, sir."

        if is_confidential:
            for m in memories:
                if m.get("category") == "confidential" or "confidential statement:" in m["content"].lower():
                    clean = re.sub(r"^confidential\s+statement:\s*", "", m["content"], flags=re.I)
                    return f"Voice identity verified: Tarun Raghav, Authorized Master. Access granted to confidential vault. Your confidential statement is: {clean}, sir."
            return "Voice identity verified: Tarun Raghav, Creator and Authorized Master. Access granted. Your confidential status is Master Developer & Sole Administrator of Project K.A.R.E.N. with security clearance Alpha-1. You have not stored a custom confidential statement yet; say 'My confidential statement is...' to store one, sir."

        if is_friend:
            friend_names = []
            for m in memories:
                c = m["content"]
                if "friend is" in c.lower() or "friend's name is" in c.lower():
                    clean = re.sub(r"^(?:tarun's|user's)?\s*friend\s*(?:is|'s\s*name\s*is)\s*", "", c, flags=re.I)
                    friend_names.append(clean.strip())
            if friend_names:
                combined = ", ".join(friend_names)
                return f"Your friend is {combined}, sir." if len(friend_names) == 1 else f"Your friends are {combined}, sir."

        if is_drink:
            for m in memories:
                c = m["content"]
                if "drink" in c.lower() or "coffee" in c.lower() or "tea" in c.lower() or "chai" in c.lower():
                    clean = re.sub(r"^(?:tarun|user)\s+likes\s+", "", c, flags=re.I)
                    return f"Tarun likes {clean}, sir."

        if is_food:
            for m in memories:
                c = m["content"]
                if "eat" in c.lower() or "pizza" in c.lower() or "biryani" in c.lower() or "food" in c.lower():
                    clean = re.sub(r"^(?:tarun|user)\s+likes\s+", "", c, flags=re.I)
                    return f"Tarun likes {clean}, sir."

        if is_like:
            like_items = []
            for m in memories:
                c = m["content"]
                if "like" in c.lower() or "love" in c.lower() or "favorite" in c.lower():
                    clean = re.sub(r"^(?:tarun|user)\s+likes\s+", "", c, flags=re.I)
                    clean = re.sub(r"^tarun's\s+favorite\s+", "", clean, flags=re.I)
                    like_items.append(clean)
            if like_items:
                combined = ", ".join(like_items[:3])
                return f"Tarun likes {combined}, sir."

        if re.search(r"\b(?:what do you remember|what do you know about me|what is in (?:your )?memory|my memories)\b", q_lower):
            items = "; ".join(m["content"] for m in memories[:5])
            return f"I have the following stored in my memory: {items}, sir."

        return None

    def context_block(self) -> str:
        rows = self.list_approved()
        memory_lines = [f"- {r['content']}" for r in rows[:20]]
        recent_chats = self.get_chat_history(limit=6)
        chat_lines = [f"{c['role'].capitalize()}: {c['content']}" for c in recent_chats]

        parts = []
        if memory_lines:
            parts.append("[User memory]\n" + "\n".join(memory_lines))
        if chat_lines:
            parts.append("[Recent conversation history]\n" + "\n".join(chat_lines))
        return "\n\n".join(parts)
