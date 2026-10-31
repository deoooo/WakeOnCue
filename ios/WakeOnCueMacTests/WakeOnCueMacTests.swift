import AVFoundation
import CoreImage
import Foundation
import Testing
import WakeOnCueCore

@testable import WakeOnCue

@Test func pairingPayloadMatchesDocumentedContractAndScans() throws {
  let payload = try PairingCode.payload(
    gatewayURL: URL(string: "http://studio.local:8090")!, token: "secret-token")
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
  #expect(object["type"] as? String == "wakeoncue.realtime-gateway")
  #expect(object["version"] as? Int == 1)
  #expect(object["gateway_url"] as? String == "http://studio.local:8090")
  #expect(object["gateway_token"] as? String == "secret-token")

  let image = try #require(PairingCode.qrImage(for: payload))
  let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
  let detector = try #require(
    CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
  let decoded = detector.features(in: CIImage(cgImage: cgImage))
    .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
  #expect(decoded == [payload])
}

private final class FrameSink: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [RealtimeAudioFrame] = []
  var frames: [RealtimeAudioFrame] { lock.withLock { stored } }
  func append(_ frame: RealtimeAudioFrame) { lock.withLock { stored.append(frame) } }
}

private func sineBuffer(sampleRate: Double, channels: AVAudioChannelCount, seconds: Double)
  -> AVAudioPCMBuffer
{
  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
  let count = AVAudioFrameCount(sampleRate * seconds)
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
  buffer.frameLength = count
  for channel in 0..<Int(channels) {
    for index in 0..<Int(count) {
      buffer.floatChannelData![channel][index] = 0.25 * sin(Float(index) * 2 * .pi * 440 / Float(sampleRate))
    }
  }
  return buffer
}

@Test func channelRecorderWritesDiskAndEmitsHalfSecondFrames() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let sink = FrameSink()
  let recorder = try ChannelRecorder(
    channel: .system,
    fileURL: directory.appending(path: "system.caf"),
    recordingStart: Date(),
    onFrame: sink.append
  )
  // 48 kHz stereo, as a process tap or Bluetooth headset might deliver.
  for _ in 0..<12 { recorder.append(sineBuffer(sampleRate: 48_000, channels: 2, seconds: 0.1)) }
  recorder.finish()

  let frames = sink.frames
  #expect(frames.map(\.sequence) == Array(1...frames.count))
  #expect(frames.dropLast().allSatisfy { $0.pcm16LittleEndian.count == 24_000 })
  #expect(frames.count >= 2)
  #expect(frames[1].startMilliseconds == 500)
  let file = try AVAudioFile(forReading: directory.appending(path: "system.caf"))
  #expect(file.fileFormat.sampleRate == 24_000)
  #expect(file.fileFormat.channelCount == 1)
  let streamedSamples = frames.reduce(0) { $0 + $1.pcm16LittleEndian.count / 2 }
  #expect(Int(file.length) == streamedSamples)
  #expect(abs(Double(file.length) / 24_000 - 1.2) < 0.05)
  #expect(recorder.failure == nil)
}

@Test func exportMixCombinesBothChannelsIntoOneM4A() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let start = Date()
  for (channel, seconds) in [(RealtimeAudioChannel.microphone, 2.0), (.system, 1.0)] {
    let recorder = try ChannelRecorder(
      channel: channel,
      fileURL: directory.appending(path: "\(channel.rawValue).caf"),
      recordingStart: start,
      onFrame: { _ in }
    )
    recorder.append(sineBuffer(sampleRate: 44_100, channels: 1, seconds: seconds))
    recorder.finish()
  }
  try MeetingRecorder.exportMix(in: directory)
  let mix = try AVAudioFile(forReading: directory.appending(path: "meeting.m4a"))
  #expect(mix.fileFormat.channelCount == 1)
  #expect(abs(Double(mix.length) / mix.fileFormat.sampleRate - 2.0) < 0.1)
}

@MainActor
@Test func liveTranscriptMergesChannelsByTimeAndRevision() {
  let transcript = LiveTranscript()
  func event(_ channel: RealtimeAudioChannel, start: Int, revision: Int, text: String)
    -> RealtimeTranscriptEvent
  {
    RealtimeTranscriptEvent(
      recordingID: "rec", segmentID: "seg_0", revision: revision, startMilliseconds: start,
      endMilliseconds: start + 900, text: text, isFinal: true,
      speaker: channel == .microphone
        ? RealtimeSpeaker(clusterID: "microphone", personID: "self", displayName: "Me")
        : RealtimeSpeaker(clusterID: "speaker_2", displayName: "Speaker 2"),
      channel: channel)
  }
  transcript.apply(event(.system, start: 1_000, revision: 2, text: "Hello from Zoom"))
  transcript.apply(event(.microphone, start: 0, revision: 1, text: "Hi"))
  transcript.apply(event(.system, start: 1_000, revision: 1, text: "stale"))
  transcript.apply(event(.microphone, start: 0, revision: 3, text: "Hi there"))

  #expect(transcript.segments.map(\.text) == ["Hi there", "Hello from Zoom"])
  #expect(transcript.segments.map { LiveTranscript.speakerName(for: $0) } 
    == [String(localized: "Me"), String(localized: "Speaker \(2)")])
}

private final class EventSink: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [RealtimeStreamEvent] = []
  var events: [RealtimeStreamEvent] { lock.withLock { stored } }
  func append(_ event: RealtimeStreamEvent) { lock.withLock { stored.append(event) } }
}

/// Runs against a real Gateway when `~/Library/Caches/com.deoooo.WakeOnCue.mac.e2e.json`
/// holds `{"gateway": "http://127.0.0.1:8095", "token": "…"}`; skipped otherwise.
private let e2eConfigURL = URL.cachesDirectory.appending(path: "com.deoooo.WakeOnCue.mac.e2e.json")

@Test(.enabled(if: FileManager.default.fileExists(atPath: e2eConfigURL.path)))
func twoChannelSessionsStreamThroughRealGateway() async throws {
  let config = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: e2eConfigURL)) as? [String: String])
  let gateway = try #require(config["gateway"].flatMap(URL.init(string:)))
  let token = try #require(config["token"])
  let sink = EventSink()
  let streams = RealtimeAudioChannel.allCases.map { channel in
    RealtimeChannelStream(
      gatewayURL: gateway, token: token, recordingID: "rec_mac_e2e", language: nil,
      channel: channel, speakerDiarization: true, eventHandler: sink.append)
  }
  for stream in streams {
    await stream.start()
    for sequence in 1...3 {
      await stream.append(
        RealtimeAudioFrame(
          sequence: sequence, startMilliseconds: (sequence - 1) * 500,
          pcm16LittleEndian: Data(count: 24_000)))
    }
    await stream.finish()
  }
  for _ in 0..<50 {
    let completed = sink.events.filter {
      if case .state(_, .completed) = $0 { return true }
      return false
    }
    if completed.count == 2 { break }
    try await Task.sleep(for: .milliseconds(100))
  }
  let transcripts = sink.events.compactMap { event -> RealtimeTranscriptEvent? in
    if case .transcript(let transcript) = event { return transcript }
    return nil
  }
  let microphone = transcripts.filter { $0.channel == .microphone }
  let system = transcripts.filter { $0.channel == .system }
  #expect(microphone.count == 3)
  #expect(system.count == 3)
  #expect(microphone.allSatisfy { $0.speaker?.personID == RealtimeSpeaker.selfPersonID })
  #expect(system.allSatisfy { $0.speaker?.personID == nil && $0.speaker?.clusterID == "speaker_1" })
  #expect(Set(transcripts.map(\.recordingID)) == ["rec_mac_e2e"])
}

/// Starts the real Python stack from this checkout when
/// `~/Library/Caches/com.deoooo.WakeOnCue.mac.host-e2e` exists; skipped otherwise.
@MainActor
@Test(
  .enabled(
    if: FileManager.default.fileExists(
      atPath: URL.cachesDirectory.appending(path: "com.deoooo.WakeOnCue.mac.host-e2e").path)),
  .timeLimit(.minutes(5)))
func processorHostStartsAndStopsRealStack() async throws {
  let host = ProcessorHost()
  #expect(host.setupIssue == nil)
  await host.start()
  #expect(host.state == .running(ownedByApp: true))
  for _ in 0..<120 where !host.isProcessorRegistered {
    try await Task.sleep(for: .seconds(2))
  }
  #expect(host.isProcessorRegistered)
  host.stop()
  try await Task.sleep(for: .seconds(3))
  let health = try? await URLSession.shared.data(
    from: ProcessorHost.localGatewayURL.appending(path: "health"))
  #expect(health == nil)
}
