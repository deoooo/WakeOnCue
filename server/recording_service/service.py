from __future__ import annotations

import hashlib
import hmac
import json
import math
import threading
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

from .database import RecordingDatabase, utc_now
from .storage import ChecksumMismatch, ConfigurableRecordingStorage, MergeError


@dataclass(slots=True)
class ServiceError(Exception):
    status: int
    code: str
    message: str
    details: Any = None


class RecordingService:
    def __init__(
        self,
        database: RecordingDatabase,
        storage: ConfigurableRecordingStorage,
        webhook_url: str | None = None,
        webhook_secret: str | None = None,
        public_base_url: str | None = None,
    ) -> None:
        self.database = database
        self.storage = storage
        self.webhook_url = webhook_url
        self.webhook_secret = webhook_secret
        self.public_base_url = public_base_url
        self._recording_locks = [threading.RLock() for _ in range(64)]

    def create_recording(self, payload: dict[str, Any]) -> tuple[dict[str, Any], bool]:
        recording_id = payload.get("id")
        if not isinstance(recording_id, str) or not recording_id.startswith("rec_"):
            raise ServiceError(400, "invalid_recording_id", "id must start with rec_")
        metadata = payload.get("metadata", {})
        if not isinstance(metadata, dict):
            raise ServiceError(400, "invalid_metadata", "metadata must be an object")
        return self.database.create_recording(payload)

    def upload_chunk(
        self,
        recording_id: str,
        chunk_index: int,
        headers: dict[str, str],
        source: BinaryIO,
        content_length: int,
    ) -> dict[str, Any]:
        if chunk_index <= 0:
            raise ServiceError(400, "invalid_chunk_index", "chunk_index must be greater than zero")
        if content_length <= 0:
            raise ServiceError(400, "invalid_chunk_size", "chunk body must not be empty")
        checksum = headers.get("x-chunk-checksum", "").lower()
        if len(checksum) != 64 or any(character not in "0123456789abcdef" for character in checksum):
            raise ServiceError(400, "invalid_checksum", "X-Chunk-Checksum must be a SHA-256 hex digest")
        started_at = headers.get("x-chunk-started-at")
        duration_value = headers.get("x-chunk-duration")
        if not started_at or duration_value is None:
            raise ServiceError(400, "missing_chunk_metadata", "chunk start and duration headers are required")
        try:
            duration = float(duration_value)
        except ValueError as error:
            raise ServiceError(400, "invalid_duration", "X-Chunk-Duration must be numeric") from error
        if not math.isfinite(duration) or duration <= 0:
            raise ServiceError(
                400, "invalid_duration", "X-Chunk-Duration must be a positive finite number"
            )

        with self._recording_lock(recording_id):
            if not self.database.recording_exists(recording_id):
                self._drain(source, content_length)
                raise ServiceError(
                    404, "recording_not_found", "create the recording before uploading"
                )
            existing = self.database.chunk(recording_id, chunk_index)
            if existing is not None:
                if existing["checksum"] != checksum or existing["size"] != content_length:
                    self._drain(source, content_length)
                    raise ServiceError(
                        409,
                        "idempotency_conflict",
                        "recording_id and chunk_index already exist with different content",
                    )
                existing_path = Path(existing["path"])
                is_durable = self.storage.is_chunk_durable(
                    recording_id,
                    chunk_index,
                    existing_path,
                    checksum,
                    content_length,
                )
                if is_durable:
                    self._drain(source, content_length)
                else:
                    try:
                        self.storage.write_chunk(
                            recording_id, chunk_index, source, checksum, content_length
                        )
                    except ChecksumMismatch as error:
                        raise ServiceError(422, "checksum_mismatch", str(error)) from error
                return self._chunk_ack(recording_id, existing, duplicate=True)
            recording = self.database.get_recording(recording_id)
            if recording["status"] == "COMPLETED":
                self._drain(source, content_length)
                raise ServiceError(
                    409,
                    "recording_completed",
                    "a completed recording cannot accept a new chunk",
                )
            try:
                path, size = self.storage.write_chunk(
                    recording_id, chunk_index, source, checksum, content_length
                )
            except ChecksumMismatch as error:
                raise ServiceError(422, "checksum_mismatch", str(error)) from error
            chunk, created = self.database.insert_chunk(
                recording_id, chunk_index, started_at, duration, checksum, size, path
            )
            return self._chunk_ack(recording_id, chunk, duplicate=not created)

    def transition(self, recording_id: str, action: str) -> dict[str, Any]:
        statuses = {"pause": "PAUSED", "resume": "RECORDING"}
        allowed_from = {"pause": "RECORDING", "resume": "PAUSED"}
        with self._recording_lock(recording_id):
            try:
                current = self.database.get_recording(recording_id)
            except KeyError as error:
                raise ServiceError(404, "recording_not_found", recording_id) from error
            target = statuses[action]
            if current["status"] == target:
                return current
            if current["status"] != allowed_from[action]:
                raise ServiceError(
                    409,
                    "invalid_recording_transition",
                    f"cannot {action} a recording in {current['status']} state",
                )
            return self.database.set_lifecycle(recording_id, target)

    def finish(self, recording_id: str) -> dict[str, Any]:
        with self._recording_lock(recording_id):
            return self._finish_locked(recording_id)

    def _finish_locked(self, recording_id: str) -> dict[str, Any]:
        try:
            current = self.database.get_recording(recording_id)
        except KeyError as error:
            raise ServiceError(404, "recording_not_found", recording_id) from error
        if current["status"] == "COMPLETED":
            return current
        if current["status"] not in {"RECORDING", "PAUSED", "FINISHING", "FAILED"}:
            raise ServiceError(
                409,
                "invalid_recording_transition",
                f"cannot finish a recording in {current['status']} state",
            )
        self.database.set_lifecycle(recording_id, "FINISHING")
        chunks = self.database.chunks(recording_id)
        if not chunks:
            raise ServiceError(409, "no_chunks", "recording has no uploaded chunks")
        expected = list(range(1, int(chunks[-1]["chunk_index"]) + 1))
        actual = [int(chunk["chunk_index"]) for chunk in chunks]
        missing = sorted(set(expected) - set(actual))
        if missing:
            raise ServiceError(409, "missing_chunks", "recording has a chunk gap", missing)
        try:
            merged_path = self.storage.merge_chunks(recording_id, chunks)
        except MergeError as error:
            self.database.mark_failed(recording_id, str(error))
            raise ServiceError(422, "merge_failed", str(error)) from error
        duration = sum(float(chunk["duration"]) for chunk in chunks)
        recording = self.database.mark_completed(recording_id, duration, merged_path)
        self._deliver_finished_webhook(recording)
        return self.database.get_recording(recording_id)

    def _recording_lock(self, recording_id: str) -> threading.RLock:
        return self._recording_locks[hash(recording_id) % len(self._recording_locks)]

    def get_recording(self, recording_id: str) -> dict[str, Any]:
        try:
            return self.database.get_recording(recording_id)
        except KeyError as error:
            raise ServiceError(404, "recording_not_found", recording_id) from error

    def list_recordings(
        self, from_date: str | None, to_date: str | None, limit: int
    ) -> list[dict[str, Any]]:
        return self.database.list_recordings(from_date, to_date, max(1, min(limit, 500)))

    def _deliver_finished_webhook(self, recording: dict[str, Any]) -> None:
        if not self.webhook_url:
            self.database.set_webhook_status(recording["id"], "not_configured")
            return
        audio_url = f"{self.public_base_url}/v1/recordings/{recording['id']}/audio"
        payload = json.dumps(
            {
                "event": "recording.finished",
                "recording_id": recording["id"],
                "audio_url": audio_url,
                "metadata": recording["metadata"],
                "occurred_at": utc_now(),
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        timestamp = utc_now()
        signature = ""
        if self.webhook_secret:
            signature = hmac.new(
                self.webhook_secret.encode("utf-8"), timestamp.encode("utf-8") + b"." + payload, hashlib.sha256
            ).hexdigest()
        request = urllib.request.Request(
            self.webhook_url,
            data=payload,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-WakeOnCue-Timestamp": timestamp,
                "X-WakeOnCue-Signature": f"sha256={signature}",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                if not 200 <= response.status < 300:
                    raise OSError(f"webhook returned {response.status}")
            self.database.set_webhook_status(recording["id"], "delivered")
        except Exception as error:  # Webhook failure must not invalidate the audio.
            self.database.set_webhook_status(recording["id"], "failed", str(error))

    @staticmethod
    def _drain(source: BinaryIO, content_length: int) -> None:
        remaining = content_length
        while remaining:
            block = source.read(min(1024 * 1024, remaining))
            if not block:
                break
            remaining -= len(block)

    @staticmethod
    def _chunk_ack(recording_id: str, chunk: dict[str, Any], duplicate: bool) -> dict[str, Any]:
        return {
            "ack": True,
            "recording_id": recording_id,
            "chunk_index": int(chunk["chunk_index"]),
            "checksum": chunk["checksum"],
            "size": int(chunk["size"]),
            "duplicate": duplicate,
        }
