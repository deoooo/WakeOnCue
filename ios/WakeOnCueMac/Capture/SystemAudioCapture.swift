@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Everything this Mac plays (the remote side of Zoom, Teams, Feishu, …) through a
/// Core Audio process tap (macOS 14.4+). The tap is private to this app, mixes down to
/// mono and does not mute the user's speakers. The first start asks for permission
/// using NSAudioCaptureUsageDescription.
final class SystemAudioCapture {
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private let queue = DispatchQueue(label: "com.deoooo.WakeOnCue.mac.system-audio", qos: .userInitiated)

  func start(into recorder: ChannelRecorder) throws {
    let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    description.uuid = UUID()
    description.name = "WakeOnCue meeting audio"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

    var streamDescription = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var formatAddress = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    try check(
      "read tap format",
      AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription))
    guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
      throw CaptureError.systemAudio("tap format", kAudioHardwareUnsupportedOperationError)
    }

    let outputUID = try Self.defaultOutputDeviceUID()
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
    try check(
      "create aggregate device",
      AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

    try check(
      "create IO proc",
      AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
        else { return }
        recorder.append(buffer)
      })
    try check("start", AudioDeviceStart(aggregateID, procID))
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
  }

  private func check(_ step: String, _ status: OSStatus) throws {
    guard status == noErr else {
      stop()
      throw CaptureError.systemAudio(step, status)
    }
  }

  private static func defaultOutputDeviceUID() throws -> String {
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr else { throw CaptureError.systemAudio("find output device", status) }

    address.mSelector = kAudioDevicePropertyDeviceUID
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
    guard status == noErr, let uid else {
      throw CaptureError.systemAudio("read output device", status)
    }
    return uid.takeRetainedValue() as String
  }
}
