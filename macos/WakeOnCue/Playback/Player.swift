@preconcurrency import AVFoundation
import Foundation
import Observation

/// Plays the day's audio from any moment, across segment files, mixing the microphone with
/// the meeting app when both were recorded. Private and deleted ranges are skipped.
@Observable
final class Player {
  private(set) var isPlaying = false
  /// Wall-clock time of the playhead; nil before anything was played.
  private(set) var position: Date?
  private(set) var sourceLabel = ""
  var rate: Float = 1 {
    didSet { for player in players { player.rate = rate } }
  }

  @ObservationIgnored private let store: Store
  @ObservationIgnored private var players: [AVAudioPlayer] = []
  @ObservationIgnored private var playing: [AudioSegment] = []
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
    guard let first = segments.first(where: { $0.channel == .microphone && $0.end > start })
      ?? segments.first(where: { $0.end > start })
    else {
      isPlaying = false
      return
    }
    start = max(start, first.start)
    // Every Mac channel that has audio at `start` plays together; Watch or iPhone audio only
    // where the Mac has none.
    let atStart = segments.filter { $0.start <= start.addingTimeInterval(0.5) && $0.end > start }
    let local = atStart.filter { $0.channel != .remote }
    let current = local.isEmpty ? Array(atStart.filter { $0.channel == .remote }.prefix(1)) : local
    var started: [AVAudioPlayer] = []
    let deviceTime = current.isEmpty ? 0 : (try? AVAudioPlayer(contentsOf: url(of: current[0])))?.deviceCurrentTime ?? 0
    for segment in current {
      guard let player = try? AVAudioPlayer(contentsOf: url(of: segment)) else { continue }
      player.enableRate = true
      player.rate = rate
      player.currentTime = max(0, start.timeIntervalSince(segment.start))
      player.prepareToPlay()
      started.append(player)
    }
    guard !started.isEmpty else {
      isPlaying = false
      return
    }
    let at = (started.first?.deviceCurrentTime ?? deviceTime) + 0.05
    for player in started { player.play(atTime: at) }
    players = started
    playing = current
    position = start
    sourceLabel = Self.label(for: current)
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
    for player in players { player.pause() }
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
    for player in players { player.stop() }
    players = []
    playing = []
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
    guard isPlaying, let lead = players.first, let segment = playing.first else { return }
    let now = segment.start.addingTimeInterval(lead.currentTime)
    position = now
    if store.marks(overlapping: DateInterval(start: now, duration: 1)).contains(where: { $0.covers(now) }) {
      play(from: now)
      return
    }
    // Move on when the lead file ends, or when another channel's segment starts.
    let ended = !lead.isPlaying || lead.currentTime >= lead.duration - 0.05
    let next = store.segments(overlapping: DateInterval(start: now, duration: 1))
    let changed = Set(next.map(\.id)) != Set(playing.map(\.id))
    if ended {
      play(from: segment.end)
    } else if changed, next.contains(where: { $0.start > segment.start }) {
      play(from: now)
    }
  }

  private static func label(for segments: [AudioSegment]) -> String {
    segments.map { $0.channel == .microphone ? "Mac 麦克风" : $0.source }.joined(separator: " + ")
  }
}
