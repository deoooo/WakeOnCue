@preconcurrency import AVFoundation
import Foundation
import Observation

/// Plays the day's audio from any moment, across segment files, mixing the microphone with
/// forwarded Watch/iPhone audio when the Mac has no audio. Private and deleted ranges are skipped.
@Observable
final class Player {
  private(set) var isPlaying = false
  /// Wall-clock time of the playhead; nil before anything was played. It changes ten times a
  /// second while playing, so only small views should read it; anything that just needs to
  /// know which hour is playing reads `positionHour`.
  private(set) var position: Date? {
    didSet {
      let hour = position.map { Calendar.current.hourStart($0) }
      if hour != positionHour { positionHour = hour }
    }
  }
  /// The start of the hour the playhead is in. Changes only when playback crosses an hour.
  private(set) var positionHour: Date?
  private(set) var sourceLabel = ""
  var rate: Float = 1 {
    didSet { for track in tracks { track.player.rate = rate } }
  }

  /// A player plus the wall-clock span it covers. The span comes from the database, which counts
  /// recorded samples; `AVAudioPlayer.duration` is an estimate for ADTS AAC and can be 8–19% short.
  private struct Track {
    let player: AVAudioPlayer
    let segment: AudioSegment
    let duration: TimeInterval
  }

  @ObservationIgnored private let store: Store
  @ObservationIgnored private var tracks: [Track] = []
  @ObservationIgnored private var ticker: Task<Void, Never>?

  init(store: Store) {
    self.store = store
  }

  /// Starts playback at `date`, or at the next recorded moment after it.
  func play(from date: Date) {
    stopPlayers()
    let hidden = store.marks(overlapping: DateInterval(start: date.addingTimeInterval(-1), duration: 86_400))
    var start = date
    if let mark = hidden.first(where: { $0.covers(start) }) { start = mark.end }

    let window = DateInterval(start: start, duration: 86_400)
    let segments = store.segments(overlapping: window)
    guard let first = Self.firstSegment(at: start, in: segments) else {
      isPlaying = false
      return
    }
    start = max(start, first.start)
    // Every Mac channel that has audio at `start` plays together; Watch or iPhone audio only
    // where the Mac has none.
    let atStart = segments.filter { $0.start <= start.addingTimeInterval(0.5) && $0.end > start }
    let local = atStart.filter { $0.channel != .remote }
    let current = local.isEmpty ? Array(atStart.filter { $0.channel == .remote }.prefix(1)) : local
    var started: [Track] = []
    let deviceTime = current.isEmpty ? 0 : (try? AVAudioPlayer(contentsOf: url(of: current[0])))?.deviceCurrentTime ?? 0
    for segment in current {
      guard let player = try? AVAudioPlayer(contentsOf: url(of: segment)) else { continue }
      player.enableRate = true
      player.rate = rate
      player.currentTime = max(0, start.timeIntervalSince(segment.start))
      player.prepareToPlay()
      started.append(Track(
        player: player,
        segment: segment,
        duration: max(0.05, segment.end.timeIntervalSince(segment.start))))
    }
    guard !started.isEmpty else {
      isPlaying = false
      return
    }
    let at = (started.first?.player.deviceCurrentTime ?? deviceTime) + 0.05
    for track in started { track.player.play(atTime: at) }
    tracks = started
    position = start
    sourceLabel = Self.label(for: started.map(\.segment))
    isPlaying = true
    startTicker()
  }

  func toggle() {
    if isPlaying {
      pause()
    } else if let position {
      play(from: position)
    }
  }

  func pause() {
    for track in tracks { track.player.pause() }
    isPlaying = false
    ticker?.cancel()
    ticker = nil
  }

  func skip(_ seconds: TimeInterval) {
    guard let position else { return }
    let target = position.addingTimeInterval(seconds)
    if isPlaying {
      play(from: target)
    } else {
      self.position = target
    }
  }

  func stop() {
    stopPlayers()
    isPlaying = false
  }

  private func stopPlayers() {
    ticker?.cancel()
    ticker = nil
    for track in tracks { track.player.stop() }
    tracks = []
  }

  private func url(of segment: AudioSegment) -> URL {
    Store.audioDirectory.appending(path: segment.path)
  }

  private func startTicker() {
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard let self else { return }
        self.tick()
      }
    }
  }

  private func tick() {
    guard isPlaying, let track = tracks.first else { return }
    let player = track.player
    let segment = track.segment
    let now = segment.start.addingTimeInterval(player.currentTime)
    position = now
    if store.marks(overlapping: DateInterval(start: now, duration: 1)).contains(where: { $0.covers(now) }) {
      play(from: now)
      return
    }
    // Move on when the lead file ends, or when another channel's segment starts. Use the span
    // recorded in the database, not `player.duration`: for ADTS AAC that estimate is too short.
    let ended = !player.isPlaying || player.currentTime >= track.duration - 0.05
    let next = store.segments(overlapping: DateInterval(start: now, duration: 1))
    let changed = Set(next.map(\.id)) != Set(tracks.map { $0.segment.id })
    if ended {
      play(from: segment.end)
    } else if changed, next.contains(where: { $0.start > segment.start }) {
      play(from: now)
    }
  }

  /// The segment covering `date`, or the first one after it. A Watch-only gap must not jump to
  /// the next Mac microphone segment when forwarded audio exists at that moment.
  nonisolated static func firstSegment(at date: Date, in segments: [AudioSegment]) -> AudioSegment? {
    segments.first(where: { $0.start <= date && $0.end > date })
      ?? segments.first(where: { $0.end > date })
  }

  private static func label(for segments: [AudioSegment]) -> String {
    segments.map { $0.channel == .microphone ? "Mac 麦克风" : $0.source }.joined(separator: " + ")
  }
}
