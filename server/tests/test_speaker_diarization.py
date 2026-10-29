from __future__ import annotations

import unittest

from recording_service.speaker_diarization import (
    DiarizationResult,
    SpeakerTurn,
    StableSpeakerTracker,
    Voiceprint,
    known_voiceprints_from_payload,
)


class StableSpeakerTrackerTest(unittest.TestCase):
    def test_keeps_clusters_stable_when_model_labels_swap(self) -> None:
        tracker = StableSpeakerTracker()
        tracker.update(
            [
                SpeakerTurn(0, 2000, "model_a"),
                SpeakerTurn(2100, 4000, "model_b"),
            ]
        )
        self.assertEqual(tracker.speaker_for(200, 1500).cluster_id, "speaker_1")
        self.assertEqual(tracker.speaker_for(2300, 3500).cluster_id, "speaker_2")

        tracker.update(
            [
                SpeakerTurn(0, 2000, "model_b"),
                SpeakerTurn(2100, 4000, "model_a"),
                SpeakerTurn(4100, 5200, "model_b"),
            ]
        )
        self.assertEqual(tracker.speaker_for(200, 1500).cluster_id, "speaker_1")
        self.assertEqual(tracker.speaker_for(2300, 3500).cluster_id, "speaker_2")
        self.assertEqual(tracker.speaker_for(4300, 5000).cluster_id, "speaker_1")

    def test_assigns_speaker_by_largest_transcript_overlap(self) -> None:
        tracker = StableSpeakerTracker()
        tracker.update(
            [
                SpeakerTurn(0, 900, "a"),
                SpeakerTurn(900, 2500, "b"),
            ]
        )
        assignment = tracker.speaker_for(500, 1800)
        self.assertEqual(assignment.cluster_id, "speaker_2")
        self.assertGreater(assignment.confidence, 0.6)

    def test_keeps_identity_across_non_overlapping_windows_using_embeddings(self) -> None:
        tracker = StableSpeakerTracker(embedding_match_threshold=0.8)
        tracker.update(
            DiarizationResult(
                turns=[
                    SpeakerTurn(0, 1000, "first_a"),
                    SpeakerTurn(1100, 2000, "first_b"),
                ],
                embeddings={"first_a": (1.0, 0.0), "first_b": (0.0, 1.0)},
            )
        )
        tracker.update(
            DiarizationResult(
                turns=[
                    SpeakerTurn(10_000, 11_000, "new_label_x"),
                    SpeakerTurn(11_100, 12_000, "new_label_y"),
                ],
                embeddings={
                    "new_label_x": (0.01, 0.99),
                    "new_label_y": (0.99, 0.01),
                },
            )
        )
        self.assertEqual(tracker.speaker_for(10_100, 10_900).cluster_id, "speaker_2")
        self.assertEqual(tracker.speaker_for(11_200, 11_900).cluster_id, "speaker_1")

    def test_matches_clusters_to_saved_voices_by_opaque_person_id(self) -> None:
        tracker = StableSpeakerTracker(
            known_voices={
                "self": Voiceprint(model="m", embedding=(1.0, 0.0)),
                "person_a": Voiceprint(model="m", embedding=(0.0, 1.0)),
                "person_b": Voiceprint(model="m", embedding=(-0.6, 0.8)),
            },
            identity_threshold=0.8,
        )
        tracker.update(
            DiarizationResult(
                turns=[
                    SpeakerTurn(0, 1000, "a"),
                    SpeakerTurn(1100, 2000, "b"),
                    SpeakerTurn(2100, 3000, "c"),
                ],
                embeddings={"a": (0.98, 0.1), "b": (0.05, 1.0), "c": (0.7, -0.7)},
            )
        )
        me = tracker.speaker_for(100, 900)
        self.assertEqual((me.cluster_id, me.person_id), ("speaker_1", "self"))
        self.assertEqual(tracker.speaker_for(1200, 1900).person_id, "person_a")
        unknown = tracker.speaker_for(2200, 2900)
        self.assertEqual((unknown.cluster_id, unknown.person_id), ("speaker_3", None))


class VoiceprintPayloadTest(unittest.TestCase):
    def test_round_trips_and_rejects_invalid_payloads(self) -> None:
        voiceprint = Voiceprint.from_payload({"model": "m", "embedding": [0.5, -1, 2]})
        self.assertEqual(voiceprint, Voiceprint(model="m", embedding=(0.5, -1.0, 2.0)))
        self.assertEqual(Voiceprint.from_payload(voiceprint.payload()), voiceprint)
        for invalid in (
            None,
            {"model": "m"},
            {"model": "", "embedding": [1.0]},
            {"model": "m", "embedding": []},
            {"model": "m", "embedding": [1.0, "x"]},
            {"model": "m", "embedding": [True]},
            {"model": "m", "embedding": [float("nan")]},
            {"model": "m", "embedding": [0.0] * 1025},
        ):
            self.assertIsNone(Voiceprint.from_payload(invalid), invalid)


    def test_parses_known_voiceprints(self) -> None:
        voices = known_voiceprints_from_payload(
            [{"person_id": "self", "model": "m", "embedding": [1.0, 0.0]}]
        )
        self.assertEqual(voices, {"self": Voiceprint(model="m", embedding=(1.0, 0.0))})
        self.assertEqual(known_voiceprints_from_payload([]), {})
        self.assertIsNone(known_voiceprints_from_payload([{"model": "m", "embedding": [1.0]}]))
        self.assertIsNone(known_voiceprints_from_payload({"person_id": "x"}))


if __name__ == "__main__":
    unittest.main()
