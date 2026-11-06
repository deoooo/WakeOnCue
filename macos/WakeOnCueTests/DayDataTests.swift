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
}
