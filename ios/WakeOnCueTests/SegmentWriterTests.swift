import AVFoundation
import Foundation
import XCTest

@testable import WakeOnCue

final class SegmentWriterTests: XCTestCase {
  private let format = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: SegmentWriter.sampleRate,
    channels: 1,
    interleaved: true
  )!
  private var directory: URL!
  private var faults: SegmentFaults!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    faults = SegmentFaults()
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  // MARK: - Budget

  func testSingleHiccupDoesNotExhaustBudget() {
    var budget = SegmentFailureBudget()
    budget.recordFailure(seconds: 0.25)
    XCTAssertFalse(budget.isExhausted)
    budget.recordSuccess(seconds: 60)
    XCTAssertEqual(budget.failedSeconds, 0)
  }

  func testSustainedFailureExhaustsBudget() {
    var budget = SegmentFailureBudget()
    budget.recordFailure(seconds: SegmentFailureBudget.limitSeconds - 0.25)
    XCTAssertFalse(budget.isExhausted)
    budget.recordFailure(seconds: 0.25)
    XCTAssertTrue(budget.isExhausted)
  }

  func testAlternatingFailuresStillExhaustBudget() {
    var budget = SegmentFailureBudget()
    var rounds = 0
    while !budget.isExhausted, rounds < 1_000 {
      budget.recordFailure(seconds: 0.25)
      budget.recordSuccess(seconds: 0.25)
      rounds += 1
    }
    XCTAssertTrue(budget.isExhausted)
  }

  func testRareFailuresNeverExhaustBudget() {
    var budget = SegmentFailureBudget()
    // One short failure every minute, for a day.
    for _ in 0..<(24 * 60) {
      budget.recordFailure(seconds: 0.25)
      budget.recordSuccess(seconds: 60)
    }
    XCTAssertFalse(budget.isExhausted)
    XCTAssertEqual(budget.failedSeconds, 0)
  }

  // MARK: - Writer

  func testRolloverNumbersSegmentsInOrderAndTheyAreReadable() throws {
    var writer = try makeWriter()
    let finished = write(seconds: 2.5, to: &writer)

    XCTAssertEqual(finished.map(\.0.index), [1, 2])
    XCTAssertEqual(writer.completedCount, 2)
    XCTAssertFalse(writer.hasFailed)
    for (metadata, url) in finished {
      XCTAssertEqual(metadata.duration, 1, accuracy: 0.3)
      XCTAssertGreaterThan(try AVAudioFile(forReading: url).length, 0)
    }
    let last = try XCTUnwrap(writer.close())
    XCTAssertEqual(last.0.index, 3)
    XCTAssertEqual(writer.completedCount, 3)
  }

  func testFailedOpenKeepsAudioInCurrentSegmentAndDoesNotSkipAnIndex() throws {
    var writer = try makeWriter()
    faults.failOpens = true
    XCTAssertTrue(write(seconds: 2, to: &writer).isEmpty)
    XCTAssertFalse(writer.hasFailed)
    XCTAssertEqual(writer.recordedDuration, 2, accuracy: 0.01)

    faults.failOpens = false
    let finished = write(seconds: 0.25, to: &writer)

    XCTAssertEqual(finished.map(\.0.index), [1])
    // Everything written during the failed opens is in the one segment.
    XCTAssertEqual(try XCTUnwrap(finished.first).0.duration, 2.25, accuracy: 0.01)
    let measured = try AVAudioFile(forReading: XCTUnwrap(finished.first).1)
    XCTAssertEqual(Double(measured.length) / SegmentWriter.sampleRate, 2.25, accuracy: 0.3)
    _ = write(seconds: 0.25, to: &writer)
    XCTAssertEqual(try XCTUnwrap(writer.close()).0.index, 2)
    XCTAssertEqual(writer.completedCount, 2)
  }

  func testPersistentOpenFailureFailsAndSavesEverythingWritten() throws {
    var writer = try makeWriter()
    XCTAssertEqual(write(seconds: 1, to: &writer).map(\.0.index), [1])

    faults.failOpens = true
    _ = write(seconds: 1 + SegmentFailureBudget.limitSeconds * 2, to: &writer, untilFailed: true)
    XCTAssertTrue(writer.hasFailed)

    let last = try XCTUnwrap(writer.close())
    XCTAssertEqual(last.0.index, 2)
    XCTAssertGreaterThan(last.0.duration, SegmentFailureBudget.limitSeconds)
    XCTAssertGreaterThan(try AVAudioFile(forReading: last.1).length, 0)
    XCTAssertEqual(writer.completedCount, 2)
    XCTAssertEqual(segmentFiles(), ["segment-0001.m4a", "segment-0002.m4a"])
  }

  func testPersistentWriteFailureFailsAndKeepsCompletedSegments() throws {
    var writer = try makeWriter()
    XCTAssertEqual(write(seconds: 1, to: &writer).map(\.0.index), [1])
    XCTAssertEqual(write(seconds: 0.5, to: &writer).count, 0)
    let before = writer.recordedDuration

    faults.failWrites = true
    _ = write(seconds: SegmentFailureBudget.limitSeconds * 2, to: &writer, untilFailed: true)
    XCTAssertTrue(writer.hasFailed)
    XCTAssertEqual(writer.recordedDuration, before)

    let last = try XCTUnwrap(writer.close())
    XCTAssertEqual(last.0.index, 2)
    XCTAssertEqual(writer.completedCount, 2)
  }

  func testWriterTakesNoMoreAudioOnceFailed() throws {
    var writer = try makeWriter()
    faults.failWrites = true
    _ = write(seconds: SegmentFailureBudget.limitSeconds * 2, to: &writer, untilFailed: true)
    XCTAssertTrue(writer.hasFailed)
    let calls = faults.writeCalls

    faults.failWrites = false
    XCTAssertTrue(write(seconds: 2, to: &writer).isEmpty)
    XCTAssertEqual(faults.writeCalls, calls)
  }

  func testBriefWriteFailureDoesNotEndTheRecording() throws {
    var writer = try makeWriter()
    faults.failWrites = true
    _ = write(seconds: 0.5, to: &writer)
    faults.failWrites = false

    XCTAssertEqual(write(seconds: 1, to: &writer).map(\.0.index), [1])
    XCTAssertFalse(writer.hasFailed)
  }

  func testFailureWithNothingWrittenLeavesNoSegment() throws {
    var writer = try makeWriter()
    faults.failWrites = true
    _ = write(seconds: SegmentFailureBudget.limitSeconds * 2, to: &writer, untilFailed: true)

    XCTAssertNil(writer.close())
    XCTAssertEqual(writer.completedCount, 0)
    XCTAssertEqual(segmentFiles(), [])
  }

  func testUnreadableSegmentAtRolloverIsNotCountedAndFailsTheWriter() throws {
    var writer = try makeWriter()
    XCTAssertEqual(write(seconds: 1, to: &writer).map(\.0.index), [1])

    faults.corruptOnClose = true
    XCTAssertTrue(write(seconds: 1, to: &writer).isEmpty)

    XCTAssertTrue(writer.hasFailed)
    XCTAssertNil(writer.close())
    XCTAssertEqual(writer.completedCount, 1)
    XCTAssertEqual(segmentFiles(), ["segment-0001.m4a"])
  }

  func testUnreadableLastSegmentIsNotCounted() throws {
    var writer = try makeWriter()
    XCTAssertEqual(write(seconds: 1, to: &writer).map(\.0.index), [1])
    _ = write(seconds: 0.5, to: &writer)

    faults.corruptOnClose = true
    XCTAssertNil(writer.close())
    XCTAssertEqual(writer.completedCount, 1)
    XCTAssertEqual(segmentFiles(), ["segment-0001.m4a"])
  }

  func testOpenFailureAtStartThrowsAndLeavesNoFile() {
    var writer = SegmentWriter(
      sessionID: UUID(), directory: directory, segmentDuration: 1, makeFile: faults.factory)
    faults.failOpens = true
    XCTAssertThrowsError(try writer.openNext(format: format))
    XCTAssertEqual(segmentFiles(), [])
  }

  // MARK: - Helpers

  private func makeWriter() throws -> SegmentWriter {
    var writer = SegmentWriter(
      sessionID: UUID(), directory: directory, segmentDuration: 1, makeFile: faults.factory)
    try writer.openNext(format: format)
    return writer
  }

  /// Writes quarter-second tone buffers, which is about the size the recorder writes.
  @discardableResult
  private func write(
    seconds: TimeInterval, to writer: inout SegmentWriter, untilFailed: Bool = false
  ) -> [(WatchSegmentMetadata, URL)] {
    let frames: AVAudioFrameCount = 4_000
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
      buffer.int16ChannelData![0][index] = Int16(8_000 * sin(Double(index) * 2 * .pi * 440 / 16_000))
    }
    var finished: [(WatchSegmentMetadata, URL)] = []
    for _ in 0..<Int((seconds / 0.25).rounded()) {
      if let segment = writer.write(buffer, format: format) { finished.append(segment) }
      if untilFailed, writer.hasFailed { break }
    }
    return finished
  }

  private func segmentFiles() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return files.filter { $0.hasSuffix(".m4a") }.sorted()
  }
}

/// Real AAC files that fail on demand. Shared by reference because the writer is a value type.
private final class SegmentFaults {
  var failOpens = false
  var failWrites = false
  var corruptOnClose = false
  var writeCalls = 0

  struct Injected: Error {}

  var factory: SegmentWriter.FileFactory {
    { [self] url, format in
      if failOpens { throw Injected() }
      return FaultyFile(
        url: url, base: try SegmentWriter.makeAACFile(url: url, format: format), faults: self)
    }
  }
}

private final class FaultyFile: SegmentFile {
  private let url: URL
  private let base: any SegmentFile
  private let faults: SegmentFaults

  init(url: URL, base: any SegmentFile, faults: SegmentFaults) {
    self.url = url
    self.base = base
    self.faults = faults
  }

  func write(from buffer: AVAudioPCMBuffer) throws {
    faults.writeCalls += 1
    if faults.failWrites { throw SegmentFaults.Injected() }
    try base.write(from: buffer)
  }

  func close() {
    base.close()
    if faults.corruptOnClose { try? Data("not audio".utf8).write(to: url) }
  }
}
