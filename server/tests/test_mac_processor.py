from __future__ import annotations

import base64
import json
import struct
import unittest
from typing import Any

from recording_service.mac_processor import (
    AnalysisResult,
    MacRealtimeProcessor,
    _is_credible_segment,
)
from recording_service.speaker_diarization import DiarizationResult, SpeakerTurn


class FakeSocket:
    def __init__(self) -> None:
        self.messages: list[dict[str, Any]] = []

    async def send(self, value: str) -> None:
        self.messages.append(json.loads(value))


class FakeASRBackend:
    def __init__(self, detected_language: str | None = None) -> None:
        self.detected_language = detected_language
        self.calls: list[dict[str, Any]] = []

    async def analyze(
        self,
        pcm: bytes,
        sample_rate: int,
        language: str | None,
        offset_ms: int,
        initial_prompt: str | None = None,
    ) -> AnalysisResult:
        self.calls.append(
            {
                "pcm": pcm,
                "language": language,
                "offset_ms": offset_ms,
                "initial_prompt": initial_prompt,
            }
        )
        duration_ms = int(len(pcm) / 2 / sample_rate * 1000)
        return AnalysisResult(
            events=[{
                "type": "transcript.upsert",
                "segment_id": f"seg_{offset_ms}",
                "start_ms": offset_ms,
                "end_ms": offset_ms + duration_ms,
                "text": f"hello {offset_ms}",
                "_words": [
                    {
                        "start_ms": offset_ms + word_start,
                        "end_ms": offset_ms + word_start + 1000,
                        "text": f" hello{(offset_ms + word_start) // 1000}",
                    }
                    for word_start in range(0, duration_ms, 1000)
                ],
                "is_final": True,
                "speaker": {
                    "cluster_id": "speaker_unknown",
                    "person_id": None,
                    "display_name": "Unknown speaker",
                    "confidence": None,
                },
            }],
            detected_language=self.detected_language,
        )


class FakeRevisingASRBackend(FakeASRBackend):
    supports_live_revisions = True
    locks_detected_language = False


class FakeDiarizer:
    async def diarize(self, pcm: bytes, sample_rate: int) -> DiarizationResult:
        return DiarizationResult(
            turns=[SpeakerTurn(0, 1000, "model_speaker_a")],
            embeddings={"model_speaker_a": (1.0, 0.0)},
        )


class MacRealtimeProcessorTest(unittest.IsolatedAsyncioTestCase):
    async def test_emits_speaker_correction_for_existing_transcript(self) -> None:
        socket = FakeSocket()
        processor = MacRealtimeProcessor(
            "http://gateway.invalid",
            "token",
            "processor",
            FakeASRBackend(),
            speaker_diarizer=FakeDiarizer(),
            window_seconds=1,
            diarization_interval_seconds=1,
            diarization_overlap_seconds=0,
        )
        await processor._handle(
            socket,
            {
                "type": "session.started",
                "session_id": "session_1",
                "language": "en",
                "audio": {"sample_rate": 100},
            },
        )
        await processor._handle(
            socket,
            {
                "type": "audio.append",
                "session_id": "session_1",
                "audio_base64": base64.b64encode(bytes(200)).decode(),
            },
        )
        session = processor.sessions["session_1"]
        if session.diarization_task is not None:
            await session.diarization_task

        transcript = next(message for message in socket.messages if message["type"] == "transcript.upsert")
        correction = next(message for message in socket.messages if message["type"] == "speaker.corrected")
        self.assertEqual(transcript["speaker"]["cluster_id"], "speaker_unknown")
        self.assertEqual(correction["segment_id"], transcript["segment_id"])
        self.assertEqual(correction["speaker"]["cluster_id"], "speaker_1")
        self.assertEqual(correction["speaker"]["display_name"], "Speaker 1")
        self.assertEqual(len(session.diarization_pcm), 0)
        self.assertEqual(session.diarization_buffer_start_ms, 1000)

    async def test_uses_overlapping_windows_without_republishing_old_audio(self) -> None:
        socket = FakeSocket()
        backend = FakeASRBackend()
        processor = MacRealtimeProcessor(
            "http://gateway.invalid",
            "token",
            "processor",
            backend,
            window_seconds=4,
            stride_seconds=2,
        )
        await processor._handle(
            socket,
            {
                "type": "session.started",
                "session_id": "session_1",
                "audio": {"sample_rate": 100},
            },
        )
        await processor._handle(
            socket,
            {
                "type": "audio.append",
                "session_id": "session_1",
                "audio_base64": base64.b64encode(bytes(1200)).decode(),
            },
        )

        self.assertEqual([call["offset_ms"] for call in backend.calls], [0, 2000])
        transcripts = [m for m in socket.messages if m["type"] == "transcript.upsert"]
        self.assertEqual([m["start_ms"] for m in transcripts], [0, 4000])
        self.assertEqual(transcripts[1]["text"], "hello4 hello5")
        self.assertEqual(
            [m["segment_id"] for m in transcripts],
            ["seg_0_4000", "seg_4000_6000"],
        )
        self.assertEqual(processor.sessions["session_1"].published_audio_ms, 6000)

    async def test_locks_detected_language_and_passes_recent_context(self) -> None:
        socket = FakeSocket()
        backend = FakeASRBackend(detected_language="zh")
        processor = MacRealtimeProcessor(
            "http://gateway.invalid",
            "token",
            "processor",
            backend,
            window_seconds=2,
            stride_seconds=1,
        )
        await processor._handle(
            socket,
            {
                "type": "session.started",
                "session_id": "session_1",
                "language": None,
                "audio": {"sample_rate": 100},
            },
        )
        await processor._handle(
            socket,
            {
                "type": "audio.append",
                "session_id": "session_1",
                "audio_base64": base64.b64encode(bytes(600)).decode(),
            },
        )

        self.assertIsNone(backend.calls[0]["language"])
        self.assertEqual(backend.calls[1]["language"], "zh")
        self.assertEqual(backend.calls[1]["initial_prompt"], "hello 0")

    async def test_revises_one_live_segment_then_finalizes_with_same_id(self) -> None:
        socket = FakeSocket()
        backend = FakeRevisingASRBackend(detected_language="zh")
        processor = MacRealtimeProcessor(
            "http://gateway.invalid",
            "token",
            "processor",
            backend,
            live_update_seconds=1,
            max_utterance_seconds=2,
        )
        await processor._handle(
            socket,
            {
                "type": "session.started",
                "session_id": "session_1",
                "audio": {"sample_rate": 100},
            },
        )
        speech = struct.pack("<h", 8_000) * 200
        await processor._handle(
            socket,
            {
                "type": "audio.append",
                "session_id": "session_1",
                "audio_base64": base64.b64encode(speech[:200]).decode(),
            },
        )
        await processor._handle(
            socket,
            {
                "type": "audio.append",
                "session_id": "session_1",
                "audio_base64": base64.b64encode(speech[200:]).decode(),
            },
        )

        transcripts = [m for m in socket.messages if m["type"] == "transcript.upsert"]
        self.assertGreaterEqual(len(transcripts), 2)
        self.assertEqual({m["segment_id"] for m in transcripts}, {"seg_0"})
        self.assertFalse(transcripts[0]["is_final"])
        self.assertTrue(transcripts[-1]["is_final"])
        self.assertTrue(all(call["language"] is None for call in backend.calls))

    def test_rejects_silence_and_repetition_hallucinations(self) -> None:
        self.assertFalse(
            _is_credible_segment(
                {"no_speech_prob": 0.9, "avg_logprob": -1.2}, "Thanks for watching"
            )
        )
        self.assertFalse(_is_credible_segment({}, "hello hello hello hello hello hello"))
        self.assertTrue(_is_credible_segment({}, "今天讨论一下发布计划"))


if __name__ == "__main__":
    unittest.main()
