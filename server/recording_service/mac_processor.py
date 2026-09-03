from __future__ import annotations

import argparse
import asyncio
import base64
import json
import math
import os
import re
import tempfile
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from websockets.asyncio.client import ClientConnection, connect

from .speaker_diarization import (
    SherpaOnnxSpeakerDiarizer,
    SpeakerDiarizer,
    StableSpeakerTracker,
)


class AnalysisBackend(Protocol):
    async def analyze(
        self,
        pcm: bytes,
        sample_rate: int,
        language: str | None,
        offset_ms: int,
        initial_prompt: str | None = None,
    ) -> "AnalysisResult": ...


@dataclass(frozen=True)
class AnalysisResult:
    events: list[dict[str, Any]]
    detected_language: str | None = None


class MLXWhisperBackend:
    """Mac-first backend. The Gateway protocol remains independent of MLX."""

    def __init__(self, model: str) -> None:
        try:
            import mlx_whisper  # type: ignore[import-not-found]
        except ImportError as error:
            raise RuntimeError(
                "MLX Whisper is not installed. Run: pip install mlx-whisper"
            ) from error
        self._mlx_whisper = mlx_whisper
        self.model = model

    async def analyze(
        self,
        pcm: bytes,
        sample_rate: int,
        language: str | None,
        offset_ms: int,
        initial_prompt: str | None = None,
    ) -> AnalysisResult:
        return await asyncio.to_thread(
            self._analyze_sync, pcm, sample_rate, language, offset_ms, initial_prompt
        )

    def _analyze_sync(
        self,
        pcm: bytes,
        sample_rate: int,
        language: str | None,
        offset_ms: int,
        initial_prompt: str | None = None,
    ) -> AnalysisResult:
        with tempfile.NamedTemporaryFile(suffix=".wav") as temporary:
            with wave.open(temporary.name, "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(sample_rate)
                output.writeframes(pcm)
            result = self._mlx_whisper.transcribe(
                temporary.name,
                path_or_hf_repo=self.model,
                language=language.split("-")[0] if language else None,
                initial_prompt=initial_prompt,
                condition_on_previous_text=True,
                compression_ratio_threshold=2.4,
                logprob_threshold=-1.0,
                no_speech_threshold=0.6,
                hallucination_silence_threshold=1.5,
                word_timestamps=True,
            )
        events: list[dict[str, Any]] = []
        for index, segment in enumerate(result.get("segments", [])):
            text = str(segment.get("text", "")).strip()
            if not text or not _is_credible_segment(segment, text):
                continue
            events.append(
                {
                    "type": "transcript.upsert",
                    "segment_id": f"seg_{offset_ms}_{index}",
                    "start_ms": offset_ms + int(float(segment.get("start", 0)) * 1000),
                    "end_ms": offset_ms + int(float(segment.get("end", 0)) * 1000),
                    "text": text,
                    "_words": [
                        {
                            "start_ms": offset_ms
                            + int(float(word.get("start", 0)) * 1000),
                            "end_ms": offset_ms + int(float(word.get("end", 0)) * 1000),
                            "text": str(word.get("word", "")),
                        }
                        for word in segment.get("words", [])
                        if str(word.get("word", "")).strip()
                    ],
                    "is_final": True,
                    # Diarization is a separate replaceable stage. Until configured,
                    # never invent a person's identity.
                    "speaker": {
                        "cluster_id": "speaker_unknown",
                        "person_id": None,
                        "display_name": "Unknown speaker",
                        "confidence": None,
                    },
                }
            )
        detected_language = str(result.get("language") or "").strip() or None
        return AnalysisResult(events=events, detected_language=detected_language)


class Qwen3ASRBackend:
    """Portable Qwen3-ASR backend using Transformers on MPS, CUDA, or CPU."""

    supports_live_revisions = True
    locks_detected_language = False

    _LANGUAGES = {
        "zh": "Chinese",
        "zh-hans": "Chinese",
        "zh-hant": "Chinese",
        "yue": "Cantonese",
        "en": "English",
        "ja": "Japanese",
        "ko": "Korean",
        "fr": "French",
        "de": "German",
        "es": "Spanish",
        "pt": "Portuguese",
        "ru": "Russian",
        "it": "Italian",
    }

    def __init__(self, model: str, device: str = "auto", glossary: str = "") -> None:
        try:
            import numpy as np  # type: ignore[import-not-found]
            import torch  # type: ignore[import-not-found]
            from qwen_asr import Qwen3ASRModel  # type: ignore[import-not-found]
        except ImportError as error:
            raise RuntimeError(
                "Qwen3-ASR is not installed. Use Python 3.12 and run: "
                "pip install -e '.[qwen-processor]'"
            ) from error
        self._np = np
        self._torch = torch
        self.model = model
        self.glossary = glossary.strip()
        if device == "auto":
            if torch.backends.mps.is_available():
                device = "mps"
            elif torch.cuda.is_available():
                device = "cuda:0"
            else:
                device = "cpu"
        dtype = torch.float16 if device == "mps" else (
            torch.bfloat16 if device.startswith("cuda") else torch.float32
        )
        print(f"Loading Qwen3-ASR model {model} on {device}...", flush=True)
        self._model = Qwen3ASRModel.from_pretrained(
            model,
            dtype=dtype,
            device_map=device,
            attn_implementation="sdpa",
            max_inference_batch_size=1,
            max_new_tokens=512,
        )
        print("Qwen3-ASR model is ready", flush=True)

    async def analyze(
        self,
        pcm: bytes,
        sample_rate: int,
        language: str | None,
        offset_ms: int,
        initial_prompt: str | None = None,
    ) -> AnalysisResult:
        return await asyncio.to_thread(
            self._analyze_sync, pcm, sample_rate, language, offset_ms, initial_prompt
        )

    def _analyze_sync(
        self,
        pcm: bytes,
        sample_rate: int,
        language: str | None,
        offset_ms: int,
        initial_prompt: str | None = None,
    ) -> AnalysisResult:
        samples = self._np.frombuffer(pcm, dtype=self._np.int16).astype(self._np.float32)
        samples /= 32768.0
        context_parts = [part for part in (self.glossary, initial_prompt) if part]
        forced_language = self._language_name(language)
        transcriptions = self._model.transcribe(
            audio=(samples, sample_rate),
            context="\n".join(context_parts),
            language=forced_language,
        )
        transcription = transcriptions[0]
        text = str(transcription.text or "").strip()
        duration_ms = int(len(pcm) / 2 / sample_rate * 1000)
        events = []
        if text:
            events.append(
                {
                    "type": "transcript.upsert",
                    "segment_id": f"seg_{offset_ms}",
                    "start_ms": offset_ms,
                    "end_ms": offset_ms + duration_ms,
                    "text": text,
                    "is_final": False,
                    "speaker": {
                        "cluster_id": "speaker_unknown",
                        "person_id": None,
                        "display_name": "Unknown speaker",
                        "confidence": None,
                    },
                }
            )
        detected = str(transcription.language or "").strip() or None
        return AnalysisResult(events=events, detected_language=detected)

    @classmethod
    def _language_name(cls, language: str | None) -> str | None:
        if not language:
            return None
        normalized = language.strip().replace("_", "-").casefold()
        return cls._LANGUAGES.get(normalized) or cls._LANGUAGES.get(normalized.split("-")[0])


def _is_credible_segment(segment: dict[str, Any], text: str) -> bool:
    """Reject common silence/repetition hallucinations without suppressing short speech."""
    no_speech = float(segment.get("no_speech_prob", 0.0) or 0.0)
    avg_logprob = float(segment.get("avg_logprob", 0.0) or 0.0)
    compression_ratio = float(segment.get("compression_ratio", 0.0) or 0.0)
    if no_speech > 0.75 and avg_logprob < -0.8:
        return False
    if compression_ratio > 2.8:
        return False
    normalized = re.sub(r"[\s\W_]+", "", text.casefold())
    if len(normalized) >= 12:
        for unit_length in range(1, min(20, len(normalized) // 3) + 1):
            unit = normalized[:unit_length]
            repeats = len(normalized) // unit_length
            if repeats >= 3 and unit * repeats == normalized[: unit_length * repeats]:
                return False
    words = re.findall(r"\w+", text.casefold())
    if len(words) >= 6 and len(set(words[-6:])) == 1:
        return False
    return True


def _pcm_frame_rms(pcm: bytes | bytearray, sample_rate: int) -> list[float]:
    frame_samples = max(1, sample_rate // 50)  # 20 ms
    samples = memoryview(pcm).cast("h")
    levels: list[float] = []
    for start in range(0, len(samples), frame_samples):
        frame = samples[start : start + frame_samples]
        if not frame:
            continue
        square_sum = sum(int(sample) * int(sample) for sample in frame)
        levels.append(math.sqrt(square_sum / len(frame)))
    return levels


def _speech_threshold(levels: list[float]) -> float:
    if not levels:
        return 350.0
    ordered = sorted(levels)
    noise_floor = ordered[max(0, int(len(ordered) * 0.2) - 1)]
    return max(350.0, min(1_500.0, noise_floor * 3.0))


def _contains_speech(pcm: bytes | bytearray, sample_rate: int) -> bool:
    levels = _pcm_frame_rms(pcm, sample_rate)
    threshold = _speech_threshold(levels)
    return sum(level >= threshold for level in levels) >= 3


def _trailing_silence_ms(pcm: bytes | bytearray, sample_rate: int) -> int:
    levels = _pcm_frame_rms(pcm, sample_rate)
    threshold = _speech_threshold(levels)
    quiet_frames = 0
    for level in reversed(levels):
        if level >= threshold:
            break
        quiet_frames += 1
    return quiet_frames * 20


@dataclass
class SessionBuffer:
    sample_rate: int
    language: str | None
    diarization_pcm: bytearray = field(default_factory=bytearray)
    diarization_buffer_start_ms: int = 0
    asr_pcm: bytearray = field(default_factory=bytearray)
    asr_buffer_start_ms: int = 0
    published_audio_ms: int = 0
    detected_language: str | None = None
    recent_transcript: list[str] = field(default_factory=list)
    transcript_segments: dict[str, dict[str, Any]] = field(default_factory=dict)
    speaker_tracker: StableSpeakerTracker = field(default_factory=StableSpeakerTracker)
    diarization_task: asyncio.Task[None] | None = None
    live_segment_id: str | None = None
    last_live_analysis_ms: int = 0
    finalized_asr_segments: list[tuple[str, int, bytes]] = field(default_factory=list)


class MacRealtimeProcessor:
    def __init__(
        self,
        gateway_url: str,
        token: str,
        processor_id: str,
        backend: AnalysisBackend,
        speaker_diarizer: SpeakerDiarizer | None = None,
        window_seconds: float = 16.0,
        stride_seconds: float = 4.0,
        diarization_interval_seconds: float = 20.0,
        diarization_overlap_seconds: float = 10.0,
        live_update_seconds: float = 4.0,
        utterance_silence_seconds: float = 0.7,
        max_utterance_seconds: float = 16.0,
    ) -> None:
        self.gateway_url = gateway_url.rstrip("/")
        self.token = token
        self.processor_id = processor_id
        self.backend = backend
        self.speaker_diarizer = speaker_diarizer
        self.window_seconds = window_seconds
        self.stride_seconds = min(stride_seconds, window_seconds)
        self.diarization_interval_seconds = diarization_interval_seconds
        self.diarization_overlap_seconds = diarization_overlap_seconds
        self.live_update_seconds = live_update_seconds
        self.utterance_silence_seconds = utterance_silence_seconds
        self.max_utterance_seconds = max_utterance_seconds
        self.sessions: dict[str, SessionBuffer] = {}

    async def run_forever(self) -> None:
        delay = 1.0
        while True:
            try:
                await self._run_once()
                delay = 1.0
            except asyncio.CancelledError:
                raise
            except Exception as error:
                print(f"Processor disconnected: {error}; retrying in {delay:.0f}s", flush=True)
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30)

    async def _run_once(self) -> None:
        websocket_url = self.gateway_url.replace("https://", "wss://", 1).replace(
            "http://", "ws://", 1
        )
        async with connect(
            f"{websocket_url}/v1/processors/connect",
            additional_headers={"Authorization": f"Bearer {self.token}"},
            max_size=2 * 1024 * 1024,
        ) as socket:
            await socket.send(
                json.dumps(
                    {
                        "protocol_version": 1,
                        "type": "processor.register",
                        "processor_id": self.processor_id,
                        "capabilities": {
                            "asr": True,
                            "speaker_diarization": self.speaker_diarizer is not None,
                            "backend": type(self.backend).__name__,
                        },
                    }
                )
            )
            async for raw in socket:
                if not isinstance(raw, str):
                    continue
                await self._handle(socket, json.loads(raw))

    async def _handle(self, socket: ClientConnection, event: dict[str, Any]) -> None:
        event_type = event.get("type")
        session_id = str(event.get("session_id", ""))
        if event_type == "session.started":
            audio = event.get("audio") or {}
            self.sessions[session_id] = SessionBuffer(
                sample_rate=int(audio.get("sample_rate", 24000)),
                language=event.get("language"),
            )
            return
        session = self.sessions.get(session_id)
        if session is None:
            return
        if event_type == "audio.append":
            audio = base64.b64decode(event.get("audio_base64", ""))
            session.diarization_pcm.extend(audio)
            session.asr_pcm.extend(audio)
            if getattr(self.backend, "supports_live_revisions", False):
                await self._process_revisable_audio(socket, session_id, session)
            else:
                target_bytes = int(session.sample_rate * 2 * self.window_seconds)
                stride_bytes = int(session.sample_rate * 2 * self.stride_seconds)
                while len(session.asr_pcm) >= target_bytes:
                    window = bytes(session.asr_pcm[:target_bytes])
                    await self._publish_analysis(
                        socket,
                        session_id,
                        session,
                        window,
                        session.asr_buffer_start_ms,
                        session.asr_buffer_start_ms + int(self.window_seconds * 1000),
                    )
                    del session.asr_pcm[:stride_bytes]
                    session.asr_buffer_start_ms += int(self.stride_seconds * 1000)
            self._schedule_diarization(socket, session_id, session)
        elif event_type == "session.finish":
            if session.asr_pcm:
                if getattr(self.backend, "supports_live_revisions", False):
                    await self._finalize_revisable_segment(socket, session_id, session)
                else:
                    window = bytes(session.asr_pcm)
                    session.asr_pcm.clear()
                    await self._publish_analysis(
                        socket,
                        session_id,
                        session,
                        window,
                        session.asr_buffer_start_ms,
                        session.asr_buffer_start_ms
                        + int(len(window) / 2 / session.sample_rate * 1000),
                    )
            if getattr(self.backend, "supports_live_revisions", False):
                await self._recheck_finalized_segments(socket, session_id, session)
            if session.diarization_task is not None:
                await session.diarization_task
            await self._run_diarization(socket, session_id, session, force=True)
            await socket.send(
                json.dumps(
                    {
                        "protocol_version": 1,
                        "type": "session.completed",
                        "session_id": session_id,
                    }
                )
            )
            self.sessions.pop(session_id, None)

    async def _publish_analysis(
        self,
        socket: ClientConnection,
        session_id: str,
        session: SessionBuffer,
        window: bytes,
        offset_ms: int,
        analyzed_until_ms: int,
    ) -> None:
        prompt = " ".join(session.recent_transcript)[-500:] or None
        result = await self.backend.analyze(
            window,
            session.sample_rate,
            session.language
            or (
                session.detected_language
                if getattr(self.backend, "locks_detected_language", True)
                else None
            ),
            offset_ms,
            prompt,
        )
        if session.language is None and session.detected_language is None:
            session.detected_language = result.detected_language
        for event in result.events:
            if int(event.get("end_ms", 0)) <= session.published_audio_ms:
                continue
            if int(event.get("start_ms", 0)) < session.published_audio_ms:
                words = [
                    word
                    for word in event.get("_words", [])
                    if int(word.get("end_ms", 0)) > session.published_audio_ms
                ]
                if not words:
                    continue
                event["start_ms"] = max(
                    session.published_audio_ms, int(words[0]["start_ms"])
                )
                event["end_ms"] = int(words[-1]["end_ms"])
                event["text"] = "".join(str(word["text"]) for word in words).strip()
                if not event["text"]:
                    continue
            event.pop("_words", None)
            event["segment_id"] = (
                f"seg_{int(event['start_ms'])}_{int(event['end_ms'])}"
            )
            event["protocol_version"] = 1
            event["session_id"] = session_id
            session.transcript_segments[str(event["segment_id"])] = dict(event)
            text = str(event.get("text", "")).strip()
            if text:
                session.recent_transcript.append(text)
                session.recent_transcript = session.recent_transcript[-12:]
            await socket.send(json.dumps(event, ensure_ascii=False))
        session.published_audio_ms = max(session.published_audio_ms, analyzed_until_ms)

    async def _process_revisable_audio(
        self, socket: ClientConnection, session_id: str, session: SessionBuffer
    ) -> None:
        duration_ms = self._pcm_duration_ms(session.asr_pcm, session.sample_rate)
        trailing_silence_ms = _trailing_silence_ms(session.asr_pcm, session.sample_rate)
        has_speech = _contains_speech(session.asr_pcm, session.sample_rate)
        should_finalize = has_speech and (
            trailing_silence_ms >= int(self.utterance_silence_seconds * 1000)
            or duration_ms >= int(self.max_utterance_seconds * 1000)
        )
        if should_finalize:
            await self._finalize_revisable_segment(socket, session_id, session)
            return
        if (
            has_speech
            and duration_ms >= int(self.live_update_seconds * 1000)
            and duration_ms - session.last_live_analysis_ms
            >= int(self.live_update_seconds * 1000)
        ):
            await self._publish_revisable_segment(
                socket, session_id, session, bytes(session.asr_pcm), is_final=False
            )
            session.last_live_analysis_ms = duration_ms

    async def _finalize_revisable_segment(
        self, socket: ClientConnection, session_id: str, session: SessionBuffer
    ) -> None:
        pcm = bytes(session.asr_pcm)
        duration_ms = self._pcm_duration_ms(pcm, session.sample_rate)
        if _contains_speech(pcm, session.sample_rate):
            await self._publish_revisable_segment(
                socket, session_id, session, pcm, is_final=True
            )
            segment_id = session.live_segment_id or f"seg_{session.asr_buffer_start_ms}"
            session.finalized_asr_segments.append(
                (segment_id, session.asr_buffer_start_ms, pcm)
            )
        session.asr_pcm.clear()
        session.asr_buffer_start_ms += duration_ms
        session.live_segment_id = None
        session.last_live_analysis_ms = 0

    async def _publish_revisable_segment(
        self,
        socket: ClientConnection,
        session_id: str,
        session: SessionBuffer,
        pcm: bytes,
        is_final: bool,
    ) -> None:
        segment_id = session.live_segment_id or f"seg_{session.asr_buffer_start_ms}"
        session.live_segment_id = segment_id
        prompt = " ".join(session.recent_transcript)[-500:] or None
        result = await self.backend.analyze(
            pcm,
            session.sample_rate,
            session.language,
            session.asr_buffer_start_ms,
            prompt,
        )
        session.detected_language = result.detected_language or session.detected_language
        if not result.events:
            return
        event = dict(result.events[-1])
        event.pop("_words", None)
        event["segment_id"] = segment_id
        event["is_final"] = is_final
        event["protocol_version"] = 1
        event["session_id"] = session_id
        previous = session.transcript_segments.get(segment_id)
        session.transcript_segments[segment_id] = dict(event)
        text = str(event.get("text", "")).strip()
        if text and (is_final or previous is None):
            if previous is not None:
                old_text = str(previous.get("text", "")).strip()
                if old_text in session.recent_transcript:
                    session.recent_transcript.remove(old_text)
            session.recent_transcript.append(text)
            session.recent_transcript = session.recent_transcript[-12:]
        await socket.send(json.dumps(event, ensure_ascii=False))

    async def _recheck_finalized_segments(
        self, socket: ClientConnection, session_id: str, session: SessionBuffer
    ) -> None:
        """Final correction pass with stable IDs so the app replaces draft text."""
        context: list[str] = []
        for segment_id, offset_ms, pcm in session.finalized_asr_segments:
            result = await self.backend.analyze(
                pcm,
                session.sample_rate,
                session.language,
                offset_ms,
                " ".join(context)[-500:] or None,
            )
            if not result.events:
                continue
            event = dict(result.events[-1])
            event.pop("_words", None)
            event.update(
                {
                    "segment_id": segment_id,
                    "is_final": True,
                    "protocol_version": 1,
                    "session_id": session_id,
                }
            )
            old = session.transcript_segments.get(segment_id) or {}
            if old.get("speaker"):
                event["speaker"] = old["speaker"]
            session.transcript_segments[segment_id] = dict(event)
            text = str(event.get("text", "")).strip()
            if text:
                context.append(text)
            await socket.send(json.dumps(event, ensure_ascii=False))

    @staticmethod
    def _pcm_duration_ms(pcm: bytes | bytearray, sample_rate: int) -> int:
        return int(len(pcm) / 2 / sample_rate * 1000)

    def _schedule_diarization(
        self, socket: ClientConnection, session_id: str, session: SessionBuffer
    ) -> None:
        if self.speaker_diarizer is None:
            return
        interval_bytes = int(
            session.sample_rate
            * 2
            * (self.diarization_interval_seconds + self.diarization_overlap_seconds)
        )
        if len(session.diarization_pcm) < interval_bytes:
            return
        if session.diarization_task is not None and not session.diarization_task.done():
            return
        session.diarization_task = asyncio.create_task(
            self._run_diarization(socket, session_id, session)
        )

    async def _run_diarization(
        self,
        socket: ClientConnection,
        session_id: str,
        session: SessionBuffer,
        force: bool = False,
    ) -> None:
        if self.speaker_diarizer is None:
            return
        snapshot = bytes(session.diarization_pcm)
        if not snapshot:
            return
        result = await self.speaker_diarizer.diarize(snapshot, session.sample_rate)
        absolute_result = result.offset(session.diarization_buffer_start_ms)
        session.speaker_tracker.update(absolute_result)
        if force:
            consumed_bytes = len(snapshot)
        else:
            overlap_bytes = int(
                session.sample_rate * 2 * self.diarization_overlap_seconds
            )
            consumed_bytes = max(0, len(snapshot) - overlap_bytes)
        if consumed_bytes > 0:
            del session.diarization_pcm[:consumed_bytes]
            consumed_frames = consumed_bytes // 2
            session.diarization_buffer_start_ms += int(
                consumed_frames / session.sample_rate * 1000
            )
        for segment_id, segment in list(session.transcript_segments.items()):
            assignment = session.speaker_tracker.speaker_for(
                int(segment["start_ms"]), int(segment["end_ms"])
            )
            if assignment is None:
                continue
            previous = segment.get("speaker") or {}
            if previous.get("cluster_id") == assignment.cluster_id:
                continue
            corrected = dict(segment)
            corrected["type"] = "speaker.corrected"
            corrected["session_id"] = session_id
            corrected["speaker"] = {
                "cluster_id": assignment.cluster_id,
                "person_id": None,
                "display_name": assignment.display_name,
                "confidence": round(assignment.confidence, 3),
            }
            session.transcript_segments[segment_id] = dict(corrected)
            await socket.send(json.dumps(corrected, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description="WakeOnCue Mac realtime processor")
    parser.add_argument(
        "--gateway",
        default=os.environ.get("WAKEONCUE_REALTIME_GATEWAY", "http://127.0.0.1:8090"),
    )
    parser.add_argument(
        "--diarization-model-dir",
        type=Path,
        default=Path(os.environ.get("WAKEONCUE_DIARIZATION_MODEL_DIR", ".local/models")),
    )
    parser.add_argument("--speaker-count", type=int, default=-1)
    parser.add_argument("--speaker-clustering-threshold", type=float, default=0.95)
    parser.add_argument("--diarization-interval", type=float, default=20.0)
    parser.add_argument("--diarization-overlap", type=float, default=10.0)
    parser.add_argument(
        "--token",
        default=os.environ.get("WAKEONCUE_REALTIME_API_TOKEN", "local-realtime-token"),
    )
    parser.add_argument("--processor-id", default=os.environ.get("HOSTNAME", "mac-local"))
    parser.add_argument(
        "--model",
        default=os.environ.get("WAKEONCUE_WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo"),
    )
    parser.add_argument(
        "--backend",
        choices=("qwen", "whisper"),
        default=os.environ.get("WAKEONCUE_ASR_BACKEND", "qwen"),
    )
    parser.add_argument(
        "--qwen-model",
        default=os.environ.get("WAKEONCUE_QWEN_MODEL", "Qwen/Qwen3-ASR-1.7B"),
    )
    parser.add_argument(
        "--qwen-device",
        default=os.environ.get("WAKEONCUE_QWEN_DEVICE", "auto"),
    )
    parser.add_argument(
        "--asr-glossary",
        default=os.environ.get("WAKEONCUE_ASR_GLOSSARY", "Codex GLM WakeOnCue Qwen3-ASR"),
    )
    args = parser.parse_args()
    segmentation_model = (
        args.diarization_model_dir
        / "sherpa-onnx-pyannote-segmentation-3-0"
        / "model.onnx"
    )
    embedding_model = (
        args.diarization_model_dir
        / "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
    )
    speaker_diarizer = None
    if segmentation_model.is_file() and embedding_model.is_file():
        speaker_diarizer = SherpaOnnxSpeakerDiarizer(
            segmentation_model,
            embedding_model,
            num_speakers=args.speaker_count,
            clustering_threshold=args.speaker_clustering_threshold,
        )
    else:
        print(
            "Speaker diarization models are missing; using Unknown speaker. "
            "Run scripts/download_diarization_models.py.",
            flush=True,
        )
    if args.backend == "qwen":
        backend: AnalysisBackend = Qwen3ASRBackend(
            args.qwen_model,
            device=args.qwen_device,
            glossary=args.asr_glossary,
        )
    else:
        backend = MLXWhisperBackend(args.model)
    processor = MacRealtimeProcessor(
        gateway_url=args.gateway,
        token=args.token,
        processor_id=args.processor_id,
        backend=backend,
        speaker_diarizer=speaker_diarizer,
        diarization_interval_seconds=args.diarization_interval,
        diarization_overlap_seconds=args.diarization_overlap,
    )
    asyncio.run(processor.run_forever())


if __name__ == "__main__":
    main()
