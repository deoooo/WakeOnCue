import Foundation

/// Which meeting apps the interface calls "being recorded": only those whose audio was actually
/// audible recently, not every app that merely has its output device open. The meeting channel
/// is a single mixed tap, so when several enabled apps are open the sound is attributed to that
/// group; the important case — a muted app with `IsRunningOutput` stuck true — stays silent.
nonisolated enum MeetingAudioActivity {
  /// A meeting app stays listed this long after its last audible moment, so short pauses do not
  /// make the menu bar flicker.
  static let hold: TimeInterval = 90

  static func activeApps(playingNames: [String], lastSoundAt: Date?, now: Date) -> [String] {
    guard let lastSoundAt, now.timeIntervalSince(lastSoundAt) < hold else { return [] }
    var seen = Set<String>()
    return playingNames.filter { seen.insert($0).inserted }
  }
}
