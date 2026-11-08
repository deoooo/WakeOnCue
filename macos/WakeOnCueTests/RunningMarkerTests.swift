import Foundation
import Testing

struct RunningMarkerTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func runningOrQuitNormallyIsLeftAlone() {
    #expect(RunningMarker.decide(markerPID: 123, isRunning: true, recentRelaunches: [], now: now) == .nothing)
    #expect(RunningMarker.decide(markerPID: nil, isRunning: false, recentRelaunches: [], now: now) == .nothing)
  }

  @Test func markerWithoutItsProcessIsRelaunched() {
    #expect(RunningMarker.decide(markerPID: 123, isRunning: false, recentRelaunches: [], now: now) == .relaunch)
    // Older relaunches do not count toward a crash loop.
    let old = (1...5).map { now.addingTimeInterval(-RunningMarker.loopWindow - Double($0)) }
    #expect(RunningMarker.decide(markerPID: 123, isRunning: false, recentRelaunches: old, now: now) == .relaunch)
  }

  @Test func crashLoopStops() {
    let recent = (1...RunningMarker.loopLimit).map { now.addingTimeInterval(-Double($0) * 60) }
    #expect(RunningMarker.decide(markerPID: 123, isRunning: false, recentRelaunches: recent, now: now) == .givingUp)
  }

  @Test func ownProcessIsRecognizedOnlyWhenItIsTheApp() {
    // The test runner is alive but is not WakeOnCue.app; a dead PID is not running.
    #expect(!RunningMarker.isAppProcess(getpid()))
    #expect(!RunningMarker.isAppProcess(0))
  }
}

/// A segment still being written ends "now", but never before it starts.
@MainActor
struct OpenSegmentTests {
  @Test func openSegmentAheadOfTheClockEndsAtItsStart() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "OpenSegmentTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try Store(directory: directory)
    let start = Date().addingTimeInterval(1.5)
    _ = store.insertSegment(channel: .microphone, start: start, path: "x.aac", source: "Mac 麦克风")
    let found = store.segments(overlapping: DateInterval(start: start.addingTimeInterval(-60), duration: 3_600))
    let segment = try #require(found.first)
    #expect(segment.end >= segment.start)
  }
}
