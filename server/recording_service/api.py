from __future__ import annotations

import hmac
import json
import os
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from .database import RecordingDatabase
from .service import RecordingService, ServiceError
from .storage import (
    ConfigurableRecordingStorage,
    LocalRecordingStorage,
    StorageConfigurationError,
    StorageConfigurationManager,
)


RECORDING_ROUTE = re.compile(r"^/v1/recordings/(rec_[A-Za-z0-9_-]+)$")
ACTION_ROUTE = re.compile(r"^/v1/recordings/(rec_[A-Za-z0-9_-]+)/(pause|resume|finish)$")
CHUNK_ROUTE = re.compile(r"^/v1/recordings/(rec_[A-Za-z0-9_-]+)/chunks/([0-9]+)$")
AUDIO_ROUTE = re.compile(r"^/v1/recordings/(rec_[A-Za-z0-9_-]+)/audio$")


class RecordingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        server_address: tuple[str, int],
        service: RecordingService,
        api_token: str,
        storage_configuration: StorageConfigurationManager,
    ) -> None:
        self.service = service
        self.api_token = api_token
        self.storage_configuration = storage_configuration
        super().__init__(server_address, RecordingRequestHandler)
        if not service.public_base_url:
            host, port = self.server_address[:2]
            advertised_host = "127.0.0.1" if host in ("", "0.0.0.0") else host
            service.public_base_url = f"http://{advertised_host}:{port}"


class RecordingRequestHandler(BaseHTTPRequestHandler):
    server: RecordingHTTPServer
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        try:
            path = urlparse(self.path)
            if path.path == "/health":
                self._json(200, {"status": "ok"})
                return
            self._authorize()
            if path.path == "/v1/recordings":
                query = parse_qs(path.query)
                limit = int(query.get("limit", ["100"])[0])
                recordings = self.server.service.list_recordings(
                    query.get("from", [None])[0], query.get("to", [None])[0], limit
                )
                self._json(200, {"recordings": recordings})
                return
            if path.path == "/v1/storage/config":
                self._json(200, self.server.storage_configuration.public_configuration())
                return
            if match := RECORDING_ROUTE.fullmatch(path.path):
                self._json(200, self.server.service.get_recording(match.group(1)))
                return
            if match := AUDIO_ROUTE.fullmatch(path.path):
                self._send_audio(match.group(1))
                return
            raise ServiceError(404, "not_found", path.path)
        except Exception as error:
            self._handle_error(error)

    def do_POST(self) -> None:
        try:
            self._authorize()
            path = urlparse(self.path).path
            if path == "/v1/recordings":
                payload = self._read_json(maximum=128 * 1024)
                recording, created = self.server.service.create_recording(payload)
                self._json(201 if created else 200, recording)
                return
            if match := ACTION_ROUTE.fullmatch(path):
                recording_id, action = match.groups()
                if action == "finish":
                    self._json(200, self.server.service.finish(recording_id))
                else:
                    self._json(200, self.server.service.transition(recording_id, action))
                return
            raise ServiceError(404, "not_found", path)
        except Exception as error:
            self._handle_error(error)

    def do_PUT(self) -> None:
        try:
            self._authorize()
            path = urlparse(self.path).path
            if path == "/v1/storage/config":
                payload = self._read_json(maximum=128 * 1024)
                self._json(200, self.server.storage_configuration.update(payload))
                return
            match = CHUNK_ROUTE.fullmatch(path)
            if not match:
                raise ServiceError(404, "not_found", path)
            content_length = self._content_length(maximum=32 * 1024 * 1024)
            headers = {key.lower(): value for key, value in self.headers.items()}
            ack = self.server.service.upload_chunk(
                match.group(1), int(match.group(2)), headers, self.rfile, content_length
            )
            self._json(200, ack)
        except Exception as error:
            self._handle_error(error)

    def log_message(self, format: str, *args: Any) -> None:
        if os.environ.get("WAKEONCUE_HTTP_LOG") == "1":
            super().log_message(format, *args)

    def _authorize(self) -> None:
        expected = f"Bearer {self.server.api_token}"
        supplied = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, expected):
            raise ServiceError(401, "unauthorized", "a valid Bearer API token is required")

    def _read_json(self, maximum: int) -> dict[str, Any]:
        length = self._content_length(maximum)
        try:
            payload = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ServiceError(400, "invalid_json", str(error)) from error
        if not isinstance(payload, dict):
            raise ServiceError(400, "invalid_json", "request body must be an object")
        return payload

    def _content_length(self, maximum: int) -> int:
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError as error:
            raise ServiceError(411, "content_length_required", "invalid Content-Length") from error
        if length < 0 or length > maximum:
            raise ServiceError(413, "payload_too_large", f"maximum payload is {maximum} bytes")
        return length

    def _send_audio(self, recording_id: str) -> None:
        try:
            path, size = self.server.service.storage.open_audio(recording_id)
        except FileNotFoundError as error:
            raise ServiceError(404, "audio_not_ready", recording_id) from error
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "audio/mp4")
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Disposition", f'attachment; filename="{recording_id}.m4a"')
        self.end_headers()
        with path.open("rb") as handle:
            while block := handle.read(1024 * 1024):
                self.wfile.write(block)

    def _json(self, status: int, payload: Any) -> None:
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle_error(self, error: Exception) -> None:
        if isinstance(error, ServiceError):
            payload: dict[str, Any] = {"error": error.code, "message": error.message}
            if error.details is not None:
                payload["details"] = error.details
            self._json(error.status, payload)
            return
        if isinstance(error, ValueError):
            status = 422 if isinstance(error, StorageConfigurationError) else 400
            code = "storage_configuration_invalid" if status == 422 else "bad_request"
            self._json(status, {"error": code, "message": str(error)})
            return
        self._json(500, {"error": "internal_error", "message": str(error)})


def create_server(
    host: str,
    port: int,
    data_directory: Path,
    api_token: str,
    webhook_url: str | None = None,
    webhook_secret: str | None = None,
    public_base_url: str | None = None,
    ffmpeg_binary: str = "ffmpeg",
    s3_client_factory: Any | None = None,
) -> RecordingHTTPServer:
    database = RecordingDatabase(data_directory / "recordings.sqlite")
    configuration = StorageConfigurationManager(
        data_directory / "storage-config.json", s3_client_factory
    )
    storage = ConfigurableRecordingStorage(
        LocalRecordingStorage(data_directory / "storage", ffmpeg_binary), configuration
    )
    service = RecordingService(database, storage, webhook_url, webhook_secret, public_base_url)
    return RecordingHTTPServer((host, port), service, api_token, configuration)
