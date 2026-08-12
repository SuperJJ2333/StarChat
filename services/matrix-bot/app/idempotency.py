from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any


class IdempotencyStore:
    def __init__(self, database_path: str, ttl_seconds: int) -> None:
        self._database_path = Path(database_path)
        self._database_path.parent.mkdir(parents=True, exist_ok=True)
        self._ttl_seconds = ttl_seconds
        self._lock = threading.Lock()
        self._connection = sqlite3.connect(self._database_path, check_same_thread=False)
        self._connection.execute(
            """
            CREATE TABLE IF NOT EXISTS idempotency_keys (
                key TEXT PRIMARY KEY,
                response_json TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """
        )
        self._connection.commit()

    def get(self, key: str) -> dict[str, Any] | None:
        with self._lock:
            self._purge_expired_locked()
            row = self._connection.execute(
                "SELECT response_json FROM idempotency_keys WHERE key = ?",
                (key,),
            ).fetchone()

        if row is None:
            return None

        return json.loads(row[0])

    def put(self, key: str, response: dict[str, Any]) -> None:
        payload = json.dumps(response)
        now = int(time.time())
        with self._lock:
            self._connection.execute(
                "INSERT OR REPLACE INTO idempotency_keys (key, response_json, created_at) VALUES (?, ?, ?)",
                (key, payload, now),
            )
            self._connection.commit()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def _purge_expired_locked(self) -> None:
        cutoff = int(time.time()) - self._ttl_seconds
        self._connection.execute("DELETE FROM idempotency_keys WHERE created_at < ?", (cutoff,))
        self._connection.commit()

