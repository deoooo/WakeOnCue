import XCTest

@testable import WakeOnCue

final class RecordingCaptureMeterTests: XCTestCase {
  func testReportsSustainedSilenceOnlyAfterThreshold() {
    var meter = RecordingCaptureMeter()
    let silence = [Float](repeating: 0, count: 2_400)

    for _ in 0..<79 {
      let update = consume(silence, with: &meter)
      XCTAssertNil(update?.sustainedSilenceDuration)
    }

    let thresholdUpdate = consume(silence, with: &meter)
    XCTAssertEqual(thresholdUpdate?.level, 0)
    XCTAssertEqual(thresholdUpdate?.sustainedSilenceDuration ?? 0, 8, accuracy: 0.001)
  }

  func testVoiceClearsSustainedSilenceAndProducesRealLevel() {
    var meter = RecordingCaptureMeter()
    let silence = [Float](repeating: 0, count: 2_400)
    let voice = [Float](repeating: 0.1, count: 2_400)

    for _ in 0..<80 { _ = consume(silence, with: &meter) }
    let update = consume(voice, with: &meter)

    XCTAssertNil(update?.sustainedSilenceDuration)
    XCTAssertEqual(update?.level ?? 0, 2.0 / 3.0, accuracy: 0.001)
  }

  private func consume(
    _ samples: [Float],
    with meter: inout RecordingCaptureMeter
  ) -> (level: Float, sustainedSilenceDuration: TimeInterval?)? {
    samples.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return nil }
      return meter.consume(
        samples: baseAddress,
        frameCount: buffer.count,
        sampleRate: AudioCaptureService.sampleRate
      )
    }
  }
}
