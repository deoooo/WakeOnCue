from __future__ import annotations

import asyncio
from dataclasses import dataclass
import math
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True)
class SpeakerTurn:
    start_ms: int
    end_ms: int
    source_label: str


@dataclass(frozen=True)
class StableSpeakerTurn:
    start_ms: int
    end_ms: int
    cluster_id: str


@dataclass(frozen=True)
class SpeakerAssignment:
    cluster_id: str
    display_name: str
    confidence: float


@dataclass(frozen=True)
class DiarizationResult:
    turns: list[SpeakerTurn]
    embeddings: dict[str, tuple[float, ...]]

    def offset(self, milliseconds: int) -> DiarizationResult:
        return DiarizationResult(
            turns=[
                SpeakerTurn(
                    start_ms=turn.start_ms + milliseconds,
                    end_ms=turn.end_ms + milliseconds,
                    source_label=turn.source_label,
                )
                for turn in self.turns
            ],
            embeddings=self.embeddings,
        )


class SpeakerDiarizer(Protocol):
    async def diarize(self, pcm: bytes, sample_rate: int) -> DiarizationResult: ...


class StableSpeakerTracker:
    """Keeps processor-local labels stable across overlapping diarization windows."""

    def __init__(self, embedding_match_threshold: float = 0.45) -> None:
        self.turns: list[StableSpeakerTurn] = []
        self.next_cluster_index = 1
        self.embedding_match_threshold = embedding_match_threshold
        self.cluster_embeddings: dict[str, tuple[float, ...]] = {}
        self.cluster_embedding_counts: dict[str, int] = {}

    def update(self, result: DiarizationResult | list[SpeakerTurn]) -> None:
        if isinstance(result, list):
            result = DiarizationResult(turns=result, embeddings={})
        turns = result.turns
        source_labels = sorted(
            {turn.source_label for turn in turns},
            key=lambda label: min(
                turn.start_ms for turn in turns if turn.source_label == label
            ),
        )
        mapping = self._match_existing_embeddings(result.embeddings)
        overlap_mapping = self._match_existing_clusters(turns, source_labels)
        claimed = set(mapping.values())
        for source_label, cluster_id in overlap_mapping.items():
            if source_label not in mapping and cluster_id not in claimed:
                mapping[source_label] = cluster_id
                claimed.add(cluster_id)
        for source_label in source_labels:
            if source_label not in mapping:
                mapping[source_label] = f"speaker_{self.next_cluster_index}"
                self.next_cluster_index += 1
        self._update_cluster_embeddings(mapping, result.embeddings)
        self.turns = [
            StableSpeakerTurn(
                start_ms=turn.start_ms,
                end_ms=turn.end_ms,
                cluster_id=mapping[turn.source_label],
            )
            for turn in turns
        ]

    def speaker_for(self, start_ms: int, end_ms: int) -> SpeakerAssignment | None:
        duration = max(1, end_ms - start_ms)
        overlaps: dict[str, int] = {}
        for turn in self.turns:
            overlap = _overlap(start_ms, end_ms, turn.start_ms, turn.end_ms)
            if overlap > 0:
                overlaps[turn.cluster_id] = overlaps.get(turn.cluster_id, 0) + overlap
        if not overlaps:
            return None
        cluster_id, overlap = max(overlaps.items(), key=lambda item: item[1])
        number = cluster_id.removeprefix("speaker_")
        return SpeakerAssignment(
            cluster_id=cluster_id,
            display_name=f"Speaker {number}",
            confidence=min(1.0, overlap / duration),
        )

    def _match_existing_clusters(
        self, turns: list[SpeakerTurn], source_labels: list[str]
    ) -> dict[str, str]:
        scores: list[tuple[int, str, str]] = []
        existing_clusters = {turn.cluster_id for turn in self.turns}
        for source_label in source_labels:
            source_turns = [turn for turn in turns if turn.source_label == source_label]
            for cluster_id in existing_clusters:
                score = sum(
                    _overlap(
                        source.start_ms,
                        source.end_ms,
                        existing.start_ms,
                        existing.end_ms,
                    )
                    for source in source_turns
                    for existing in self.turns
                    if existing.cluster_id == cluster_id
                )
                if score > 0:
                    scores.append((score, source_label, cluster_id))
        mapping: dict[str, str] = {}
        claimed_clusters: set[str] = set()
        for _, source_label, cluster_id in sorted(scores, reverse=True):
            if source_label in mapping or cluster_id in claimed_clusters:
                continue
            mapping[source_label] = cluster_id
            claimed_clusters.add(cluster_id)
        return mapping

    def _match_existing_embeddings(
        self, source_embeddings: dict[str, tuple[float, ...]]
    ) -> dict[str, str]:
        scores = [
            (_cosine_similarity(source, existing), source_label, cluster_id)
            for source_label, source in source_embeddings.items()
            for cluster_id, existing in self.cluster_embeddings.items()
        ]
        mapping: dict[str, str] = {}
        claimed_clusters: set[str] = set()
        for score, source_label, cluster_id in sorted(scores, reverse=True):
            if score < self.embedding_match_threshold:
                continue
            if source_label in mapping or cluster_id in claimed_clusters:
                continue
            mapping[source_label] = cluster_id
            claimed_clusters.add(cluster_id)
        return mapping

    def _update_cluster_embeddings(
        self,
        mapping: dict[str, str],
        source_embeddings: dict[str, tuple[float, ...]],
    ) -> None:
        for source_label, embedding in source_embeddings.items():
            cluster_id = mapping.get(source_label)
            if cluster_id is None:
                continue
            existing = self.cluster_embeddings.get(cluster_id)
            count = self.cluster_embedding_counts.get(cluster_id, 0)
            if existing is None or len(existing) != len(embedding):
                combined = embedding
                count = 0
            else:
                combined = tuple(
                    (old * count + new) / (count + 1)
                    for old, new in zip(existing, embedding, strict=True)
                )
            self.cluster_embeddings[cluster_id] = combined
            self.cluster_embedding_counts[cluster_id] = count + 1


class SherpaOnnxSpeakerDiarizer:
    def __init__(
        self,
        segmentation_model: Path,
        embedding_model: Path,
        num_speakers: int = -1,
        clustering_threshold: float = 0.95,
    ) -> None:
        try:
            import sherpa_onnx  # type: ignore[import-not-found]
        except ImportError as error:
            raise RuntimeError(
                "sherpa-onnx is not installed. Install the mac-processor extra."
            ) from error
        if not segmentation_model.is_file() or not embedding_model.is_file():
            raise RuntimeError("speaker diarization model files are missing")
        config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
            segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
                pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                    model=str(segmentation_model)
                )
            ),
            embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
                model=str(embedding_model)
            ),
            clustering=sherpa_onnx.FastClusteringConfig(
                num_clusters=num_speakers,
                threshold=clustering_threshold,
            ),
            min_duration_on=0.3,
            min_duration_off=0.5,
        )
        if not config.validate():
            raise RuntimeError("invalid sherpa-onnx speaker diarization configuration")
        self._diarizer = sherpa_onnx.OfflineSpeakerDiarization(config)
        embedding_config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(embedding_model),
            num_threads=2,
            debug=False,
            provider="cpu",
        )
        if not embedding_config.validate():
            raise RuntimeError("invalid sherpa-onnx speaker embedding configuration")
        self._embedding_extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
            embedding_config
        )

    async def diarize(self, pcm: bytes, sample_rate: int) -> DiarizationResult:
        return await asyncio.to_thread(self._diarize_sync, pcm, sample_rate)

    def _diarize_sync(self, pcm: bytes, sample_rate: int) -> DiarizationResult:
        import numpy as np

        samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        target_rate = int(self._diarizer.sample_rate)
        if sample_rate != target_rate and len(samples) > 0:
            target_count = int(len(samples) * target_rate / sample_rate)
            positions = np.linspace(0, len(samples) - 1, target_count)
            samples = np.interp(positions, np.arange(len(samples)), samples).astype(
                np.float32
            )
        result = self._diarizer.process(samples).sort_by_start_time()
        turns = [
            SpeakerTurn(
                start_ms=int(segment.start * 1000),
                end_ms=int(segment.end * 1000),
                source_label=str(segment.speaker),
            )
            for segment in result
        ]
        embeddings: dict[str, tuple[float, ...]] = {}
        for source_label in {turn.source_label for turn in turns}:
            pieces = [
                samples[
                    max(0, int(turn.start_ms * target_rate / 1000)) : min(
                        len(samples), int(turn.end_ms * target_rate / 1000)
                    )
                ]
                for turn in turns
                if turn.source_label == source_label
            ]
            pieces = [piece for piece in pieces if len(piece) > 0]
            if not pieces:
                continue
            speaker_audio = np.concatenate(pieces)
            stream = self._embedding_extractor.create_stream()
            stream.accept_waveform(target_rate, speaker_audio)
            stream.input_finished()
            if self._embedding_extractor.is_ready(stream):
                embeddings[source_label] = tuple(
                    float(value) for value in self._embedding_extractor.compute(stream)
                )
        return DiarizationResult(turns=turns, embeddings=embeddings)


def _overlap(start_a: int, end_a: int, start_b: int, end_b: int) -> int:
    return max(0, min(end_a, end_b) - max(start_a, start_b))


def _cosine_similarity(left: tuple[float, ...], right: tuple[float, ...]) -> float:
    if not left or len(left) != len(right):
        return -1
    dot = sum(a * b for a, b in zip(left, right, strict=True))
    left_norm = math.sqrt(sum(value * value for value in left))
    right_norm = math.sqrt(sum(value * value for value in right))
    if left_norm == 0 or right_norm == 0:
        return -1
    return dot / (left_norm * right_norm)
