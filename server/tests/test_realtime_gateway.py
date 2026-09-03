from __future__ import annotations

import unittest

from aiohttp import ClientSession, WSMsgType
from aiohttp.test_utils import TestServer

from recording_service.realtime_gateway import create_realtime_application


class RealtimeGatewayTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.server = TestServer(create_realtime_application("test-realtime-token"))
        await self.server.start_server()
        self.client = ClientSession()

    async def asyncTearDown(self) -> None:
        await self.client.close()
        await self.server.close()

    async def test_routes_audio_and_replays_revisioned_transcript(self) -> None:
        processor = await self.client.ws_connect(
            self.server.make_url("/v1/processors/connect"),
            headers={"Authorization": "Bearer test-realtime-token"},
        )
        await processor.send_json(
            {
                "protocol_version": 1,
                "type": "processor.register",
                "processor_id": "processor_test",
                "capabilities": {"asr": True, "speaker_diarization": True},
            }
        )
        registered = await processor.receive_json()
        self.assertEqual(registered["type"], "processor.registered")

        response = await self.client.post(
            self.server.make_url("/v1/realtime/sessions"),
            headers={"Authorization": "Bearer test-realtime-token"},
            json={
                "protocol_version": 1,
                "recording_id": "rec_realtime",
                "language": "zh-Hans",
                "audio": {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1},
            },
        )
        self.assertEqual(response.status, 201)
        created = await response.json()
        app_socket_url = self.server.make_url(
            f"/v1/realtime/sessions/{created['session_id']}/stream"
        )
        app = await self.client.ws_connect(
            app_socket_url,
            headers={"Authorization": f"Bearer {created['session_token']}"},
        )

        started = await processor.receive_json()
        self.assertEqual(started["type"], "session.started")
        statuses = [await app.receive_json(), await app.receive_json()]
        self.assertIn("processing", {event.get("status") for event in statuses})

        await app.send_json(
            {"protocol_version": 1, "type": "audio.append", "sequence": 1, "audio_base64": "AAA="}
        )
        audio = await processor.receive_json()
        self.assertEqual(audio["type"], "audio.append")
        self.assertEqual(audio["recording_id"], "rec_realtime")

        await processor.send_json(
            {
                "protocol_version": 1,
                "type": "transcript.upsert",
                "session_id": created["session_id"],
                "segment_id": "seg_1",
                "start_ms": 0,
                "end_ms": 1200,
                "text": "测试文本",
                "is_final": True,
                "speaker": {
                    "cluster_id": "speaker_1",
                    "display_name": "Speaker 1",
                    "confidence": 0.9,
                },
            }
        )
        transcript = await app.receive_json()
        self.assertEqual(transcript["revision"], 1)
        self.assertEqual(transcript["speaker"]["cluster_id"], "speaker_1")

        await app.send_json(
            {"protocol_version": 1, "type": "session.replay", "after_revision": 0}
        )
        replay = await app.receive_json()
        self.assertEqual(replay["segment_id"], "seg_1")
        self.assertEqual(replay["revision"], 1)

        await app.close()
        await processor.close()

    async def test_requires_auth_and_rejects_incompatible_audio(self) -> None:
        response = await self.client.post(
            self.server.make_url("/v1/realtime/sessions"), json={}
        )
        self.assertEqual(response.status, 401)

        response = await self.client.post(
            self.server.make_url("/v1/realtime/sessions"),
            headers={"Authorization": "Bearer test-realtime-token"},
            json={
                "protocol_version": 1,
                "recording_id": "rec_bad",
                "audio": {"encoding": "opus", "sample_rate": 48000, "channels": 1},
            },
        )
        self.assertEqual(response.status, 422)

    async def test_delivers_finish_when_processor_joins_late(self) -> None:
        response = await self.client.post(
            self.server.make_url("/v1/realtime/sessions"),
            headers={"Authorization": "Bearer test-realtime-token"},
            json={
                "protocol_version": 1,
                "recording_id": "rec_late_processor",
                "language": None,
                "audio": {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1},
            },
        )
        created = await response.json()
        app = await self.client.ws_connect(
            self.server.make_url(f"/v1/realtime/sessions/{created['session_id']}/stream"),
            headers={"Authorization": f"Bearer {created['session_token']}"},
        )
        await app.receive_json()
        await app.send_json({"protocol_version": 1, "type": "session.finish"})

        processor = await self.client.ws_connect(
            self.server.make_url("/v1/processors/connect"),
            headers={"Authorization": "Bearer test-realtime-token"},
        )
        await processor.send_json(
            {
                "protocol_version": 1,
                "type": "processor.register",
                "processor_id": "late_processor",
                "capabilities": {"asr": True},
            }
        )
        self.assertEqual((await processor.receive_json())["type"], "processor.registered")
        self.assertEqual((await processor.receive_json())["type"], "session.started")
        self.assertEqual((await processor.receive_json())["type"], "session.finish")
        await app.close()
        await processor.close()


if __name__ == "__main__":
    unittest.main()
