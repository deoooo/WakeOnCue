import AVFoundation
import Foundation

/// Durable bookkeeping for recordings made on the Watch. Each recording lives in
/// `Documents/Recordings/<session-id>/` with a `state.json` and its `segment-NNNN.m4a` files.
/// A segment file is deleted once the iPhone confirms it. `state.json` stays behind so the Watch
/// can list what it recorded; it is pruned `historyRetention` after everything was delivered.
struct WatchRecordingState: Codable, Equatable {
  var summary: WatchSessionSummary
  var isEnded = false
  var isSummaryQueued = false
  var isSummaryDelivered = false
}

/// What the Watch shows for one recording: how much it recorded and how much reached the iPhone.
struct WatchRecordingStatus: Identifiable, Equatable {
  let state: WatchRecordingState
  /// Completed segments whose file is still on the Watch.
  let pendingSegments: Int

  var id: UUID { state.summary.sessionID }
  var startedAt: Date { state.summary.startedAt }
  var segmentCount: Int { state.summary.segmentCount }
  var deliveredSegments: Int { max(0, segmentCount - pendingSegments) }
  var isEnded: Bool { state.isEnded }
  var isFullyDelivered: Bool { state.isEnded && state.isSummaryDelivered && pendingSegments == 0 }

  /// Recorded length; an open recording counts up to `now`.
  func duration(at now: Date) -> TimeInterval {
    let end = state.isEnded ? state.summary.endedAt : now
    return max(0, end.timeIntervalSince(state.summary.startedAt))
  }
}

enum WatchRecordingStore {
  static func root() -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let root = documents.appending(path: "Recordings", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  static func directory(for sessionID: UUID) -> URL {
    let directory = root().appending(
      path: sessionID.uuidString.lowercased(), directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func load(_ sessionID: UUID) -> WatchRecordingState? {
    let url = directory(for: sessionID).appending(path: "state.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? WatchBridgeCoding.decode(WatchRecordingState.self, from: data)
  }

  static func save(_ state: WatchRecordingState) {
    let url = directory(for: state.summary.sessionID).appending(path: "state.json")
    try? WatchBridgeCoding.encode(state).write(to: url, options: [.atomic])
  }

  /// Returns the changed state, which is right even when a full disk kept it from being saved.
  @discardableResult
  static func update(
    _ sessionID: UUID, _ change: (inout WatchRecordingState) -> Void
  ) -> WatchRecordingState? {
    guard var state = load(sessionID) else { return nil }
    change(&state)
    save(state)
    return state
  }

  static let historyRetention: TimeInterval = 7 * 24 * 3600

  /// Every recording still known to the Watch, newest first.
  static func statuses() -> [WatchRecordingStatus] {
    allStates()
      .map { WatchRecordingStatus(state: $0, pendingSegments: pendingSegmentCount(of: $0)) }
      .sorted { $0.startedAt > $1.startedAt }
  }

  /// Counts completed segment files without opening them, so it stays cheap for long recordings.
  static func pendingSegmentCount(of state: WatchRecordingState) -> Int {
    let folder = root().appending(
      path: state.summary.sessionID.uuidString.lowercased(), directoryHint: .isDirectory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { name in
      guard name.hasSuffix(".m4a"),
        let index = Int(name.dropFirst("segment-".count).dropLast(".m4a".count))
      else { return false }
      return index <= state.summary.segmentCount
    }.count
  }

  /// Drops the bookkeeping of recordings that were fully delivered more than a week ago.
  static func pruneHistory(now: Date = Date()) {
    for state in allStates()
    where state.isEnded && state.isSummaryDelivered
      && now.timeIntervalSince(state.summary.endedAt) > historyRetention
      && pendingSegmentCount(of: state) == 0
    {
      try? FileManager.default.removeItem(
        at: root().appending(
          path: state.summary.sessionID.uuidString.lowercased(), directoryHint: .isDirectory))
    }
  }

  static func allStates() -> [WatchRecordingState] {
    let folders = (try? FileManager.default.contentsOfDirectory(
      at: root(), includingPropertiesForKeys: nil)) ?? []
    return folders.compactMap { UUID(uuidString: $0.lastPathComponent) }.compactMap(load)
  }

  /// Completed segment files still waiting for delivery.
  static func pendingSegments(of state: WatchRecordingState) -> [(WatchSegmentMetadata, URL)] {
    let directory = directory(for: state.summary.sessionID)
    let completed = state.summary.segmentCount
    guard completed > 0 else { return [] }
    return (1...completed).compactMap { index in
      let placeholder = WatchSegmentMetadata(
        sessionID: state.summary.sessionID, index: index, startedAt: .distantPast, duration: 0)
      let url = directory.appending(path: placeholder.fileName)
      guard FileManager.default.fileExists(atPath: url.path),
        let file = try? AVAudioFile(forReading: url)
      else { return nil }
      let duration = Double(file.length) / file.fileFormat.sampleRate
      let startedAt = state.summary.startedAt.addingTimeInterval(
        Double(index - 1) * WatchAudioRecorder.segmentDuration)
      return (
        WatchSegmentMetadata(
          sessionID: state.summary.sessionID, index: index, startedAt: startedAt,
          duration: duration),
        url
      )
    }
  }

  /// A recording that was still open when the app stopped (crash, battery, update) is ended
  /// here with the segments that were completed. The half-written segment is unreadable AAC.
  static func recoverInterrupted(excluding activeSessionID: UUID? = nil) -> [WatchRecordingState] {
    allStates().filter { !$0.isEnded && $0.summary.sessionID != activeSessionID }.map { state in
      var state = state
      let directory = directory(for: state.summary.sessionID)
      let completed = state.summary.segmentCount
      let files = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
      for file in files where file.pathExtension == "m4a" {
        let index = Int(file.deletingPathExtension().lastPathComponent.dropFirst("segment-".count))
        if let index, index > completed { try? FileManager.default.removeItem(at: file) }
      }
      state.isEnded = true
      state.summary.endReason = "recovered"
      state.summary.endedAt = state.summary.startedAt.addingTimeInterval(
        Double(completed) * WatchAudioRecorder.segmentDuration)
      save(state)
      WatchDiagnostics.log(
        "recovered session=\(state.summary.sessionID.uuidString.prefix(8)) segments=\(completed)")
      return state
    }
  }

  static func segmentDelivered(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  static func summaryDelivered(_ sessionID: UUID) {
    update(sessionID) { $0.isSummaryDelivered = true }
  }
}
