from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class RecordingDatabase:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        with self._lock:
            self._connection.execute("PRAGMA journal_mode = WAL")
            self._connection.execute("PRAGMA synchronous = FULL")
            self._connection.execute("PRAGMA foreign_keys = ON")
            self._connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS recordings (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    duration REAL NOT NULL DEFAULT 0,
                    status TEXT NOT NULL,
                    upload_status TEXT NOT NULL,
                    uploaded_bytes INTEGER NOT NULL DEFAULT 0,
                    device_model TEXT,
                    app_version TEXT,
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    merged_path TEXT,
                    webhook_status TEXT NOT NULL DEFAULT 'pending',
                    last_error TEXT,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS chunks (
                    recording_id TEXT NOT NULL,
                    chunk_index INTEGER NOT NULL CHECK(chunk_index > 0),
                    started_at TEXT NOT NULL,
                    duration REAL NOT NULL CHECK(duration >= 0),
                    checksum TEXT NOT NULL,
                    size INTEGER NOT NULL CHECK(size >= 0),
                    path TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(recording_id, chunk_index),
                    FOREIGN KEY(recording_id) REFERENCES recordings(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS recordings_created_at_idx
                    ON recordings(created_at DESC);
                """
            )
            self._connection.commit()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def create_recording(self, payload: dict[str, Any]) -> tuple[dict[str, Any], bool]:
        recording_id = str(payload["id"])
        created_at = str(payload.get("created_at") or utc_now())
        started_at = str(payload.get("started_at") or created_at)
        metadata = payload.get("metadata") or {}
        now = utc_now()
        with self._lock:
            cursor = self._connection.execute(
                """
                INSERT OR IGNORE INTO recordings (
                    id, created_at, started_at, status, upload_status,
                    device_model, app_version, metadata_json, updated_at
                ) VALUES (?, ?, ?, 'RECORDING', 'UPLOADING', ?, ?, ?, ?)
                """,
                (
                    recording_id,
                    created_at,
                    started_at,
                    payload.get("device_model"),
                    payload.get("app_version"),
                    json.dumps(metadata, separators=(",", ":"), sort_keys=True),
                    now,
                ),
            )
            self._connection.commit()
            created = cursor.rowcount == 1
            return self.get_recording(recording_id), created

    def recording_exists(self, recording_id: str) -> bool:
        with self._lock:
            row = self._connection.execute(
                "SELECT 1 FROM recordings WHERE id = ?", (recording_id,)
            ).fetchone()
        return row is not None

    def get_recording(self, recording_id: str) -> dict[str, Any]:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT r.*,
                       COUNT(c.chunk_index) AS chunk_count,
                       COALESCE(MAX(c.chunk_index), 0) AS last_chunk_index
                FROM recordings r
                LEFT JOIN chunks c ON c.recording_id = r.id
                WHERE r.id = ?
                GROUP BY r.id
                """,
                (recording_id,),
            ).fetchone()
        if row is None:
            raise KeyError(recording_id)
        return self._serialize_recording(row)

    def list_recordings(
        self, from_date: str | None, to_date: str | None, limit: int
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        parameters: list[Any] = []
        if from_date:
            clauses.append("r.created_at >= ?")
            parameters.append(from_date)
        if to_date:
            clauses.append("r.created_at <= ?")
            parameters.append(to_date)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        parameters.append(limit)
        with self._lock:
            rows = self._connection.execute(
                f"""
                SELECT r.*,
                       COUNT(c.chunk_index) AS chunk_count,
                       COALESCE(MAX(c.chunk_index), 0) AS last_chunk_index
                FROM recordings r
                LEFT JOIN chunks c ON c.recording_id = r.id
                {where}
                GROUP BY r.id
                ORDER BY r.created_at DESC
                LIMIT ?
                """,
                parameters,
            ).fetchall()
        return [self._serialize_recording(row) for row in rows]

    def insert_chunk(
        self,
        recording_id: str,
        chunk_index: int,
        started_at: str,
        duration: float,
        checksum: str,
        size: int,
        path: Path,
    ) -> tuple[dict[str, Any], bool]:
        with self._lock:
            existing = self._connection.execute(
                "SELECT * FROM chunks WHERE recording_id = ? AND chunk_index = ?",
                (recording_id, chunk_index),
            ).fetchone()
            if existing is not None:
                return dict(existing), False
            now = utc_now()
            self._connection.execute(
                """
                INSERT INTO chunks (
                    recording_id, chunk_index, started_at, duration,
                    checksum, size, path, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    recording_id,
                    chunk_index,
                    started_at,
                    duration,
                    checksum,
                    size,
                    str(path),
                    now,
                ),
            )
            self._connection.execute(
                """
                UPDATE recordings
                SET uploaded_bytes = uploaded_bytes + ?,
                    upload_status = 'UPLOADING',
                    updated_at = ?
                WHERE id = ?
                """,
                (size, now, recording_id),
            )
            self._connection.commit()
            row = self._connection.execute(
                "SELECT * FROM chunks WHERE recording_id = ? AND chunk_index = ?",
                (recording_id, chunk_index),
            ).fetchone()
            assert row is not None
            return dict(row), True

    def chunk(self, recording_id: str, chunk_index: int) -> dict[str, Any] | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM chunks WHERE recording_id = ? AND chunk_index = ?",
                (recording_id, chunk_index),
            ).fetchone()
        return dict(row) if row else None

    def chunks(self, recording_id: str) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT * FROM chunks WHERE recording_id = ? ORDER BY chunk_index",
                (recording_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    def set_lifecycle(self, recording_id: str, status: str) -> dict[str, Any]:
        now = utc_now()
        ended_at = now if status == "FINISHING" else None
        with self._lock:
            cursor = self._connection.execute(
                """
                UPDATE recordings
                SET status = ?, ended_at = COALESCE(?, ended_at), updated_at = ?
                WHERE id = ?
                """,
                (status, ended_at, now, recording_id),
            )
            self._connection.commit()
            if cursor.rowcount != 1:
                raise KeyError(recording_id)
        return self.get_recording(recording_id)

    def mark_completed(
        self, recording_id: str, duration: float, merged_path: Path
    ) -> dict[str, Any]:
        now = utc_now()
        with self._lock:
            self._connection.execute(
                """
                UPDATE recordings
                SET status = 'COMPLETED', upload_status = 'COMPLETED',
                    duration = ?, ended_at = COALESCE(ended_at, ?),
                    merged_path = ?, last_error = NULL, updated_at = ?
                WHERE id = ?
                """,
                (duration, now, str(merged_path), now, recording_id),
            )
            self._connection.commit()
        return self.get_recording(recording_id)

    def mark_failed(self, recording_id: str, error: str) -> None:
        with self._lock:
            self._connection.execute(
                """
                UPDATE recordings
                SET status = 'FAILED', upload_status = 'FAILED',
                    last_error = ?, updated_at = ?
                WHERE id = ?
                """,
                (error, utc_now(), recording_id),
            )
            self._connection.commit()

    def set_webhook_status(self, recording_id: str, status: str, error: str | None = None) -> None:
        with self._lock:
            self._connection.execute(
                """
                UPDATE recordings
                SET webhook_status = ?, last_error = COALESCE(?, last_error), updated_at = ?
                WHERE id = ?
                """,
                (status, error, utc_now(), recording_id),
            )
            self._connection.commit()

    @staticmethod
    def _serialize_recording(row: sqlite3.Row) -> dict[str, Any]:
        result = dict(row)
        result["metadata"] = json.loads(result.pop("metadata_json"))
        result["pending_chunks"] = 0
        result["audio_available"] = bool(result.get("merged_path"))
        result.pop("merged_path", None)
        result.pop("last_error", None) if result.get("last_error") is None else None
        return result
