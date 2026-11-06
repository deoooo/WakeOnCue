import Foundation

/// Where a piece of audio came from: this Mac's microphone, or audio forwarded from the Watch
/// or iPhone. "meeting" remains readable from older libraries but is no longer recorded.
nonisolated enum AudioChannel: String, Codable, CaseIterable, Sendable {
  case microphone
  /// A legacy channel from the removed online-meeting recording. Kept so old rows decode.
  case meeting
  /// Audio forwarded from the Watch or the iPhone; `source` says which.
  case remote
}

/// Speakers are told apart as the user and someone else near the Mac.
nonisolated enum Speaker: String, Codable, Sendable {
  case me
  case other

  var label: String {
    switch self {
    case .me: "我"
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
  /// What the user sees as the source: "Mac 麦克风" or the device's name.
  var source: String
  var text: String
  /// The model that re-transcribed this sentence, or nil for Apple speech's live result.
  var refinedBy: String? = nil
  /// A person's name, or "说话人 2" when speakers are told apart without names.
  var speakerName: String? = nil
  /// How many times re-transcription failed.
  var refineAttempts: Int = 0
  /// When re-transcription may be tried again, if it failed before.
  var refineNext: Date? = nil
  /// The model that checked this sentence and chose to keep the live text.
  var refineCheckedBy: String? = nil

  /// What to show as the speaker: the name when known, otherwise 我 / 他人.
  var speakerLabel: String { speakerName ?? speaker.label }
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

/// A moment the user marked on the Watch or the iPhone ("记下刚才"), placed on the Mac's
/// timeline: `start` and `end` already include the device's clock offset.
nonisolated struct DeviceMark: Identifiable, Hashable, Sendable {
  enum Tag: String, Sendable {
    case todo
    case important
    case idea

    var label: String {
      switch self {
      case .todo: "待办"
      case .important: "重要"
      case .idea: "想法"
      }
    }
  }

  var id: String
  /// "watch" or "iphone".
  var source: String
  var recordingID: String
  var start: Date
  /// Nil for a point mark.
  var end: Date?
  var tag: Tag?
  var title: String?

  var sourceLabel: String { source == "watch" ? "Apple Watch" : "iPhone" }
  /// The marked stretch; a point mark counts as its own instant.
  var interval: DateInterval { DateInterval(start: start, end: max(start, end ?? start)) }
  /// What to call it: the title, the tag, or just "标记".
  var label: String { title ?? tag?.label ?? "标记" }
  /// Important and to-do marks steer the day summary.
  var isPriority: Bool { tag == .important || tag == .todo }
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
