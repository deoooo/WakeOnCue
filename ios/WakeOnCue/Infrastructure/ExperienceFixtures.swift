#if DEBUG && targetEnvironment(simulator)
import AVFoundation
import Foundation
import WakeOnCueCore

/// Opt-in, isolated simulator data for deterministic product navigation tests.
/// These generated tones are not evidence of microphone or ASR correctness.
enum ExperienceFixtures {
  static func prepareIfRequested() async throws {
    guard ProcessInfo.processInfo.environment["WAKEONCUE_EXPERIENCE_FIXTURES"] == "1" else { return }
    let layout = try RecordingFileLayout()
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    let anchor = Date(timeIntervalSince1970: 1_789_200_000)
    for index in 1...12 {
      let id = String(format: "experience-%02d", index)
      if let existing = try? await store.recording(id: id) {
        if existing.deletedAt != nil { try await store.restoreRecording(recordingID: id) }
        continue
      }
      let audio = try layout.downloadedAudioURL(recordingID: id)
      try writeTone(to: audio)
      let start = anchor.addingTimeInterval(-Double(index) * 3_600)
      let recording = RecordingRecord(
        id: id, createdAt: start, startedAt: start, duration: 60,
        status: .recording, localAudioPath: audio.path,
        deviceModel: "Simulator fixture", appVersion: "test",
        metadata: ["storage_mode": "local", "fixture": "experience"]
      )
      try await store.createRecording(recording, createPayloadPath: "", enqueueUpload: false)
      try await store.completeLocally(recordingID: id, duration: 60)
      let segments = (0..<30).map { segment in
        RealtimeTranscriptEvent(
          recordingID: id, segmentID: "\(id)-segment-\(segment)", revision: 1,
          startMilliseconds: segment * 2_000, endMilliseconds: (segment + 1) * 2_000,
          text: index == 12 && segment == 5
            ? "Orchid launch decision: review the prototype on Friday."
            : "Meeting \(index), point \(segment + 1): review the recording experience and next steps.",
          isFinal: true,
          speaker: RealtimeSpeaker(
            clusterID: "speaker_\(segment % 2 + 1)",
            personID: segment.isMultiple(of: 2) ? RealtimeSpeaker.selfPersonID : nil,
            displayName: "Speaker \(segment % 2 + 1)"
          )
        )
      }
      try JSONEncoder().encode(segments).write(to: layout.transcriptURL(recordingID: id), options: .atomic)
    }
    if ProcessInfo.processInfo.environment["WAKEONCUE_EXPERIENCE_UNREADABLE_TRANSCRIPT"] == "1" {
      try Data("unreadable".utf8).write(
        to: layout.transcriptURL(recordingID: "experience-01"), options: .atomic)
    }
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let input = documents.appending(path: "experience-input.m4a")
    if !FileManager.default.fileExists(atPath: input.path) {
      try FileManager.default.copyItem(at: layout.downloadedAudioURL(recordingID: "experience-01"), to: input)
    }
  }

  private static func writeTone(to url: URL) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
      AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000),
      let channel = buffer.floatChannelData?[0]
    else { throw CocoaError(.fileWriteUnknown) }
    buffer.frameLength = 24_000
    for frame in 0..<24_000 { channel[frame] = sin(Float(frame) * 0.04) * 0.015 }
    for _ in 0..<60 { try file.write(from: buffer) }
  }
}
#endif
