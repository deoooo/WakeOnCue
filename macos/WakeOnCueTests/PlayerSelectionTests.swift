import Foundation
import Testing

/// Playback must start at the segment that actually covers the requested moment. A Watch-only
/// stretch between two Mac recordings is the case that used to jump to the later Mac audio.
struct PlayerSelectionTests {
  private let day = Date(timeIntervalSince1970: 1_800_000_000)

  private func segment(_ channel: AudioChannel, _ startHour: Double, _ endHour: Double) -> AudioSegment {
    AudioSegment(
      id: Int64(startHour), channel: channel, start: day.addingTimeInterval(startHour * 3_600),
      end: day.addingTimeInterval(endHour * 3_600), path: "\(startHour).aac", source: "")
  }

  @Test func startsInsideTheSegmentThatCoversTheMoment() {
    let segments = [segment(.microphone, 9, 10), segment(.remote, 10, 11), segment(.microphone, 11, 12)]
    let chosen = Player.firstSegment(at: day.addingTimeInterval(10.5 * 3_600), in: segments)
    #expect(chosen?.channel == .remote)
  }

  @Test func fallsForwardOnlyWhenNothingCoversTheMoment() {
    let segments = [segment(.microphone, 9, 10), segment(.remote, 10, 11), segment(.microphone, 11, 12)]
    let chosen = Player.firstSegment(at: day.addingTimeInterval(11.5 * 3_600), in: segments)
    #expect(chosen?.channel == .microphone)
    #expect(Player.firstSegment(at: day.addingTimeInterval(12.5 * 3_600), in: segments) == nil)
  }
}
