from __future__ import annotations

import unittest

from recording_service.speaker_diarization import (
    DiarizationResult,
    SpeakerTurn,
    StableSpeakerTracker,
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


if __name__ == "__main__":
    unittest.main()
