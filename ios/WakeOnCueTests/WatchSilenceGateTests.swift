import AVFoundation
import Foundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class WatchSilenceGateTests: XCTestCase {
  private static let rate = 16_000
  private static let frame = 320

  // MARK: - Decisions

  func testPauseShorterThanHoldStaysUntouched() throws {
    let input = Self.speech(seconds: 2) + Self.noise(seconds: 8, decibels: -60) + Self.speech(seconds: 2)
    let result = try Self.run(input)
    XCTAssertEqual(result.output, input)
    XCTAssertEqual(result.zeroed, 0)
  }

  func testLongSilenceIsZeroedOnlyInsideItsMargins() throws {
    let silenceStart = 2 * Self.rate
    let silenceEnd = 32 * Self.rate
    let input = Self.speech(seconds: 2) + Self.noise(seconds: 30, decibels: -60) + Self.speech(seconds: 2)
    let result = try Self.run(input)

    XCTAssertEqual(result.output.count, input.count)
    let zeroed = try XCTUnwrap(Self.zeroedRange(result.output))
    // The hold before and the pre-roll after are kept, give or take the frame that detects them.
    XCTAssertEqual(zeroed.lowerBound, silenceStart + 10 * Self.rate, accuracy: 2 * Self.frame)
    XCTAssertEqual(zeroed.upperBound, silenceEnd - 1 * Self.rate, accuracy: 2 * Self.frame)
    XCTAssertEqual(result.zeroed, 19 * Self.rate, accuracy: 4 * Self.frame)
    XCTAssertEqual(Array(result.output[..<zeroed.lowerBound]), Array(input[..<zeroed.lowerBound]))
    XCTAssertEqual(Array(result.output[zeroed.upperBound...]), Array(input[zeroed.upperBound...]))
  }

  func testQuietSpeechAboveTheFloorSurvivesWithItsPreRoll() throws {
    let quietStart = 20 * Self.rate
    // Just over the 6 dB margin above a -60 dBFS floor.
    let input = Self.noise(seconds: 20, decibels: -60) + Self.tone(seconds: 3, decibels: -50)
      + Self.noise(seconds: 2, decibels: -60)
    let result = try Self.run(input)
    let keptFrom = quietStart - 1 * Self.rate
    XCTAssertEqual(Array(result.output[keptFrom...]), Array(input[keptFrom...]))
  }

  func testSingleLoudFrameRestartsTheHold() throws {
    var input = Self.noise(seconds: 30, decibels: -60)
    let click = 15 * Self.rate
    input.replaceSubrange(click..<(click + Self.frame), with: Self.speech(samples: Self.frame))
    let result = try Self.run(input)
    let kept = (click - 1 * Self.rate)..<(click + 10 * Self.rate)
    XCTAssertEqual(Array(result.output[kept]), Array(input[kept]))
    XCTAssertGreaterThan(result.zeroed, 0)
  }

  func testNoisyRoomIsNeverZeroed() throws {
    // Louder than the -45 dBFS ceiling, however long it lasts.
    let input = Self.noise(seconds: 40, decibels: -38)
    let result = try Self.run(input)
    XCTAssertEqual(result.output, input)
    XCTAssertEqual(result.zeroed, 0)
  }

  func testLongQuietTalkNeverBecomesTheNoiseFloor() throws {
    // Syllable-like bursts: the gaps keep pulling the floor back down between them.
    let burst = Array(Self.tone(seconds: 1, decibels: -50)[..<(Self.rate * 3 / 10)])
    let gap = Array(Self.noise(seconds: 1, decibels: -60)[..<(Self.rate / 10)])
    let input = Array(repeatElement(burst + gap, count: 300).joined())
    let result = try Self.run(input)
    XCTAssertEqual(result.output, input)
    XCTAssertEqual(result.zeroed, 0)
  }

  func testFloorFollowsARoomThatGetsLouder() throws {
    let input = Self.noise(seconds: 5, decibels: -70) + Self.noise(seconds: 60, decibels: -55)
    XCTAssertGreaterThan(try Self.run(input).zeroed, 0)
  }

  func testInvalidConfigurationFallsBackToFullRecording() {
    var configuration = WatchSilenceGate.Configuration()
    configuration.preRollSeconds = 0
    XCTAssertNil(WatchSilenceGate(configuration: configuration))
    configuration = WatchSilenceGate.Configuration()
    configuration.frameSeconds = 0
    XCTAssertNil(WatchSilenceGate(configuration: configuration))
    configuration = WatchSilenceGate.Configuration()
    configuration.maximumThresholdDecibels = -80
    XCTAssertNil(WatchSilenceGate(configuration: configuration))
    XCTAssertNotNil(WatchSilenceGate())
  }

  // MARK: - Time positions

  func testBufferSizeDoesNotChangeTheResult() throws {
    let input = Self.speech(seconds: 1) + Self.noise(seconds: 15, decibels: -60) + Self.speech(seconds: 1)
    let whole = try Self.run(input, bufferSize: input.count).output
    XCTAssertEqual(try Self.run(input, bufferSize: 1).output, whole)
    XCTAssertEqual(try Self.run(input, bufferSize: 1_365).output, whole)
    XCTAssertEqual(try Self.run(input, bufferSize: 4_096).output, whole)
  }

  func testEverySampleKeepsItsPosition() throws {
    // A ramp above the ceiling: any lost, repeated, or reordered sample shows up.
    let input = (0..<(3 * Self.rate + 7)).map { Int16(2_000 + $0 % 20_000) }
    XCTAssertEqual(try Self.run(input, bufferSize: 1_000).output, input)
  }

  func testFlushBeforeTheFirstFrameReturnsThePartialFrame() throws {
    let input: [Int16] = [1, 2, 3]
    XCTAssertEqual(try Self.run(input).output, input)
  }

  func testFlushBeforeThePreRollIsFullReturnsEverythingInOrder() throws {
    let input = (0..<(Self.rate / 2 + 11)).map { Int16($0 % 30_000) }
    XCTAssertEqual(try Self.run(input, bufferSize: 512).output, input)
  }

  func testFlushKeepsTheHeldAudioEvenInsideASilence() throws {
    let input = Self.noise(seconds: 30, decibels: -60)
    let result = try Self.run(input)
    let lastSecond = input.count - 1 * Self.rate
    XCTAssertEqual(Array(result.output[lastSecond...]), Array(input[lastSecond...]))
    XCTAssertEqual(result.output.count, input.count)
  }

  // MARK: - Through the importer

  @MainActor
  func testZeroedSegmentsImportWithTheSameTimeline() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "watch-gate-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let layout = try RecordingFileLayout(root: root.appending(path: "data"))
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    let annotations = RecordingAnnotationsService(fileLayout: layout)
    let importer = WatchRecordingImporter(store: store, fileLayout: layout, annotations: annotations)

    // 30 s of speech, then 60 s of silence that zeroes most of segments 2 and 3 (20 s each).
    let segmentSeconds = 20
    let input = Self.speech(seconds: 30) + Self.noise(seconds: 60, decibels: -60)
    let output = try Self.run(input, bufferSize: 1_365).output
    XCTAssertEqual(output.count, input.count)

    let sessionID = UUID()
    let startedAt = Date(timeIntervalSince1970: 20_000)
    let pieces = stride(from: 0, to: output.count, by: segmentSeconds * Self.rate).map {
      Array(output[$0..<min($0 + segmentSeconds * Self.rate, output.count)])
    }
    var sizes: [Int] = []
    for (offset, piece) in pieces.enumerated() {
      let url = root.appending(path: "incoming-\(offset).m4a")
      try Self.writeAAC(piece, to: url)
      sizes.append(try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
      try WatchSessionInbox.stage(
        segmentURL: url,
        metadata: WatchSegmentMetadata(
          sessionID: sessionID, index: offset + 1, startedAt: startedAt,
          duration: Double(piece.count) / Double(Self.rate)),
        root: inbox
      )
    }
    XCTAssertLessThan(sizes[2], sizes[0] / 2, "A mostly zeroed segment should be much smaller")

    // One bookmark in speech and one inside the zeroed span.
    let summary = WatchSessionSummary(
      sessionID: sessionID,
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(90),
      segmentCount: pieces.count,
      bookmarks: [
        WatchSessionBookmark(position: 12, duration: 5, tag: .todo),
        WatchSessionBookmark(position: 65, tag: .important),
      ]
    )
    try WatchSessionInbox.stage(summary: summary, root: inbox)
    let imported = await importer.importPendingSessions(root: inbox)
    XCTAssertEqual(imported, [summary.recordingID])

    let recording = try await store.recording(id: summary.recordingID)
    XCTAssertEqual(recording.status, .completed)
    XCTAssertEqual(recording.duration, 90, accuracy: 0.5)
    let chunks = try await store.chunks(recordingID: summary.recordingID)
    XCTAssertEqual(chunks.map(\.index), Array(1...pieces.count))
    for (offset, chunk) in chunks.sorted(by: { $0.index < $1.index }).enumerated() {
      XCTAssertEqual(
        chunk.startedAt.timeIntervalSince(startedAt), Double(offset * segmentSeconds), accuracy: 0.5)
    }
    let bookmarks = annotations.annotations(for: summary.recordingID).bookmarks
    XCTAssertEqual(bookmarks.map(\.position).sorted(), [12, 65])

    let assembled = try layout.downloadedAudioURL(recordingID: summary.recordingID)
    let duration = try await AVURLAsset(url: assembled).load(.duration).seconds
    XCTAssertEqual(duration, 90, accuracy: 0.5)
  }

  // MARK: - Helpers

  private static func run(
    _ input: [Int16], bufferSize: Int = 1_365
  ) throws -> (output: [Int16], zeroed: Int) {
    var gate = try XCTUnwrap(WatchSilenceGate())
    var output: [Int16] = []
    output.reserveCapacity(input.count)
    input.withUnsafeBufferPointer { samples in
      var next = 0
      while next < samples.count {
        let end = min(next + bufferSize, samples.count)
        output += gate.process(UnsafeBufferPointer(rebasing: samples[next..<end]))
        next = end
      }
    }
    output += gate.flush()
    return (output, gate.zeroedSamples)
  }

  /// From the first run of at least one frame of zeros to the end of the last such run.
  private static func zeroedRange(_ samples: [Int16]) -> Range<Int>? {
    var first: Int?
    var last: Int?
    var run = 0
    for (index, sample) in samples.enumerated() {
      run = sample == 0 ? run + 1 : 0
      if run == frame, first == nil { first = index - frame + 1 }
      if run >= frame { last = index + 1 }
    }
    guard let first, let last else { return nil }
    return first..<last
  }

  /// Reproducible white noise; the level is the RMS in dBFS.
  private static func noise(seconds: Int, decibels: Double) -> [Int16] {
    var generator = SeededGenerator(state: UInt64(bitPattern: Int64(decibels * 100)) &+ 1)
    let peak = pow(10, decibels / 20) * 32_768 * 3.0.squareRoot()
    return (0..<(seconds * rate)).map { _ in
      let value = Double.random(in: -peak...peak, using: &generator)
      // Never exactly zero, so only the gate can produce a run of zeros.
      return Int16(value.rounded(value < 0 ? .down : .up))
    }
  }

  private static func tone(seconds: Int, decibels: Double) -> [Int16] {
    let peak = pow(10, decibels / 20) * 32_768 * 2.0.squareRoot()
    return (0..<(seconds * rate)).map { index in
      let value = peak * sin(Double(index) * 2 * .pi * 220 / Double(rate))
      return Int16(value.rounded(value < 0 ? .down : .up))
    }
  }

  private static func speech(seconds: Int) -> [Int16] { speech(samples: seconds * rate) }

  private static func speech(samples: Int) -> [Int16] {
    (0..<samples).map { index in
      let value = 8_000 * sin(Double(index) * 2 * .pi * 220 / Double(rate))
      return Int16(value.rounded(value < 0 ? .down : .up))
    }
  }

  private static func writeAAC(_ samples: [Int16], to url: URL) throws {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
      ],
      commonFormat: .pcmFormatInt16,
      interleaved: true
    )
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      buffer.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
  }
}

private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
