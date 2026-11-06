import Foundation

/// The rule for "this microphone sentence happened during an online meeting": the meeting channel
/// had audio at that moment, and someone on the meeting channel spoke within a minute either side
/// (a real call always has the other side talking; a muted app has neither).
nonisolated enum VoiceMeetingSignal {
  static func isDuringMeeting(
    sentence: Sentence, meetingSegments: [AudioSegment], nearbySentences: [Sentence]
  ) -> Bool {
    let span = DateInterval(start: sentence.start, end: max(sentence.end, sentence.start))
    guard meetingSegments.contains(where: {
      $0.channel == .meeting && $0.start < span.end && max($0.start, $0.end) > span.start
    }) else { return false }
    return hasNearbyMeetingSentence(sentence: sentence, nearbySentences: nearbySentences)
  }

  /// The other half of the rule: the meeting channel has a transcribed sentence within a minute
  /// either side. Kept separate so it can be used with the pipeline's exact audible history.
  static func hasNearbyMeetingSentence(sentence: Sentence, nearbySentences: [Sentence]) -> Bool {
    let around = DateInterval(
      start: sentence.start.addingTimeInterval(-60), end: sentence.end.addingTimeInterval(60))
    return nearbySentences.contains {
      $0.channel == .meeting && $0.start >= around.start && $0.start < around.end
    }
  }
}
