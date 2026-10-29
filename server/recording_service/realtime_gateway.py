from __future__ import annotations

import asyncio
import base64
import binascii
import copy
import hmac
import secrets
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

from aiohttp import WSMsgType, web

from .mcp_server import McpServer
from .speaker_diarization import Voiceprint, known_voiceprints_from_payload


PROTOCOL_VERSION = 1
REALTIME_AUDIO_FORMAT = {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1}
MAX_ENROLLMENT_SECONDS = 25
ENROLLMENT_TIMEOUT_SECONDS = 60


@dataclass
class RealtimeSession:
    session_id: str
    recording_id: str
    token: str
    expires_at: datetime
    audio: dict[str, Any]
    language: str | None
    speaker_diarization: bool = False
    # Saved voices, held in memory only until the processor completes the session.
    known_voiceprints: list[dict[str, Any]] = field(default_factory=list)
    app_socket: web.WebSocketResponse | None = None
    processor_id: str | None = None
    revision: int = 0
    events: list[dict[str, Any]] = field(default_factory=list)
    finished: bool = False


@dataclass
class ProcessorConnection:
    processor_id: str
    socket: web.WebSocketResponse
    capabilities: dict[str, Any]


class RealtimeGateway:
    """Versioned, processor-neutral realtime routing for WakeOnCue clients."""

    def __init__(
        self,
        api_token: str,
        public_base_url: str | None = None,
        mcp: McpServer | None = None,
    ) -> None:
        self.api_token = api_token
        self.public_base_url = public_base_url
        self.mcp = mcp
        self.sessions: dict[str, RealtimeSession] = {}
        self.processors: dict[str, ProcessorConnection] = {}
        self.pending_enrollments: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._lock = asyncio.Lock()

    def application(self) -> web.Application:
        app = web.Application(client_max_size=2 * 1024 * 1024)
        app.router.add_get("/health", self.health)
        app.router.add_post("/v1/realtime/validate", self.validate_configuration)
        app.router.add_post("/v1/realtime/sessions", self.create_session)
        app.router.add_post("/v1/voiceprints/enroll", self.enroll_voiceprint)
        app.router.add_get("/v1/realtime/sessions/{session_id}/stream", self.app_stream)
        app.router.add_get("/v1/processors/connect", self.processor_stream)
        if self.mcp is not None:
            self.mcp.register(app)
        return app

    async def health(self, request: web.Request) -> web.Response:
        return web.json_response(
            {
                "status": "ok",
                "protocol_version": PROTOCOL_VERSION,
                "processors_available": len(self.processors),
            }
        )

    async def validate_configuration(self, request: web.Request) -> web.Response:
        self._authorize(request)
        return web.json_response(
            {
                "status": "ok",
                "protocol_version": PROTOCOL_VERSION,
                "processors_available": len(self.processors),
            }
        )

    async def create_session(self, request: web.Request) -> web.Response:
        self._authorize(request)
        payload = await request.json()
        if payload.get("protocol_version") != PROTOCOL_VERSION:
            raise web.HTTPUnprocessableEntity(
                text="unsupported protocol_version", content_type="text/plain"
            )
        recording_id = str(payload.get("recording_id", "")).strip()
        audio = payload.get("audio")
        if not recording_id or not isinstance(audio, dict):
            raise web.HTTPBadRequest(text="recording_id and audio are required")
        if audio != REALTIME_AUDIO_FORMAT:
            raise web.HTTPUnprocessableEntity(text="unsupported audio format")
        known_voiceprints = payload.get("known_voiceprints") or []
        if known_voiceprints_from_payload(known_voiceprints) is None:
            raise web.HTTPUnprocessableEntity(text="invalid known_voiceprints")

        session_id = f"rts_{secrets.token_hex(12)}"
        token = secrets.token_urlsafe(32)
        expires_at = datetime.now(UTC) + timedelta(hours=8)
        session = RealtimeSession(
            session_id=session_id,
            recording_id=recording_id,
            token=token,
            expires_at=expires_at,
            audio=audio,
            language=payload.get("language"),
            speaker_diarization=payload.get("speaker_diarization") is True,
            known_voiceprints=known_voiceprints,
        )
        async with self._lock:
            self.sessions[session_id] = session

        public_base = self.public_base_url or f"{request.scheme}://{request.host}"
        websocket_base = public_base.replace("https://", "wss://", 1).replace(
            "http://", "ws://", 1
        )
        return web.json_response(
            {
                "protocol_version": PROTOCOL_VERSION,
                "session_id": session_id,
                "websocket_url": f"{websocket_base}/v1/realtime/sessions/{session_id}/stream",
                "session_token": token,
                "expires_at": expires_at.isoformat().replace("+00:00", "Z"),
            },
            status=201,
        )

    async def enroll_voiceprint(self, request: web.Request) -> web.Response:
        """Turns a short sample of the user's own voice into a voiceprint.

        Neither the Gateway nor the processor keeps the audio or the result;
        the caller is the only place the voiceprint is stored.
        """
        self._authorize(request)
        payload = await request.json()
        if payload.get("protocol_version") != PROTOCOL_VERSION:
            raise web.HTTPUnprocessableEntity(text="unsupported protocol_version")
        if payload.get("audio") != REALTIME_AUDIO_FORMAT:
            raise web.HTTPUnprocessableEntity(text="unsupported audio format")
        try:
            pcm = base64.b64decode(str(payload.get("audio_base64", "")), validate=True)
        except (binascii.Error, ValueError) as error:
            raise web.HTTPBadRequest(text="invalid audio_base64") from error
        max_bytes = REALTIME_AUDIO_FORMAT["sample_rate"] * 2 * MAX_ENROLLMENT_SECONDS
        if not pcm:
            raise web.HTTPBadRequest(text="enrollment audio is empty")
        if len(pcm) > max_bytes:
            raise web.HTTPRequestEntityTooLarge(
                max_size=max_bytes, actual_size=len(pcm), text="enrollment audio too long"
            )

        processor = next(
            (
                candidate
                for candidate in self.processors.values()
                if candidate.capabilities.get("voiceprint_model")
            ),
            None,
        )
        if processor is None:
            raise web.HTTPServiceUnavailable(text="no processor supports voiceprints")

        request_id = f"vpe_{secrets.token_hex(12)}"
        result: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self.pending_enrollments[request_id] = result
        try:
            await processor.socket.send_json(
                {
                    "protocol_version": PROTOCOL_VERSION,
                    "type": "voiceprint.enroll",
                    "request_id": request_id,
                    "audio": REALTIME_AUDIO_FORMAT,
                    "audio_base64": base64.b64encode(pcm).decode("ascii"),
                }
            )
            response = await asyncio.wait_for(result, ENROLLMENT_TIMEOUT_SECONDS)
        except TimeoutError as error:
            raise web.HTTPGatewayTimeout(text="voiceprint enrollment timed out") from error
        finally:
            self.pending_enrollments.pop(request_id, None)

        if response.get("type") != "voiceprint.enrolled":
            return web.json_response(
                {
                    "protocol_version": PROTOCOL_VERSION,
                    "error": str(response.get("reason") or "enrollment_failed"),
                },
                status=422,
            )
        voiceprint = Voiceprint.from_payload(response.get("voiceprint"))
        if voiceprint is None:
            raise web.HTTPBadGateway(text="processor returned an invalid voiceprint")
        return web.json_response(
            {
                "protocol_version": PROTOCOL_VERSION,
                "voiceprint": voiceprint.payload(),
                "speech_ms": int(response.get("speech_ms", 0)),
            }
        )

    async def app_stream(self, request: web.Request) -> web.WebSocketResponse:
        session = self.sessions.get(request.match_info["session_id"])
        authorization = request.headers.get("Authorization", "")
        supplied = (
            authorization.removeprefix("Bearer ")
            if authorization.startswith("Bearer ")
            else request.query.get("token", "")
        )
        if session is None or not hmac.compare_digest(supplied, session.token):
            raise web.HTTPUnauthorized()
        if session.expires_at < datetime.now(UTC):
            raise web.HTTPUnauthorized(text="session expired")

        socket = web.WebSocketResponse(heartbeat=20, max_msg_size=2 * 1024 * 1024)
        await socket.prepare(request)
        session.app_socket = socket
        await self._assign_processor(session)
        await socket.send_json(
            {
                "protocol_version": PROTOCOL_VERSION,
                "type": "session.ready",
                "status": "processing" if session.processor_id else "waiting_for_processor",
            }
        )
        try:
            async for message in socket:
                if message.type != WSMsgType.TEXT:
                    continue
                payload = message.json()
                event_type = payload.get("type")
                if event_type == "session.replay":
                    await self._replay(session, socket, int(payload.get("after_revision", 0)))
                    continue
                if event_type not in {"audio.append", "session.pause", "session.resume", "session.finish"}:
                    continue
                if event_type == "session.finish":
                    session.finished = True
                processor = self.processors.get(session.processor_id or "")
                if processor is None:
                    await self._assign_processor(session)
                    processor = self.processors.get(session.processor_id or "")
                if processor is not None:
                    routed = dict(payload)
                    routed["protocol_version"] = PROTOCOL_VERSION
                    routed["session_id"] = session.session_id
                    routed["recording_id"] = session.recording_id
                    await processor.socket.send_json(routed)
        finally:
            if session.app_socket is socket:
                session.app_socket = None
        return socket

    async def processor_stream(self, request: web.Request) -> web.WebSocketResponse:
        self._authorize(request)
        socket = web.WebSocketResponse(heartbeat=20, max_msg_size=2 * 1024 * 1024)
        await socket.prepare(request)
        processor_id: str | None = None
        try:
            first = await socket.receive(timeout=10)
            if first.type != WSMsgType.TEXT:
                await socket.close(code=1008, message=b"processor.register required")
                return socket
            registration = first.json()
            if registration.get("type") != "processor.register":
                await socket.close(code=1008, message=b"processor.register required")
                return socket
            processor_id = str(registration.get("processor_id", "")).strip()
            if not processor_id:
                await socket.close(code=1008, message=b"processor_id required")
                return socket
            self.processors[processor_id] = ProcessorConnection(
                processor_id=processor_id,
                socket=socket,
                capabilities=dict(registration.get("capabilities") or {}),
            )
            await socket.send_json(
                {"protocol_version": PROTOCOL_VERSION, "type": "processor.registered"}
            )
            for session in self.sessions.values():
                if session.processor_id is None:
                    await self._assign_processor(session)

            async for message in socket:
                if message.type != WSMsgType.TEXT:
                    continue
                payload = message.json()
                if payload.get("type") in {"voiceprint.enrolled", "voiceprint.failed"}:
                    pending = self.pending_enrollments.get(str(payload.get("request_id", "")))
                    if pending is not None and not pending.done():
                        pending.set_result(payload)
                    continue
                session = self.sessions.get(str(payload.get("session_id", "")))
                if session is None:
                    continue
                await self._publish_processor_event(session, payload)
        finally:
            if processor_id and self.processors.get(processor_id, None) is not None:
                current = self.processors.get(processor_id)
                if current and current.socket is socket:
                    self.processors.pop(processor_id, None)
                    for session in self.sessions.values():
                        if session.processor_id == processor_id:
                            session.processor_id = None
                            await self._send_app_status(session, "waiting_for_processor")
        return socket

    async def _assign_processor(self, session: RealtimeSession) -> None:
        if session.processor_id in self.processors:
            return
        processor = next(iter(self.processors.values()), None)
        if processor is None:
            session.processor_id = None
            return
        session.processor_id = processor.processor_id
        started: dict[str, Any] = {
            "protocol_version": PROTOCOL_VERSION,
            "type": "session.started",
            "session_id": session.session_id,
            "recording_id": session.recording_id,
            "language": session.language,
            "audio": session.audio,
        }
        if session.speaker_diarization:
            started["speaker_diarization"] = True
            started["known_voiceprints"] = session.known_voiceprints
        await processor.socket.send_json(started)
        if session.finished:
            await processor.socket.send_json(
                {
                    "protocol_version": PROTOCOL_VERSION,
                    "type": "session.finish",
                    "session_id": session.session_id,
                    "recording_id": session.recording_id,
                }
            )
        await self._send_app_status(session, "processing")

    async def _publish_processor_event(
        self, session: RealtimeSession, payload: dict[str, Any]
    ) -> None:
        event_type = payload.get("type")
        if event_type == "session.completed":
            session.known_voiceprints = []
        outgoing = copy.deepcopy(payload)
        outgoing.pop("session_id", None)
        outgoing["protocol_version"] = PROTOCOL_VERSION
        outgoing["recording_id"] = session.recording_id
        if event_type in {"transcript.upsert", "speaker.corrected"}:
            session.revision += 1
            outgoing["revision"] = session.revision
            session.events.append(outgoing)
            session.events = session.events[-500:]
        if session.app_socket is not None and not session.app_socket.closed:
            await session.app_socket.send_json(outgoing)

    async def _replay(
        self, session: RealtimeSession, socket: web.WebSocketResponse, after_revision: int
    ) -> None:
        for event in session.events:
            if int(event.get("revision", 0)) > after_revision:
                await socket.send_json(event)

    async def _send_app_status(self, session: RealtimeSession, status: str) -> None:
        if session.app_socket is not None and not session.app_socket.closed:
            await session.app_socket.send_json(
                {
                    "protocol_version": PROTOCOL_VERSION,
                    "type": "processor.status",
                    "status": status,
                }
            )

    def _authorize(self, request: web.Request) -> None:
        supplied = request.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, f"Bearer {self.api_token}"):
            raise web.HTTPUnauthorized(text="valid Bearer token required")


def create_realtime_application(
    api_token: str,
    public_base_url: str | None = None,
    mcp: McpServer | None = None,
) -> web.Application:
    return RealtimeGateway(api_token, public_base_url, mcp).application()
