"""Read-only MCP server over the recordings the iPhone uploads to the user's S3 bucket.

Implements the Streamable HTTP transport of MCP 2025-06-18 with plain JSON responses.
It only reads `metadata.json`, `transcript.json` and `summary.json`; it never reads audio,
never writes to the bucket and never returns voiceprints or saved person names, which
stay on the iPhone.
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import re
import threading
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any, Callable, Protocol
from urllib.parse import urlsplit

from aiohttp import web


LATEST_PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26")
SERVER_NAME = "wakeoncue"
SERVER_VERSION = "0.1.0"
MAX_REQUEST_BYTES = 256 * 1024
DEFAULT_SEARCH_LIMIT = 10
MAX_SEARCH_LIMIT = 50
DEFAULT_LIST_LIMIT = 20
MAX_LIST_LIMIT = 200
RECORDING_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602


class ArchiveError(RuntimeError):
    pass


class RecordingArchive(Protocol):
    def recording_ids(self) -> list[str]: ...

    def object_versions(self, recording_id: str) -> dict[str, str]:
        """Maps file names directly under the recording folder to a version tag (ETag)."""
        ...

    def read_json(self, recording_id: str, name: str) -> Any: ...


class S3RecordingArchive:
    """Reads the iPhone's S3 layout: `<prefix>/recordings/<id>/{metadata,transcript,summary}.json`."""

    FILES = ("metadata.json", "transcript.json", "summary.json")

    def __init__(self, client: Any, bucket: str, prefix: str = "wakeoncue") -> None:
        self.client = client
        self.bucket = bucket
        self.prefix = prefix.strip().strip("/")

    def _key(self, suffix: str) -> str:
        return "/".join(part for part in (self.prefix, suffix) if part)

    def recording_ids(self) -> list[str]:
        root = self._key("recordings") + "/"
        ids: list[str] = []
        token: str | None = None
        while True:
            options: dict[str, Any] = {"Bucket": self.bucket, "Prefix": root, "Delimiter": "/"}
            if token:
                options["ContinuationToken"] = token
            response = self.client.list_objects_v2(**options)
            for common in response.get("CommonPrefixes", []):
                recording_id = str(common.get("Prefix", ""))[len(root):].rstrip("/")
                if RECORDING_ID_PATTERN.match(recording_id):
                    ids.append(recording_id)
            if not response.get("IsTruncated"):
                return ids
            token = response.get("NextContinuationToken")

    def object_versions(self, recording_id: str) -> dict[str, str]:
        folder = self._key(f"recordings/{recording_id}") + "/"
        response = self.client.list_objects_v2(Bucket=self.bucket, Prefix=folder, Delimiter="/")
        versions: dict[str, str] = {}
        for item in response.get("Contents", []):
            name = str(item.get("Key", ""))[len(folder):]
            if name in self.FILES:
                versions[name] = str(item.get("ETag") or item.get("LastModified") or "")
        return versions

    def read_json(self, recording_id: str, name: str) -> Any:
        if name not in self.FILES:
            raise ArchiveError(f"{name} is not readable")
        response = self.client.get_object(
            Bucket=self.bucket, Key=self._key(f"recordings/{recording_id}/{name}")
        )
        body = response["Body"]
        try:
            return json.loads(body.read())
        finally:
            close = getattr(body, "close", None)
            if close:
                close()


@dataclass(frozen=True, slots=True)
class Segment:
    segment_id: str
    start_ms: int
    end_ms: int
    text: str
    speaker: str | None

    def payload(self) -> dict[str, Any]:
        return {
            "segment_id": self.segment_id,
            "start_ms": self.start_ms,
            "end_ms": self.end_ms,
            "timestamp": format_timestamp(self.start_ms),
            "speaker": self.speaker,
            "text": self.text,
        }


@dataclass(slots=True)
class Recording:
    recording_id: str
    started_at: datetime | None = None
    title: str | None = None
    summary: dict[str, Any] | None = None
    segments: list[Segment] = field(default_factory=list)
    versions: dict[str, str] = field(default_factory=dict)

    @property
    def display_title(self) -> str | None:
        return self.title or (self.summary or {}).get("title") or None

    def overview(self) -> dict[str, Any]:
        return {
            "recording_id": self.recording_id,
            "title": self.display_title,
            "started_at": iso(self.started_at),
            "duration_ms": max((segment.end_ms for segment in self.segments), default=0),
            "segment_count": len(self.segments),
            "has_summary": self.summary is not None,
        }


def format_timestamp(milliseconds: int) -> str:
    seconds = max(0, milliseconds) // 1000
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes:02d}:{seconds:02d}"


def iso(value: datetime | None) -> str | None:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z") if value else None


def parse_datetime(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def parse_segments(payload: Any) -> list[Segment]:
    """Keeps only the newest revision of each segment and only whitelisted fields."""
    if not isinstance(payload, list):
        return []
    newest: dict[str, tuple[int, Segment]] = {}
    for item in payload:
        if not isinstance(item, dict):
            continue
        text = item.get("text")
        segment_id = item.get("segment_id")
        if not isinstance(text, str) or not text.strip() or not isinstance(segment_id, str):
            continue
        try:
            start = int(item.get("start_ms", 0))
            end = int(item.get("end_ms", start))
            revision = int(item.get("revision", 0))
        except (TypeError, ValueError):
            continue
        speaker = item.get("speaker")
        label = None
        if isinstance(speaker, dict) and isinstance(speaker.get("display_name"), str):
            label = speaker["display_name"].strip() or None
        segment = Segment(segment_id, max(0, start), max(start, end), text.strip(), label)
        current = newest.get(segment_id)
        if current is None or revision >= current[0]:
            newest[segment_id] = (revision, segment)
    return sorted((segment for _, segment in newest.values()), key=lambda s: (s.start_ms, s.segment_id))


def parse_summary(payload: Any) -> dict[str, Any] | None:
    if not isinstance(payload, dict):
        return None

    def strings(value: Any) -> list[str]:
        return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []

    title = payload.get("title")
    overview = payload.get("overview")
    return {
        "title": title if isinstance(title, str) else None,
        "overview": overview if isinstance(overview, str) else None,
        "key_points": strings(payload.get("keyPoints", payload.get("key_points"))),
        "action_items": strings(payload.get("actionItems", payload.get("action_items"))),
    }


class RecordingIndex:
    """In-memory view of the archive that re-reads a file only when its ETag changes."""

    def __init__(
        self,
        archive: RecordingArchive,
        refresh_seconds: float = 30,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.archive = archive
        self.refresh_seconds = refresh_seconds
        self.clock = clock
        self._recordings: dict[str, Recording] = {}
        self._refreshed_at: float | None = None
        self._lock = threading.Lock()

    def recordings(self) -> list[Recording]:
        with self._lock:
            now = self.clock()
            if self._refreshed_at is None or now - self._refreshed_at >= self.refresh_seconds:
                self._refresh()
                self._refreshed_at = now
            return sorted(
                self._recordings.values(),
                key=lambda r: (r.started_at or datetime.min.replace(tzinfo=UTC), r.recording_id),
                reverse=True,
            )

    def recording(self, recording_id: str) -> Recording | None:
        return next((r for r in self.recordings() if r.recording_id == recording_id), None)

    def _refresh(self) -> None:
        try:
            ids = self.archive.recording_ids()
        except Exception as error:
            raise ArchiveError(f"could not list recordings: {error}") from error
        updated: dict[str, Recording] = {}
        for recording_id in ids:
            previous = self._recordings.get(recording_id)
            try:
                versions = self.archive.object_versions(recording_id)
            except Exception:
                if previous:
                    updated[recording_id] = previous
                continue
            if "metadata.json" not in versions and "transcript.json" not in versions:
                continue
            recording = previous or Recording(recording_id)
            if previous is None or previous.versions != versions:
                recording = self._load(recording_id, versions, previous)
            updated[recording_id] = recording
        self._recordings = updated

    def _load(
        self, recording_id: str, versions: dict[str, str], previous: Recording | None
    ) -> Recording:
        recording = Recording(recording_id, versions=dict(versions))
        old = previous.versions if previous else {}

        def changed(name: str) -> bool:
            return name in versions and (previous is None or old.get(name) != versions[name])

        if changed("metadata.json"):
            metadata = self._read(recording_id, "metadata.json")
            if isinstance(metadata, dict):
                recording.started_at = parse_datetime(metadata.get("started_at")) or parse_datetime(
                    metadata.get("created_at")
                )
                extra = metadata.get("metadata")
                title = extra.get("title") if isinstance(extra, dict) else None
                recording.title = title.strip() if isinstance(title, str) and title.strip() else None
        elif previous and "metadata.json" in versions:
            recording.started_at, recording.title = previous.started_at, previous.title
        if changed("transcript.json"):
            recording.segments = parse_segments(self._read(recording_id, "transcript.json"))
        elif previous and "transcript.json" in versions:
            recording.segments = previous.segments
        if changed("summary.json"):
            recording.summary = parse_summary(self._read(recording_id, "summary.json"))
        elif previous and "summary.json" in versions:
            recording.summary = previous.summary
        return recording

    def _read(self, recording_id: str, name: str) -> Any:
        try:
            return self.archive.read_json(recording_id, name)
        except Exception:
            return None


_CJK_RUN = re.compile(r"[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]+")
_WORD = re.compile(r"[^\W_]+(?:'[^\W_]+)?")
_STOP_WORDS = frozenset(
    "a an and are about at be by did do does for from had has have how i in is it me my of on "
    "or our say said that the their them they this to was we were what when where which who "
    "why will with you your".split()
)
_CJK_STOP_GRAMS = frozenset(
    "我们 你们 他们 什么 关于 一下 这个 那个 怎么 是不 不是 有没 没有 了什 的是 是什 吗 呢 了 的 是".split()
)


def query_terms(query: str) -> list[str]:
    """Words for alphabetic scripts; overlapping character pairs for CJK, which has no spaces."""
    lowered = query.casefold()
    terms: list[str] = []
    for run in _CJK_RUN.findall(lowered):
        grams = [run] if len(run) == 1 else [run[i : i + 2] for i in range(len(run) - 1)]
        terms.extend(gram for gram in grams if gram not in _CJK_STOP_GRAMS)
    for word in _WORD.findall(_CJK_RUN.sub(" ", lowered)):
        if word not in _STOP_WORDS and (len(word) > 1 or word.isdigit()):
            terms.append(word)
    return list(dict.fromkeys(terms))


def search(recordings: list[Recording], query: str, limit: int) -> list[dict[str, Any]]:
    terms = query_terms(query)
    phrase = query.strip().casefold()
    if not terms and not phrase:
        return []
    hits: list[tuple[float, Recording, Segment]] = []
    for recording in recordings:
        title = (recording.display_title or "").casefold()
        title_bonus = 0.5 if any(term in title for term in terms) else 0.0
        for segment in recording.segments:
            text = segment.text.casefold()
            matched = [term for term in terms if term in text]
            if not matched and phrase not in text:
                continue
            coverage = len(matched) / len(terms) if terms else 1.0
            score = coverage * 2 + sum(text.count(term) for term in matched) * 0.1 + title_bonus
            if phrase and phrase in text:
                score += 2
            hits.append((score, recording, segment))
    hits.sort(key=lambda hit: (-hit[0], hit[1].recording_id, hit[2].start_ms))
    return [
        {
            "recording_id": recording.recording_id,
            "recording_title": recording.display_title,
            "recording_started_at": iso(recording.started_at),
            **segment.payload(),
            "score": round(score, 3),
        }
        for score, recording, segment in hits[:limit]
    ]


class ToolError(ValueError):
    pass


def _limit(arguments: dict[str, Any], default: int, maximum: int) -> int:
    value = arguments.get("limit", default)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ToolError("limit must be a number")
    return max(1, min(maximum, int(value)))


TOOLS: list[dict[str, Any]] = [
    {
        "name": "search_transcripts",
        "title": "Search recordings",
        "description": (
            "Search the transcripts of the user's WakeOnCue recordings. Returns matching "
            "segments with recording_id, timestamp and speaker label so answers can cite "
            "their sources. Answer only from the returned text."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Words or a question to look for."},
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_SEARCH_LIMIT,
                    "default": DEFAULT_SEARCH_LIMIT,
                },
            },
            "required": ["query"],
        },
        "annotations": {"readOnlyHint": True, "openWorldHint": False},
    },
    {
        "name": "get_recording",
        "title": "Get a recording",
        "description": "Full transcript with timestamps plus the on-device summary, if any.",
        "inputSchema": {
            "type": "object",
            "properties": {"recording_id": {"type": "string"}},
            "required": ["recording_id"],
        },
        "annotations": {"readOnlyHint": True, "openWorldHint": False},
    },
    {
        "name": "list_recordings",
        "title": "List recordings",
        "description": "Recordings newest first, optionally only those started at or after `since`.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "since": {
                    "type": "string",
                    "description": "ISO 8601 date or date-time, for example 2026-10-01.",
                },
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_LIST_LIMIT,
                    "default": DEFAULT_LIST_LIMIT,
                },
            },
        },
        "annotations": {"readOnlyHint": True, "openWorldHint": False},
    },
]


class RecordingTools:
    def __init__(self, index: RecordingIndex) -> None:
        self.index = index

    def call(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "search_transcripts":
            query = arguments.get("query")
            if not isinstance(query, str) or not query.strip():
                raise ToolError("query is required")
            limit = _limit(arguments, DEFAULT_SEARCH_LIMIT, MAX_SEARCH_LIMIT)
            citations = search(self.index.recordings(), query, limit)
            return {"query": query, "citations": citations, "found": bool(citations)}
        if name == "get_recording":
            recording_id = arguments.get("recording_id")
            if not isinstance(recording_id, str) or not RECORDING_ID_PATTERN.match(recording_id):
                raise ToolError("recording_id is invalid")
            recording = self.index.recording(recording_id)
            if recording is None:
                raise ToolError(f"recording {recording_id} was not found")
            return {
                **recording.overview(),
                "summary": recording.summary,
                "segments": [segment.payload() for segment in recording.segments],
            }
        if name == "list_recordings":
            limit = _limit(arguments, DEFAULT_LIST_LIMIT, MAX_LIST_LIMIT)
            since_value = arguments.get("since")
            since = parse_datetime(since_value)
            if since_value not in (None, "") and since is None:
                raise ToolError("since must be an ISO 8601 date or date-time")
            recordings = [
                r for r in self.index.recordings()
                if since is None or (r.started_at is not None and r.started_at >= since)
            ]
            return {"recordings": [r.overview() for r in recordings[:limit]]}
        raise KeyError(name)


class McpServer:
    """Stateless Streamable HTTP endpoint; every request carries the bearer token."""

    def __init__(
        self,
        tools: RecordingTools,
        api_token: str,
        allowed_origins: tuple[str, ...] = (),
    ) -> None:
        self.tools = tools
        self.api_token = api_token
        self.allowed_origins = allowed_origins

    def register(self, app: web.Application, path: str = "/mcp") -> None:
        app.router.add_post(path, self.handle_post)
        app.router.add_get(path, self.handle_unsupported)
        app.router.add_delete(path, self.handle_unsupported)

    async def handle_unsupported(self, request: web.Request) -> web.Response:
        self._check_request(request)
        return web.Response(status=405, headers={"Allow": "POST"})

    async def handle_post(self, request: web.Request) -> web.Response:
        self._check_request(request)
        version = request.headers.get("MCP-Protocol-Version")
        if version and version not in SUPPORTED_PROTOCOL_VERSIONS:
            return web.json_response(
                self._error(None, INVALID_REQUEST, f"unsupported MCP-Protocol-Version {version}"),
                status=400,
            )
        if request.content_length and request.content_length > MAX_REQUEST_BYTES:
            raise web.HTTPRequestEntityTooLarge(
                max_size=MAX_REQUEST_BYTES, actual_size=request.content_length
            )
        try:
            message = json.loads(await request.read())
        except (ValueError, UnicodeDecodeError):
            return web.json_response(self._error(None, PARSE_ERROR, "parse error"), status=400)
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return web.json_response(
                self._error(None, INVALID_REQUEST, "expected one JSON-RPC 2.0 message"),
                status=400,
            )
        if "method" not in message:
            # A response or error from the client; this server never sends requests.
            return web.Response(status=202)
        if "id" not in message:
            return web.Response(status=202)
        response = await self.dispatch(message)
        return web.json_response(response, dumps=lambda value: json.dumps(value, ensure_ascii=False))

    async def dispatch(self, message: dict[str, Any]) -> dict[str, Any]:
        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params") or {}
        if not isinstance(params, dict):
            return self._error(request_id, INVALID_PARAMS, "params must be an object")
        if method == "initialize":
            requested = params.get("protocolVersion")
            version = requested if requested in SUPPORTED_PROTOCOL_VERSIONS else LATEST_PROTOCOL_VERSION
            return self._result(
                request_id,
                {
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {
                        "name": SERVER_NAME,
                        "title": "WakeOnCue recordings",
                        "version": SERVER_VERSION,
                    },
                    "instructions": (
                        "Read-only access to the user's WakeOnCue recording transcripts. "
                        "Use search_transcripts first, answer only from returned segments and "
                        "cite recording_id and timestamp for every claim. Say so when nothing "
                        "relevant is found."
                    ),
                },
            )
        if method == "ping":
            return self._result(request_id, {})
        if method == "tools/list":
            return self._result(request_id, {"tools": TOOLS})
        if method == "tools/call":
            name = params.get("name")
            arguments = params.get("arguments") or {}
            if not isinstance(name, str) or not isinstance(arguments, dict):
                return self._error(request_id, INVALID_PARAMS, "name and arguments are required")
            if name not in {tool["name"] for tool in TOOLS}:
                return self._error(request_id, INVALID_PARAMS, f"unknown tool {name}")
            try:
                structured = await asyncio.to_thread(self.tools.call, name, arguments)
            except (ToolError, ArchiveError) as error:
                return self._result(
                    request_id,
                    {"content": [{"type": "text", "text": str(error)}], "isError": True},
                )
            text = json.dumps(structured, ensure_ascii=False, indent=2)
            return self._result(
                request_id,
                {"content": [{"type": "text", "text": text}], "structuredContent": structured},
            )
        return self._error(request_id, METHOD_NOT_FOUND, f"method {method} is not supported")

    def _check_request(self, request: web.Request) -> None:
        # Browsers send Origin; rejecting foreign origins blocks DNS-rebinding attacks.
        origin = request.headers.get("Origin")
        if origin and origin not in self.allowed_origins and urlsplit(origin).netloc != request.host:
            raise web.HTTPForbidden(text="origin not allowed")
        supplied = request.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied.encode(), f"Bearer {self.api_token}".encode()):
            raise web.HTTPUnauthorized(
                text="valid Bearer token required", headers={"WWW-Authenticate": "Bearer"}
            )

    @staticmethod
    def _result(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    @staticmethod
    def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def archive_from_environment(environ: dict[str, str] | None = None) -> S3RecordingArchive | None:
    """Builds the S3 reader from `WAKEONCUE_MCP_S3_*`; credentials use the normal AWS chain."""
    env = os.environ if environ is None else environ
    bucket = env.get("WAKEONCUE_MCP_S3_BUCKET", "").strip()
    if not bucket:
        return None
    import boto3
    from botocore.config import Config

    path_style = env.get("WAKEONCUE_MCP_S3_FORCE_PATH_STYLE", "").lower() in {"1", "true", "yes"}
    client = boto3.client(
        "s3",
        region_name=env.get("WAKEONCUE_MCP_S3_REGION") or "us-east-1",
        endpoint_url=env.get("WAKEONCUE_MCP_S3_ENDPOINT_URL") or None,
        config=Config(
            connect_timeout=5,
            read_timeout=15,
            retries={"max_attempts": 2, "mode": "standard"},
            s3={"addressing_style": "path" if path_style else "auto"},
        ),
    )
    return S3RecordingArchive(client, bucket, env.get("WAKEONCUE_MCP_S3_PREFIX", "wakeoncue"))


def mcp_server_from_environment(
    api_token: str, environ: dict[str, str] | None = None
) -> McpServer | None:
    env = os.environ if environ is None else environ
    archive = archive_from_environment(env)
    if archive is None:
        return None
    origins = tuple(
        origin.strip()
        for origin in env.get("WAKEONCUE_MCP_ALLOWED_ORIGINS", "").split(",")
        if origin.strip()
    )
    refresh = float(env.get("WAKEONCUE_MCP_REFRESH_SECONDS", "30"))
    return McpServer(RecordingTools(RecordingIndex(archive, refresh)), api_token, origins)


def main() -> None:
    """Standalone entry point for running the MCP server without the realtime Gateway."""
    token = os.environ.get("WAKEONCUE_MCP_API_TOKEN") or os.environ.get(
        "WAKEONCUE_REALTIME_API_TOKEN", ""
    )
    if not token:
        raise SystemExit("Set WAKEONCUE_MCP_API_TOKEN (or WAKEONCUE_REALTIME_API_TOKEN).")
    server = mcp_server_from_environment(token)
    if server is None:
        raise SystemExit("Set WAKEONCUE_MCP_S3_BUCKET to the bucket the iPhone uploads to.")
    app = web.Application(client_max_size=MAX_REQUEST_BYTES)
    server.register(app)
    web.run_app(
        app,
        host=os.environ.get("WAKEONCUE_MCP_HOST", "127.0.0.1"),
        port=int(os.environ.get("WAKEONCUE_MCP_PORT", "8091")),
        print=lambda message: print(f"WakeOnCue MCP server: {message}", flush=True),
    )


if __name__ == "__main__":
    main()
