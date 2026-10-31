@preconcurrency import AVFoundation
import Foundation
import Observation
import OSLog
import WakeOnCueCore

/// Records an online meeting as two local channels — the microphone (the user) and the
/// audio this Mac plays (everyone else) — and optionally streams each channel as its own
/// realtime session with the same recording ID.
///
/// Files per meeting, in `~/Library/Application Support/WakeOnCue/Meetings/<recording_id>/`:
/// `microphone.caf` and `system.caf` (24 kHz mono PCM16, written while recording, the source
/// of truth), `meeting.m4a` (a mono AAC mix made on stop) and `transcript.json`.
@MainActor
@Observable
final class MeetingRecorder {
  enum State: Equatable {
    case idle
    case recording(since: Date)
    case finishing
  }

  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.mac", category: "Recording")

  let transcript = LiveTranscript()
  private(set) var state: State = .idle
  private(set) var recordingID: String?
  private(set) var folder: URL?
  private(set) var lastFolder: URL?
  private(set) var warning: String?
  private(set) var streamStates: [RealtimeAudioChannel: RealtimeStreamState] = [:]
  private(set) var levels: [RealtimeAudioChannel: Float] = [:]

  private var microphone: MicrophoneCapture?
  private var systemAudio: SystemAudioCapture?
  private var recorders: [RealtimeAudioChannel: ChannelRecorder] = [:]
  private var streams: [RealtimeAudioChannel: RealtimeChannelStream] = [:]
  private var frameContinuations: [RealtimeAudioChannel: AsyncStream<RealtimeAudioFrame>.Continuation] = [:]
  private var senders: [Task<Void, Never>] = []
  private var meterTask: Task<Void, Never>?

  var isRecording: Bool {
    if case .recording = state { return true }
    return false
  }

  static var meetingsDirectory: URL {
    URL.applicationSupportDirectory.appending(path: "WakeOnCue/Meetings", directoryHint: .isDirectory)
  }

  /// - Parameter realtime: the Gateway to stream to, or nil to record locally only.
  func start(realtime: (url: URL, token: String)?, tellSpeakersApart: Bool) async {
    guard state == .idle else { return }
    warning = nil
    guard await MicrophoneCapture.requestAccess() else {
      warning = CaptureError.microphoneDenied.localizedDescription
      return
    }

    let id = "rec_mac_\(UUID().uuidString.lowercased().prefix(12))"
    let directory = Self.meetingsDirectory.appending(path: id, directoryHint: .isDirectory)
    let startedAt = Date()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for channel in RealtimeAudioChannel.allCases {
        let (frames, continuation) = AsyncStream.makeStream(
          of: RealtimeAudioFrame.self, bufferingPolicy: .bufferingNewest(600))
        frameContinuations[channel] = continuation
        recorders[channel] = try ChannelRecorder(
          channel: channel,
          fileURL: directory.appending(path: "\(channel.rawValue).caf"),
          recordingStart: startedAt,
          onFrame: { continuation.yield($0) }
        )
        if let realtime {
          let stream = RealtimeChannelStream(
            gatewayURL: realtime.url,
            token: realtime.token,
            recordingID: id,
            language: nil,
            channel: channel,
            speakerDiarization: tellSpeakersApart,
            eventHandler: { [weak self] event in
              Task { @MainActor in self?.handle(event) }
            }
          )
          streams[channel] = stream
          // One ordered consumer per channel keeps audio.append in sequence.
          senders.append(
            Task {
              await stream.start()
              for await frame in frames { await stream.append(frame) }
              await stream.finish()
            })
        } else {
          senders.append(Task { for await _ in frames {} })
        }
      }

      let microphone = MicrophoneCapture()
      try microphone.start(into: recorders[.microphone]!)
      self.microphone = microphone
    } catch {
      warning = error.localizedDescription
      await teardown()
      try? FileManager.default.removeItem(at: directory)
      return
    }

    let systemAudio = SystemAudioCapture()
    do {
      try systemAudio.start(into: recorders[.system]!)
      self.systemAudio = systemAudio
    } catch {
      // Keep the microphone recording; the user still gets their own side of the meeting.
      Self.logger.error("System audio unavailable: \(error.localizedDescription, privacy: .public)")
      warning = error.localizedDescription
    }

    transcript.reset()
    recordingID = id
    folder = directory
    state = .recording(since: startedAt)
    startMeter()
  }

  func stop() async {
    guard isRecording, let folder else { return }
    state = .finishing
    await teardown()
    let directory = folder
    let snapshotStreams = Array(streams.values)
    streams = [:]

    do {
      try await Task.detached(priority: .utility) {
        try MeetingRecorder.exportMix(in: directory)
      }.value
    } catch {
      warning = String(localized: "Saved the channel recordings, but could not make meeting.m4a: \(error.localizedDescription)")
    }

    // Give the processor a moment to finalize the last sentences, then save the transcript.
    for _ in 0..<40 where !snapshotStreams.isEmpty {
      if streamStates.values.allSatisfy({ $0 == .completed || $0.isUnavailable }) { break }
      try? await Task.sleep(for: .milliseconds(500))
    }
    for stream in snapshotStreams { await stream.stop() }
    saveTranscript(in: directory)

    lastFolder = directory
    self.folder = nil
    recordingID = nil
    streamStates = [:]
    levels = [:]
    state = .idle
  }

  private func teardown() async {
    meterTask?.cancel()
    meterTask = nil
    microphone?.stop()
    systemAudio?.stop()
    microphone = nil
    systemAudio = nil
    for recorder in recorders.values {
      await Task.detached { recorder.finish() }.value
      if let failure = recorder.failure { warning = failure }
    }
    for continuation in frameContinuations.values { continuation.finish() }
    for sender in senders { await sender.value }
    recorders = [:]
    frameContinuations = [:]
    senders = []
  }

  private func handle(_ event: RealtimeStreamEvent) {
    switch event {
    case .state(let channel, let state):
      streamStates[channel] = state
    case .transcript(let event):
      transcript.apply(event)
    }
  }

  private func startMeter() {
    meterTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        for (channel, recorder) in self.recorders { self.levels[channel] = recorder.level }
        try? await Task.sleep(for: .milliseconds(150))
      }
    }
  }

  private func saveTranscript(in directory: URL) {
    guard !transcript.segments.isEmpty else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(transcript.segments) {
      try? data.write(to: directory.appending(path: "transcript.json"), options: .atomic)
    }
  }

  /// Mixes both channel files into one mono AAC m4a for listening and sharing.
  nonisolated static func exportMix(in directory: URL) throws {
    let sources = RealtimeAudioChannel.allCases.compactMap { channel -> AVAudioFile? in
      try? AVAudioFile(forReading: directory.appending(path: "\(channel.rawValue).caf"))
    }
    guard let first = sources.first else { return }
    let format = first.processingFormat
    let outputURL = directory.appending(path: "meeting.m4a")
    let output = try AVAudioFile(
      forWriting: outputURL,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
      ],
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )
    let chunk = AVAudioFrameCount(format.sampleRate)
    guard let mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
      let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)
    else { return }
    while true {
      mix.frameLength = 0
      for source in sources where source.framePosition < source.length {
        try source.read(into: scratch, frameCount: chunk)
        let count = Int(scratch.frameLength)
        guard let into = mix.floatChannelData?[0], let from = scratch.floatChannelData?[0] else {
          continue
        }
        if Int(mix.frameLength) < count {
          for index in Int(mix.frameLength)..<count { into[index] = 0 }
          mix.frameLength = AVAudioFrameCount(count)
        }
        for index in 0..<count { into[index] = max(-1, min(1, into[index] + from[index])) }
      }
      guard mix.frameLength > 0 else { break }
      try output.write(from: mix)
    }
  }
}

extension RealtimeStreamState {
  var isUnavailable: Bool {
    if case .unavailable = self { return true }
    return false
  }
}
