@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// The sound played by the chosen apps only, through a Core Audio process tap. The tap is
/// private to WakeOnCue, mixes the processes down to mono and does not mute the speakers.
/// The first start asks for permission using NSAudioCaptureUsageDescription.
nonisolated final class MeetingAudioCapture: @unchecked Sendable {
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private let queue = DispatchQueue(label: "com.deoooo.WakeOnCue.macos.meeting-audio", qos: .userInitiated)
  private(set) var processes: [AudioObjectID] = []
  private(set) var outputUID: String?

  var isRunning: Bool { procID != nil }

  /// Asks for the system audio permission by briefly tapping all audio, without recording.
  static func requestAccess() {
    let capture = MeetingAudioCapture()
    let pipeline = ChannelPipeline(channel: .meeting, source: "", onSegment: { _ in }, onAudio: { _ in })
    try? capture.start(description: CATapDescription(monoGlobalTapButExcludeProcesses: []), processes: [], into: pipeline)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { capture.stop() }
  }

  func start(processes: [AudioObjectID], into pipeline: ChannelPipeline) throws {
    try start(description: CATapDescription(monoMixdownOfProcesses: processes), processes: processes, into: pipeline)
  }

  private func start(description: CATapDescription, processes: [AudioObjectID], into pipeline: ChannelPipeline) throws {
    stop()
    description.uuid = UUID()
    description.name = "WakeOnCue meeting audio"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

    var streamDescription = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var formatAddress = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    try check("read tap format", AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription))
    guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
      throw CaptureError.meetingAudio("tap format", kAudioHardwareUnsupportedOperationError)
    }

    guard let outputUID = AudioDevices.defaultOutputUID() else {
      throw CaptureError.meetingAudio("find output device", kAudioHardwareBadDeviceError)
    }
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "WakeOnCue Meeting Audio",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
      ],
    ]
    try check("create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
    try check(
      "create IO proc",
      AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
        pipeline.append(buffer)
      })
    try check("start", AudioDeviceStart(aggregateID, procID))
    self.processes = processes
    self.outputUID = outputUID
  }

  func stop() {
    if aggregateID != kAudioObjectUnknown {
      if let procID {
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
      }
      AudioHardwareDestroyAggregateDevice(aggregateID)
    }
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    procID = nil
    aggregateID = AudioObjectID(kAudioObjectUnknown)
    tapID = AudioObjectID(kAudioObjectUnknown)
    processes = []
    outputUID = nil
  }

  private func check(_ step: String, _ status: OSStatus) throws {
    guard status == noErr else {
      stop()
      throw CaptureError.meetingAudio(step, status)
    }
  }
}
