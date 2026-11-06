import Foundation

/// Decides when a meeting channel opens a segment file: never while silent, with a little
/// pre-roll so the first word is not clipped, and closed after a long silence so a muted app does
/// not fill the disk. Pure state; `ChannelPipeline` supplies the buffers and does the writing.
nonisolated struct MeetingAudioGate {
  /// Audio kept before the first audible buffer and written into the new segment.
  static let preRoll: TimeInterval = 2
  /// Silence this long closes the open segment.
  static let silenceClose: TimeInterval = 60

  enum Decision: Equatable {
    /// Silent and no file open: keep the buffer in the pre-roll ring, write nothing.
    case skip
    /// First sound after silence: open a file and write the pre-roll plus this buffer.
    case open(preroll: TimeInterval)
    /// File is open: append this buffer.
    case append
    /// The silence limit was reached: append this buffer, then close the file.
    case appendAndClose
  }

  private(set) var isOpen = false
  private var silentFor: TimeInterval = 0

  mutating func process(duration: TimeInterval, silent: Bool) -> Decision {
    if !isOpen {
      guard !silent else { return .skip }
      isOpen = true
      silentFor = 0
      return .open(preroll: Self.preRoll)
    }
    guard silent else {
      silentFor = 0
      return .append
    }
    silentFor += max(0, duration)
    guard silentFor >= Self.silenceClose else { return .append }
    isOpen = false
    silentFor = 0
    return .appendAndClose
  }

  mutating func reset() {
    isOpen = false
    silentFor = 0
  }
}
