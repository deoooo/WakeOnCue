import AVFoundation
import Foundation

/// Durable bookkeeping for recordings made on the Watch. Each recording lives in
/// `Documents/Recordings/<session-id>/` with a `state.json` and its `segment-NNNN.m4a` files.
/// A segment file is deleted once the iPhone confirms it; the folder is deleted once the summary
/// and every segment have been delivered.
struct WatchRecordingState: Codable, Equatable {
  var summary: WatchSessionSummary
  var isEnded = false
  var isSummaryQueued = false
  var isSummaryDelivered = false
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

  static func update(_ sessionID: UUID, _ change: (inout WatchRecordingState) -> Void) {
    guard var state = load(sessionID) else { return }
    change(&state)
    save(state)
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
    removeIfDelivered(directory: url.deletingLastPathComponent())
  }

  static func summaryDelivered(_ sessionID: UUID) {
    update(sessionID) { $0.isSummaryDelivered = true }
    removeIfDelivered(directory: directory(for: sessionID))
  }

  private static func removeIfDelivered(directory: URL) {
    guard let sessionID = UUID(uuidString: directory.lastPathComponent),
      let state = load(sessionID), state.isSummaryDelivered
    else { return }
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? []
    guard !files.contains(where: { $0.pathExtension == "m4a" }) else { return }
    try? FileManager.default.removeItem(at: directory)
  }
}
