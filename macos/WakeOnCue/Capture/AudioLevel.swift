import Foundation

/// Audio levels used by meeting recording and the one-time silence cleanup.
///
/// -70 dBFS is the digital-silence floor: full scale is 1.0, so a peak below about 0.000316 is
/// considered silent. A real call, even a quiet one, is far above this; a muted meeting app's tap
/// delivers only zeros.
nonisolated enum AudioLevel {
  static let silenceDBFS: Float = -70
  static var silenceThreshold: Float { pow(10, silenceDBFS / 20) }

  static func peak(_ samples: UnsafeBufferPointer<Float>) -> Float {
    var peak: Float = 0
    for sample in samples { peak = max(peak, abs(sample)) }
    return peak
  }

  static func peak(_ samples: [Float]) -> Float {
    samples.withUnsafeBufferPointer { peak($0) }
  }

  static func isSilent(_ peak: Float) -> Bool {
    peak < silenceThreshold
  }
}
