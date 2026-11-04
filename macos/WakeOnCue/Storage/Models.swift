import Foundation

/// Where a piece of audio came from. Phase 1 has the Mac microphone and the meeting apps.
nonisolated enum AudioChannel: String, Codable, CaseIterable, Sendable {
  case microphone
  case meeting
  /// Audio forwarded from the Watch or the iPhone; `source` says which.
  case remote
}

/// Phase 1 tells speakers apart only by channel: the user, the meeting app, or someone
/// else near the Mac.
nonisolated enum Speaker: String, Codable, Sendable {
  case me
  case remote
  case other

  var label: String {
    switch self {
    case .me: "我"
    case .remote: "会议对方"
    case .other: "他人"
    }
  }
}

nonisolated struct Sentence: Identifiable, Hashable, Sendable {
  var id: Int64
  var start: Date
  var end: Date
  var channel: AudioChannel
  var speaker: Speaker
  /// What the user sees as the source: "Mac 麦克风" or the meeting app's name.
  var source: String
  var text: String
  /// The model that re-transcribed this sentence, or nil for Apple speech's live result.
  var refinedBy: String? = nil
}

nonisolated struct AudioSegment: Identifiable, Hashable, Sendable {
  var id: Int64
  var channel: AudioChannel
  var start: Date
  var end: Date
  var path: String
  var source: String
}

/// A time range the user marked private or deleted. Deleted ranges stay restorable for 30 days.
nonisolated struct TimeMark: Identifiable, Hashable, Sendable {
  enum Kind: String, Sendable {
    case privateRange = "private"
    case deleted
    /// Recording was paused; audio from other devices in this time is dropped too.
    case paused
  }

  var id: Int64
  var kind: Kind
  var start: Date
  var end: Date
  var createdAt: Date

  func covers(_ date: Date) -> Bool { date >= start && date < end }
}

/// Why this Mac could not record during a range, shown on the hour and in the banner.
nonisolated struct CaptureGap: Identifiable, Hashable, Sendable {
  var id: Int64
  var start: Date
  var end: Date?
  var reason: String
}

/// A line of a generated summary, with the sentences it is based on.
nonisolated struct CitedLine: Codable, Hashable, Sendable {
  var text: String
  var cites: [Int64]
}

nonisolated struct HourSummary: Hashable, Sendable {
  var hourStart: Date
  var summary: String
  var keySentenceIDs: [Int64]
  var generatedAt: Date
  /// False while the hour is still running or its summary could not be generated.
  var isFinal: Bool
  /// Which engine wrote it, e.g. "本机 Apple 智能" or "网关 gpt-4o-mini".
  var engine: String?
}

nonisolated struct DaySummary: Hashable, Sendable {
  var day: Date
  var headline: CitedLine
  var details: [CitedLine]
  var generatedAt: Date
  var engine: String?
}

nonisolated struct Attendee: Codable, Hashable, Sendable {
  var name: String
  var email: String?
}

nonisolated struct Meeting: Identifiable, Hashable, Sendable {
  enum Origin: String, Sendable {
    case calendar
    case meetingAudio
    case manual
  }

  var id: Int64
  var title: String
  var start: Date
  var end: Date
  var origin: Origin
  var calendarEventID: String?
  var calendarStart: Date?
  var calendarEnd: Date?
  var app: String?
  var attendees: [Attendee]
  var points: [CitedLine]
  var minutes: String?
  var pointsGeneratedAt: Date?
  /// True once the user moved the start or end; detection then leaves the range alone.
  var userAdjusted: Bool
  /// Which engine wrote the key points.
  var pointsEngine: String? = nil
}
