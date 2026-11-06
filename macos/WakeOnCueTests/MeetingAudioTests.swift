@preconcurrency import AVFoundation
import Foundation
import XCTest

nonisolated final class MeetingAudioTests: XCTestCase {
  func testSilenceFloorIsMinusSeventyDBFS() {
    XCTAssertEqual(AudioLevel.silenceDBFS, -70)
    XCTAssertTrue(AudioLevel.isSilent(0))
    XCTAssertTrue(AudioLevel.isSilent(0.0001))
    XCTAssertTrue(AudioLevel.isSilent(AudioLevel.silenceThreshold * 0.99))
    XCTAssertFalse(AudioLevel.isSilent(AudioLevel.silenceThreshold * 1.01))
    XCTAssertFalse(AudioLevel.isSilent(0.01))
  }

  func testPeakUsesTheLargestAbsoluteSample() {
    XCTAssertEqual(AudioLevel.peak([Float]()), 0)
    XCTAssertEqual(AudioLevel.peak([0, 0, 0]), 0)
    XCTAssertEqual(AudioLevel.peak([0.001, -0.02, 0.003]), 0.02)
  }

  func testSilenceNeverOpensASegment() {
    var gate = MeetingAudioGate()
    for _ in 0..<30 {
      XCTAssertEqual(gate.process(duration: 1, silent: true), .skip)
    }
    XCTAssertFalse(gate.isOpen)
  }

  func testFirstSoundOpensWithPreRoll() {
    var gate = MeetingAudioGate()
    for _ in 0..<5 { _ = gate.process(duration: 0.1, silent: true) }
    XCTAssertEqual(gate.process(duration: 0.1, silent: false), .open(preroll: 2))
    XCTAssertTrue(gate.isOpen)
  }

  func testSixtySecondsOfSilenceClosesTheSegment() {
    var gate = MeetingAudioGate()
    XCTAssertEqual(gate.process(duration: 0.1, silent: false), .open(preroll: 2))
    for _ in 0..<30 { XCTAssertEqual(gate.process(duration: 1, silent: true), .append) }
    for _ in 0..<29 { XCTAssertEqual(gate.process(duration: 1, silent: true), .append) }
    XCTAssertTrue(gate.isOpen)
    XCTAssertEqual(gate.process(duration: 1, silent: true), .appendAndClose)
    XCTAssertFalse(gate.isOpen)
    XCTAssertEqual(gate.process(duration: 1, silent: true), .skip)
  }

  func testSoundAfterAClosedSegmentOpensAgain() {
    var gate = MeetingAudioGate()
    _ = gate.process(duration: 1, silent: false)
    for _ in 0..<60 { _ = gate.process(duration: 1, silent: true) }
    XCTAssertFalse(gate.isOpen)
    XCTAssertEqual(gate.process(duration: 0.1, silent: false), .open(preroll: 2))
    XCTAssertTrue(gate.isOpen)
  }

  func testActiveMeetingAppsNeedRecentSound() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertEqual(
      MeetingAudioActivity.activeApps(playingNames: ["飞书", "腾讯会议"], lastSoundAt: now.addingTimeInterval(-89), now: now),
      ["飞书", "腾讯会议"])
    XCTAssertEqual(
      MeetingAudioActivity.activeApps(playingNames: ["飞书"], lastSoundAt: now.addingTimeInterval(-91), now: now),
      [])
    XCTAssertEqual(MeetingAudioActivity.activeApps(playingNames: ["飞书"], lastSoundAt: nil, now: now), [])
  }

  func testActiveMeetingAppsKeepsOrderAndDropsDuplicates() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertEqual(
      MeetingAudioActivity.activeApps(playingNames: ["飞书", "腾讯会议", "飞书"], lastSoundAt: now, now: now),
      ["飞书", "腾讯会议"])
  }

  /// The gate decisions above, but through the real pipeline: silent buffers create no file,
  /// the first sound keeps about two seconds of pre-roll, and a minute of silence closes it.
  @MainActor func testSilentMeetingAudioCreatesNoFileAndKeepsPreRoll() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MeetingAudioTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let events = EventBox()
    let pipeline = ChannelPipeline(
      channel: .meeting, source: "飞书", directory: directory,
      onSegment: { events.append($0) }, onAudio: { _ in })
    pipeline.start()
    Thread.sleep(forTimeInterval: 0.1)

    for _ in 0..<10 { pipeline.append(buffer(seconds: 0.25, amplitude: 0)) }
    Thread.sleep(forTimeInterval: 0.4)
    XCTAssertTrue(events.opened.isEmpty, "silence must not open a segment")
    XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true)

    let beforeSound = Date()
    pipeline.append(buffer(seconds: 0.25, amplitude: 0.1))
    Thread.sleep(forTimeInterval: 0.6)
    let opened = try XCTUnwrap(events.opened.first)
    XCTAssertLessThan(opened.start, beforeSound)
    XCTAssertGreaterThan(opened.start, beforeSound.addingTimeInterval(-2.5), "about two seconds of pre-roll")
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: opened.path).path))

    pipeline.stop()
  }

  private func buffer(seconds: TimeInterval, amplitude: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let frames = AVAudioFrameCount(44_100 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    for index in 0..<Int(frames) {
      samples[index] = amplitude * sin(Float(index) * 2 * .pi * 440 / 44_100)
    }
    return buffer
  }
}

/// Collects segment events from the capture queue.
nonisolated private final class EventBox: @unchecked Sendable {
  private let lock = NSLock()
  private var openedEvents: [(path: String, start: Date)] = []
  private var closedEvents: [String] = []

  var opened: [(path: String, start: Date)] { lock.withLock { openedEvents } }
  var closed: [String] { lock.withLock { closedEvents } }

  func append(_ event: SegmentEvent) {
    lock.withLock {
      switch event {
      case .opened(_, let path, let start, _): openedEvents.append((path, start))
      case .closed(let path, _, _): closedEvents.append(path)
      case .failed: break
      }
    }
  }
}
