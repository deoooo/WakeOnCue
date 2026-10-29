from __future__ import annotations

import asyncio
import base64
import unittest

from aiohttp import ClientSession, WSMsgType
from aiohttp.test_utils import TestServer

from recording_service.realtime_gateway import RealtimeGateway


class RealtimeGatewayTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.gateway = RealtimeGateway("test-realtime-token")
        self.server = TestServer(self.gateway.application())
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

    async def _register_processor(self, capabilities: dict) -> object:
        processor = await self.client.ws_connect(
            self.server.make_url("/v1/processors/connect"),
            headers={"Authorization": "Bearer test-realtime-token"},
        )
        await processor.send_json(
            {
                "protocol_version": 1,
                "type": "processor.register",
                "processor_id": "voice_processor",
                "capabilities": capabilities,
            }
        )
        self.assertEqual((await processor.receive_json())["type"], "processor.registered")
        return processor

    async def test_forwards_known_voiceprints_and_rejects_invalid_ones(self) -> None:
        processor = await self._register_processor({"voiceprint_model": "m"})
        audio = {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1}
        response = await self.client.post(
            self.server.make_url("/v1/realtime/sessions"),
            headers={"Authorization": "Bearer test-realtime-token"},
            json={
                "protocol_version": 1,
                "recording_id": "rec_bad_voice",
                "audio": audio,
                "speaker_diarization": True,
                "known_voiceprints": [{"person_id": "self", "model": "m", "embedding": ["x"]}],
            },
        )
        self.assertEqual(response.status, 422)

        response = await self.client.post(
            self.server.make_url("/v1/realtime/sessions"),
            headers={"Authorization": "Bearer test-realtime-token"},
            json={
                "protocol_version": 1,
                "recording_id": "rec_voice",
                "audio": audio,
                "speaker_diarization": True,
                "known_voiceprints": [
                    {"person_id": "self", "model": "m", "embedding": [0.5, 0.5]}
                ],
            },
        )
        created = await response.json()
        app = await self.client.ws_connect(
            self.server.make_url(f"/v1/realtime/sessions/{created['session_id']}/stream"),
            headers={"Authorization": f"Bearer {created['session_token']}"},
        )
        started = await processor.receive_json()
        self.assertTrue(started["speaker_diarization"])
        self.assertEqual(
            started["known_voiceprints"],
            [{"person_id": "self", "model": "m", "embedding": [0.5, 0.5]}],
        )

        await processor.send_json(
            {"type": "session.completed", "session_id": created["session_id"]}
        )
        while (await app.receive_json())["type"] != "session.completed":
            pass
        self.assertEqual(self.gateway.sessions[created["session_id"]].known_voiceprints, [])
        await app.close()
        await processor.close()

    async def test_enrolls_voiceprint_through_processor(self) -> None:
        processor = await self._register_processor({"voiceprint_model": "m"})
        audio = {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1}
        sample = base64.b64encode(bytes(48_000)).decode()

        async def answer() -> dict:
            request = await processor.receive_json()
            await processor.send_json(
                {
                    "protocol_version": 1,
                    "type": "voiceprint.enrolled",
                    "request_id": request["request_id"],
                    "voiceprint": {"model": "m", "embedding": [0.1, 0.2]},
                    "speech_ms": 900,
                }
            )
            return request

        answering = asyncio.create_task(answer())
        response = await self.client.post(
            self.server.make_url("/v1/voiceprints/enroll"),
            headers={"Authorization": "Bearer test-realtime-token"},
            json={"protocol_version": 1, "audio": audio, "audio_base64": sample},
        )
        request = await answering
        self.assertEqual(request["type"], "voiceprint.enroll")
        self.assertEqual(request["audio_base64"], sample)
        self.assertEqual(response.status, 200)
        body = await response.json()
        self.assertEqual(body["voiceprint"], {"model": "m", "embedding": [0.1, 0.2]})
        self.assertEqual(body["speech_ms"], 900)

        async def reject() -> None:
            request = await processor.receive_json()
            await processor.send_json(
                {
                    "type": "voiceprint.failed",
                    "request_id": request["request_id"],
                    "reason": "insufficient_speech",
                }
            )

        rejecting = asyncio.create_task(reject())
        response = await self.client.post(
            self.server.make_url("/v1/voiceprints/enroll"),
            headers={"Authorization": "Bearer test-realtime-token"},
            json={"protocol_version": 1, "audio": audio, "audio_base64": sample},
        )
        await rejecting
        self.assertEqual(response.status, 422)
        self.assertEqual((await response.json())["error"], "insufficient_speech")
        await processor.close()

    async def test_enrollment_requires_capable_processor_and_bounded_audio(self) -> None:
        audio = {"encoding": "pcm_s16le", "sample_rate": 24000, "channels": 1}
        url = self.server.make_url("/v1/voiceprints/enroll")
        headers = {"Authorization": "Bearer test-realtime-token"}
        sample = base64.b64encode(bytes(4800)).decode()

        response = await self.client.post(url, json={})
        self.assertEqual(response.status, 401)

        processor = await self._register_processor({"asr": True})
        response = await self.client.post(
            url,
            headers=headers,
            json={"protocol_version": 1, "audio": audio, "audio_base64": sample},
        )
        self.assertEqual(response.status, 503)

        too_long = base64.b64encode(bytes(24_000 * 2 * 26)).decode()
        response = await self.client.post(
            url,
            headers=headers,
            json={"protocol_version": 1, "audio": audio, "audio_base64": too_long},
        )
        self.assertEqual(response.status, 413)
        await processor.close()


if __name__ == "__main__":
    unittest.main()
