import Foundation

/// Replaces the middle of long silences with digital zero, the only input the AAC encoder makes
/// noticeably smaller. Every sample in comes out once, in order, so the recording's length and
/// every time position stay exactly what they would have been.
///
/// A frame is zeroed only when it sits inside an unbroken silent run: at least `holdSeconds` of
/// silence before it and `preRollSeconds` after it. One louder frame ends the run, so a doubtful
/// frame keeps the audio around it. Samples are delayed by `preRollSeconds` to see that far ahead.
struct WatchSilenceGate {
  struct Configuration: Equatable, Sendable {
    var sampleRate = 16_000.0
    var frameSeconds = 0.02
    /// Silence kept after the last sound before zeroing starts. Ordinary pauses stay untouched.
    var holdSeconds = 10.0
    /// Audio kept before the next sound, which may start too quietly to be detected.
    var preRollSeconds = 1.0
    /// A frame is silent up to this far above the noise floor.
    var marginDecibels = 6.0
    var minimumThresholdDecibels = -66.0
    /// Nothing louder than this is ever silence, so a noisy room is simply recorded in full.
    var maximumThresholdDecibels = -45.0
    /// How fast the noise floor may climb when the surroundings get louder.
    var floorRiseDecibelsPerSecond = 0.3

    var frameSamples: Int { Int((sampleRate * frameSeconds).rounded()) }
    var holdFrames: Int { Int((holdSeconds / frameSeconds).rounded()) }
    var preRollFrames: Int { Int((preRollSeconds / frameSeconds).rounded()) }

    var isValid: Bool {
      frameSamples > 0 && holdFrames > 0 && preRollFrames > 0 && marginDecibels >= 0
        && floorRiseDecibelsPerSecond >= 0
        && minimumThresholdDecibels <= maximumThresholdDecibels
    }
  }

  private let frameSamples: Int
  private let preRollFrames: Int
  private let runToZero: Int
  private let margin: Float
  private let minimumThreshold: Float
  private let maximumThreshold: Float
  private let floorRise: Float
  private var partial: [Int16]
  private var held: [Int16]
  private var frameCount = 0
  private var silentRun = 0
  private var floor: Float?

  /// Samples replaced with zero so far.
  private(set) var zeroedSamples = 0

  /// Returns nil for an unusable configuration; the caller then records everything unchanged.
  init?(configuration: Configuration = Configuration()) {
    guard configuration.isValid else { return nil }
    frameSamples = configuration.frameSamples
    preRollFrames = configuration.preRollFrames
    runToZero = configuration.holdFrames + configuration.preRollFrames + 1
    margin = Self.linear(decibels: configuration.marginDecibels)
    minimumThreshold = Self.linear(decibels: configuration.minimumThresholdDecibels)
    maximumThreshold = Self.linear(decibels: configuration.maximumThresholdDecibels)
    floorRise = Self.linear(
      decibels: configuration.floorRiseDecibelsPerSecond * configuration.frameSeconds)
    partial = []
    partial.reserveCapacity(frameSamples)
    held = [Int16](repeating: 0, count: preRollFrames * frameSamples)
  }

  /// Takes the next samples and returns those that are ready to be written.
  mutating func process(_ samples: UnsafeBufferPointer<Int16>) -> [Int16] {
    var output: [Int16] = []
    output.reserveCapacity(samples.count + frameSamples)
    var next = 0
    while next < samples.count {
      let taken = min(frameSamples - partial.count, samples.count - next)
      partial.append(contentsOf: samples[next..<(next + taken)])
      next += taken
      guard partial.count == frameSamples else { continue }
      advance(appendingTo: &output)
      partial.removeAll(keepingCapacity: true)
    }
    return output
  }

  /// Returns everything still held, unchanged. Call once when the recording stops.
  mutating func flush() -> [Int16] {
    var output: [Int16] = []
    let heldFrames = min(frameCount, preRollFrames)
    output.reserveCapacity(heldFrames * frameSamples + partial.count)
    let oldest = frameCount >= preRollFrames ? frameCount % preRollFrames : 0
    for offset in 0..<heldFrames {
      let start = ((oldest + offset) % preRollFrames) * frameSamples
      output.append(contentsOf: held[start..<(start + frameSamples)])
    }
    output.append(contentsOf: partial)
    partial.removeAll(keepingCapacity: true)
    frameCount = 0
    silentRun = 0
    return output
  }

  /// Classifies the frame in `partial`, releases the oldest held frame, and holds this one.
  private mutating func advance(appendingTo output: inout [Int16]) {
    silentRun = isSilent(partial) ? silentRun + 1 : 0
    let start = (frameCount % preRollFrames) * frameSamples
    if frameCount >= preRollFrames {
      // The frame leaving is `preRollFrames` older than the newest one, so a run this long
      // covers the whole hold before it and the whole pre-roll after it.
      if silentRun >= runToZero {
        output.append(contentsOf: repeatElement(0, count: frameSamples))
        zeroedSamples += frameSamples
      } else {
        output.append(contentsOf: held[start..<(start + frameSamples)])
      }
    }
    held.replaceSubrange(start..<(start + frameSamples), with: partial)
    frameCount += 1
  }

  private mutating func isSilent(_ frame: [Int16]) -> Bool {
    var sum: Float = 0
    for sample in frame {
      let value = Float(sample) / 32_768
      sum += value * value
    }
    let level = (sum / Float(frame.count)).squareRoot()
    // Falls at once and climbs slowly, so the floor follows the quiet moments, not the speech.
    let current = floor.map { min(level, $0 * floorRise) } ?? level
    floor = current
    let threshold = min(max(current * margin, minimumThreshold), maximumThreshold)
    return level <= threshold
  }

  private static func linear(decibels: Double) -> Float {
    Float(pow(10, decibels / 20))
  }
}
