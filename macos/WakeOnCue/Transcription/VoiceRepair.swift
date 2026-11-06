@preconcurrency import AVFoundation
import Foundation

/// One-time repair of data the old meeting recording and voice learning left behind. The version
/// lives in `Preferences.voiceRepairVersion`; it runs once per library, at launch.
nonisolated enum VoiceRepair {
  static let version = 1

  /// IDs of meeting segments whose whole audio is below the silence floor. The channel check is
  /// repeated here so a caller cannot accidentally pass microphone audio.
  static func silentMeetingSegmentIDs(_ segments: [AudioSegment], directory: URL) async -> [Int64] {
    let meetingSegments = segments.filter { $0.channel == .meeting }
    return await Task.detached(priority: .utility) {
      meetingSegments.compactMap { segment in
        guard let peak = peak(of: directory.appending(path: segment.path)) else { return nil }
        return peak < AudioLevel.silenceThreshold ? segment.id : nil
      }
    }.value
  }

  /// Peak sample of a whole audio file, or nil when it cannot be read.
  static func peak(of url: URL) -> Float? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return nil }
    var peak: Float = 0
    while file.framePosition < file.length {
      do { try file.read(into: buffer) } catch { return nil }
      guard buffer.frameLength > 0 else { break }
      guard let samples = buffer.floatChannelData?[0] else { return nil }
      peak = max(peak, AudioLevel.peak(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
    }
    return peak
  }
}
