import Foundation
import Observation
import WakeOnCueCore

/// Merges the microphone and system-audio sessions of one meeting into a single
/// time-ordered transcript. Segment IDs are unique per channel, and a higher revision
/// of the same segment replaces the earlier one.
@MainActor
@Observable
final class LiveTranscript {
  private(set) var segments: [RealtimeTranscriptEvent] = []
  private var byID: [String: RealtimeTranscriptEvent] = [:]

  func reset() {
    segments = []
    byID = [:]
  }

  func apply(_ event: RealtimeTranscriptEvent) {
    if let existing = byID[event.id], existing.revision >= event.revision { return }
    byID[event.id] = event
    segments = byID.values
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted { ($0.startMilliseconds, $0.id) < ($1.startMilliseconds, $1.id) }
  }

  static func speakerName(for event: RealtimeTranscriptEvent) -> String {
    if event.channel == .microphone || event.speaker?.personID == RealtimeSpeaker.selfPersonID {
      return String(localized: "Me")
    }
    if let speaker = event.speaker, speaker.clusterID.hasPrefix("speaker_"),
      let number = Int(speaker.clusterID.dropFirst("speaker_".count))
    {
      return String(localized: "Speaker \(number)")
    }
    return String(localized: "Others")
  }

  func plainText() -> String {
    segments.map { event in
      "[\(Self.timestamp(event.startMilliseconds))] \(Self.speakerName(for: event)): \(event.text)"
    }.joined(separator: "\n")
  }

  static func timestamp(_ milliseconds: Int) -> String {
    let seconds = milliseconds / 1_000
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}
