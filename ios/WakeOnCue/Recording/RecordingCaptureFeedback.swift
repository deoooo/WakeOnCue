import Foundation

enum RecordingCapturePauseReason: Sendable, Equatable {
  case userPaused
  case systemInterruption
}

struct RecordingCaptureFeedback: Sendable, Equatable {
  static let idle = RecordingCaptureFeedback(
    normalizedInputLevel: 0,
    inputSourceName: nil,
    sustainedSilenceDuration: nil,
    pauseReason: nil
  )

  /// A perceptual 0...1 meter value derived from the microphone's PCM samples.
  let normalizedInputLevel: Float
  /// The active audio-session input, such as "iPhone Microphone" or an AirPods microphone.
  let inputSourceName: String?
  /// Non-nil after input has remained below the silence threshold for the configured duration.
  let sustainedSilenceDuration: TimeInterval?
  let pauseReason: RecordingCapturePauseReason?

  var hasSustainedSilence: Bool { sustainedSilenceDuration != nil }
}

/// Small, allocation-free state machine used by the audio tap.
struct RecordingCaptureMeter {
  static let silenceThresholdRMS: Float = 0.003_162_277_7  // -50 dBFS
  static let sustainedSilenceThreshold: TimeInterval = 8
  static let updateInterval: TimeInterval = 0.1
  static let maximumSamplesPerUpdate = 1_024

  private(set) var normalizedLevel: Float = 0
  private(set) var silentDuration: TimeInterval = 0
  private var framesSinceUpdate: Int64 = 0
  private var silentFrames: Int64 = 0

  mutating func consume(
    samples: UnsafePointer<Float>,
    frameCount: Int,
    sampleRate: Double
  ) -> (level: Float, sustainedSilenceDuration: TimeInterval?)? {
    guard frameCount > 0, sampleRate > 0 else { return nil }

    framesSinceUpdate += Int64(frameCount)
    guard Double(framesSinceUpdate) / sampleRate >= Self.updateInterval else { return nil }

    let stride = max(1, (frameCount - 1) / Self.maximumSamplesPerUpdate + 1)
    var sumOfSquares: Float = 0
    var sampleCount = 0
    var index = 0
    while index < frameCount {
      let sample = samples[index]
      sumOfSquares += sample * sample
      sampleCount += 1
      index += stride
    }

    let rms = sqrt(sumOfSquares / Float(max(1, sampleCount)))
    let observedFrames = framesSinceUpdate
    framesSinceUpdate = 0

    if rms <= Self.silenceThresholdRMS {
      silentFrames += observedFrames
      silentDuration = Double(silentFrames) / sampleRate
    } else {
      silentFrames = 0
      silentDuration = 0
    }

    // Map -60...0 dBFS onto 0...1 and smooth falling values to avoid a jittery meter.
    let decibels = 20 * log10(max(rms, 0.000_001))
    let instantaneousLevel = min(1, max(0, (decibels + 60) / 60))
    normalizedLevel = max(instantaneousLevel, normalizedLevel * 0.72)

    let sustainedDuration =
      silentDuration >= Self.sustainedSilenceThreshold ? silentDuration : nil
    return (normalizedLevel, sustainedDuration)
  }

  mutating func reset() {
    normalizedLevel = 0
    silentDuration = 0
    framesSinceUpdate = 0
    silentFrames = 0
  }
}
