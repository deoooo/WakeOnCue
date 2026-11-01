from __future__ import annotations

import io
import json
import unittest

from aiohttp import ClientSession
from aiohttp.test_utils import TestServer

from recording_service.mcp_server import (
    McpServer,
    RecordingIndex,
    RecordingTools,
    S3RecordingArchive,
    query_terms,
)
from recording_service.realtime_gateway import RealtimeGateway


TOKEN = "test-mcp-token"


class FakeS3:
    """Implements the three S3 calls the archive makes, with ETags from content."""

    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}
        self.reads: list[str] = []

    def put(self, key: str, value: object) -> None:
        self.objects[key] = json.dumps(value, ensure_ascii=False).encode()

    def list_objects_v2(self, Bucket: str, Prefix: str, Delimiter: str, **_: object) -> dict:
        contents, prefixes = [], set()
        for key, body in sorted(self.objects.items()):
            if not key.startswith(Prefix):
                continue
            rest = key[len(Prefix):]
            if Delimiter in rest:
                prefixes.add(Prefix + rest.split(Delimiter, 1)[0] + Delimiter)
            else:
                contents.append({"Key": key, "ETag": f'"{hash(body)}"'})
        return {
            "Contents": contents,
            "CommonPrefixes": [{"Prefix": prefix} for prefix in sorted(prefixes)],
            "IsTruncated": False,
        }

    def get_object(self, Bucket: str, Key: str) -> dict:
        self.reads.append(Key)
        return {"Body": io.BytesIO(self.objects[Key])}


def segment(segment_id: str, start: int, text: str, speaker: str | None = None, **extra: object) -> dict:
    payload: dict = {
        "protocol_version": 1,
        "type": "transcript.upsert",
        "recording_id": "ignored",
        "segment_id": segment_id,
        "revision": 1,
        "start_ms": start,
        "end_ms": start + 4000,
        "text": text,
        "is_final": True,
        "speaker": None,
        **extra,
    }
    if speaker:
        payload["speaker"] = {
            "cluster_id": "c1",
            "person_id": "self",
            "display_name": speaker,
            "confidence": 0.9,
            "embedding": [0.1, 0.2],
        }
    return payload


def make_archive() -> tuple[FakeS3, S3RecordingArchive]:
    s3 = FakeS3()
    root = "wakeoncue/recordings"
    s3.put(
        f"{root}/rec_budget/metadata.json",
        {
            "id": "rec_budget",
            "created_at": "2026-10-20T09:00:00Z",
            "started_at": "2026-10-20T09:00:00Z",
            "device_model": "iPhone",
            "app_version": "1",
            "metadata": {"title": "Budget review", "s3_bucket": "private-bucket"},
        },
    )
    s3.put(
        f"{root}/rec_budget/transcript.json",
        [
            segment("s1", 0, "Good morning everyone", "Speaker 1"),
            segment("s2", 65_000, "We agreed the marketing budget is 20k", "Speaker 2"),
            segment("s2", 65_000, "We agreed the marketing budget is 30k", "Speaker 2", revision=2),
            segment("s3", 3_725_000, "我们决定下周发布新版本"),
        ],
    )
    s3.put(
        f"{root}/rec_budget/summary.json",
        {
            "title": "Budget",
            "overview": "Budget meeting",
            "keyPoints": ["Budget is 30k"],
            "actionItems": [],
            "generatedAt": 0,
        },
    )
    s3.objects[f"{root}/rec_budget/source.m4a"] = b"audio"
    s3.objects[f"{root}/rec_budget/chunks/000001.m4a"] = b"audio"
    s3.put(
        f"{root}/rec_old/metadata.json",
        {"id": "rec_old", "created_at": "2026-09-01T09:00:00Z", "started_at": "2026-09-01T09:00:00Z"},
    )
    s3.put(f"{root}/rec_old/transcript.json", [segment("o1", 1000, "Lunch plans for Friday")])
    s3.put("wakeoncue/.wakeoncue-validation/x", {})
    return s3, S3RecordingArchive(s3, "bucket", "/wakeoncue/")


class RecordingToolsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.s3, archive = make_archive()
        self.now = 0.0
        self.index = RecordingIndex(archive, refresh_seconds=30, clock=lambda: self.now)
        self.tools = RecordingTools(self.index)

    def test_search_returns_citations_with_latest_revision(self) -> None:
        result = self.tools.call("search_transcripts", {"query": "marketing budget", "limit": 5})
        self.assertTrue(result["found"])
        first = result["citations"][0]
        self.assertEqual(first["recording_id"], "rec_budget")
        self.assertEqual(first["recording_title"], "Budget review")
        self.assertEqual(first["segment_id"], "s2")
        self.assertEqual(first["timestamp"], "01:05")
        self.assertEqual(first["start_ms"], 65_000)
        self.assertEqual(first["speaker"], "Speaker 2")
        self.assertIn("30k", first["text"])

    def test_search_handles_chinese_and_reports_nothing_found(self) -> None:
        result = self.tools.call("search_transcripts", {"query": "什么时候发布"})
        self.assertEqual(result["citations"][0]["segment_id"], "s3")
        self.assertEqual(result["citations"][0]["timestamp"], "1:02:05")
        self.assertFalse(self.tools.call("search_transcripts", {"query": "kangaroo"})["found"])

    def test_query_terms_split_cjk_into_pairs(self) -> None:
        self.assertEqual(query_terms("下周发布"), ["下周", "周发", "发布"])
        self.assertEqual(query_terms("What is the budget?"), ["budget"])

    def test_get_recording_whitelists_fields(self) -> None:
        result = self.tools.call("get_recording", {"recording_id": "rec_budget"})
        self.assertEqual(result["summary"]["key_points"], ["Budget is 30k"])
        self.assertEqual(len(result["segments"]), 3)
        serialized = json.dumps(result)
        for secret in ("embedding", "person_id", "cluster_id", "private-bucket", "confidence"):
            self.assertNotIn(secret, serialized)
        with self.assertRaises(ValueError):
            self.tools.call("get_recording", {"recording_id": "../rec_budget"})
        with self.assertRaises(ValueError):
            self.tools.call("get_recording", {"recording_id": "missing"})

    def test_list_recordings_newest_first_with_since(self) -> None:
        listed = self.tools.call("list_recordings", {})["recordings"]
        self.assertEqual([r["recording_id"] for r in listed], ["rec_budget", "rec_old"])
        self.assertEqual(listed[0]["duration_ms"], 3_729_000)
        recent = self.tools.call("list_recordings", {"since": "2026-10-01"})["recordings"]
        self.assertEqual([r["recording_id"] for r in recent], ["rec_budget"])
        with self.assertRaises(ValueError):
            self.tools.call("list_recordings", {"since": "last week"})

    def test_never_reads_audio_and_rereads_only_changed_files(self) -> None:
        self.tools.call("list_recordings", {})
        self.assertFalse(any(key.endswith(".m4a") for key in self.s3.reads))
        reads = len(self.s3.reads)
        self.now = 10
        self.tools.call("list_recordings", {})
        self.assertEqual(len(self.s3.reads), reads)

        self.s3.put(
            "wakeoncue/recordings/rec_old/transcript.json",
            [segment("o1", 1000, "Dinner plans for Friday")],
        )
        self.now = 31
        result = self.tools.call("search_transcripts", {"query": "dinner"})
        self.assertEqual(result["citations"][0]["recording_id"], "rec_old")
        self.assertEqual(self.s3.reads[reads:], ["wakeoncue/recordings/rec_old/transcript.json"])


class McpHttpTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        _, archive = make_archive()
        mcp = McpServer(RecordingTools(RecordingIndex(archive)), TOKEN)
        self.server = TestServer(RealtimeGateway(TOKEN, mcp=mcp).application())
        await self.server.start_server()
        self.client = ClientSession()

    async def asyncTearDown(self) -> None:
        await self.client.close()
        await self.server.close()

    async def rpc(self, method: str, params: dict | None = None, **headers: str) -> dict:
        response = await self.client.post(
            self.server.make_url("/mcp"),
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Accept": "application/json, text/event-stream",
                **headers,
            },
            json={"jsonrpc": "2.0", "id": 7, "method": method, "params": params or {}},
        )
        self.assertEqual(response.status, 200)
        return await response.json()

    async def test_initialize_list_and_call(self) -> None:
        initialized = await self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}})
        self.assertEqual(initialized["id"], 7)
        self.assertEqual(initialized["result"]["protocolVersion"], "2025-06-18")
        self.assertIn("tools", initialized["result"]["capabilities"])

        notified = await self.client.post(
            self.server.make_url("/mcp"),
            headers={"Authorization": f"Bearer {TOKEN}"},
            json={"jsonrpc": "2.0", "method": "notifications/initialized"},
        )
        self.assertEqual(notified.status, 202)

        listed = await self.rpc("tools/list", **{"MCP-Protocol-Version": "2025-06-18"})
        names = {tool["name"] for tool in listed["result"]["tools"]}
        self.assertEqual(names, {"search_transcripts", "get_recording", "list_recordings"})
        self.assertTrue(all(tool["annotations"]["readOnlyHint"] for tool in listed["result"]["tools"]))

        called = await self.rpc(
            "tools/call", {"name": "search_transcripts", "arguments": {"query": "budget"}}
        )
        structured = called["result"]["structuredContent"]
        self.assertEqual(structured["citations"][0]["recording_id"], "rec_budget")
        self.assertEqual(json.loads(called["result"]["content"][0]["text"]), structured)

        failed = await self.rpc("tools/call", {"name": "get_recording", "arguments": {}})
        self.assertTrue(failed["result"]["isError"])
        unknown = await self.rpc("tools/call", {"name": "delete_recording", "arguments": {}})
        self.assertEqual(unknown["error"]["code"], -32602)
        missing = await self.rpc("resources/list")
        self.assertEqual(missing["error"]["code"], -32601)

    async def test_requires_token_and_rejects_foreign_origin(self) -> None:
        response = await self.client.post(self.server.make_url("/mcp"), json={})
        self.assertEqual(response.status, 401)
        self.assertEqual(response.headers["WWW-Authenticate"], "Bearer")
        response = await self.client.post(
            self.server.make_url("/mcp"),
            headers={"Authorization": f"Bearer {TOKEN}", "Origin": "https://evil.example"},
            json={"jsonrpc": "2.0", "id": 1, "method": "ping"},
        )
        self.assertEqual(response.status, 403)
        response = await self.client.get(
            self.server.make_url("/mcp"), headers={"Authorization": f"Bearer {TOKEN}"}
        )
        self.assertEqual(response.status, 405)
        response = await self.client.post(
            self.server.make_url("/mcp"),
            headers={"Authorization": f"Bearer {TOKEN}", "MCP-Protocol-Version": "1999-01-01"},
            json={"jsonrpc": "2.0", "id": 1, "method": "ping"},
        )
        self.assertEqual(response.status, 400)
        response = await self.client.post(
            self.server.make_url("/mcp"),
            headers={"Authorization": f"Bearer {TOKEN}"},
            json=[{"jsonrpc": "2.0", "id": 1, "method": "ping"}],
        )
        self.assertEqual(response.status, 400)

    async def test_gateway_without_mcp_has_no_route(self) -> None:
        server = TestServer(RealtimeGateway(TOKEN).application())
        await server.start_server()
        try:
            response = await self.client.post(
                server.make_url("/mcp"), headers={"Authorization": f"Bearer {TOKEN}"}, json={}
            )
            self.assertEqual(response.status, 404)
        finally:
            await server.close()


if __name__ == "__main__":
    unittest.main()
