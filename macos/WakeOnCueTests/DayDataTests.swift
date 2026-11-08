import Foundation
import Testing

/// The day header counts actual audio, including Watch/iPhone audio that fills a Mac gap.
struct DayDataTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func segment(_ channel: AudioChannel, _ from: TimeInterval, _ to: TimeInterval) -> AudioSegment {
    AudioSegment(
      id: Int64(from), channel: channel, start: start.addingTimeInterval(from),
      end: start.addingTimeInterval(to), path: "\(from).aac", source: "")
  }

  @Test func recordedTimeMergesOverlappingMacAndRemoteAudio() {
    let segments = [
      segment(.microphone, 0, 3_600),
      segment(.remote, 1_800, 5_400),
      segment(.microphone, 7_200, 9_000),
    ]
    let interval = DateInterval(start: start, duration: 86_400)
    #expect(DayData.recordedDuration(segments: segments, in: interval) == 7_200)
  }

  /// 2026-11-07 19:28: a segment opened at 19:25:00 by the sample clock, a moment before the
  /// wall clock got there, ended "now" before it started and `DateInterval` trapped.
  @Test func segmentEndingBeforeItStartsDoesNotCrash() {
    let ahead = AudioSegment(
      id: 1, channel: .microphone, start: start.addingTimeInterval(300), end: start.addingTimeInterval(298),
      path: "a.aac", source: "")
    let interval = DateInterval(start: start, duration: 86_400)
    #expect(DayData.recordedDuration(segments: [segment(.microphone, 0, 300), ahead], in: interval) == 300)
  }
}
