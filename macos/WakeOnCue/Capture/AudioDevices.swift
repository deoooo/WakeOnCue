import CoreAudio
import Foundation

/// Core Audio lookups for devices and processes.
nonisolated enum AudioDevices {
  static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var result = value
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
    return status == noErr ? result : value
  }

  static func array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  private static func hasInput(_ device: AudioObjectID) -> Bool {
    !array(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty
  }

  /// The Mac's own microphone, which stays put when AirPods connect.
  static func builtInMicrophone() -> AudioObjectID? {
    array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).first { device in
      property(device, kAudioDevicePropertyTransportType, default: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
        && hasInput(device)
    }
  }

  static func defaultInput() -> AudioObjectID? {
    let id = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(kAudioObjectUnknown))
    return id == kAudioObjectUnknown ? nil : id
  }

  static func name(of device: AudioObjectID) -> String {
    string(device, kAudioObjectPropertyName) ?? "麦克风"
  }

  static func defaultOutputUID() -> String? {
    let id = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    guard id != kAudioObjectUnknown else { return nil }
    return string(id, kAudioDevicePropertyDeviceUID)
  }

  struct AudioProcess: Hashable {
    let object: AudioObjectID
    let bundleID: String
    let isPlaying: Bool
  }

  /// Every process Core Audio knows about, with whether it is playing sound right now.
  static func processes() -> [AudioProcess] {
    array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { object in
      guard let bundleID = string(object, kAudioProcessPropertyBundleID), !bundleID.isEmpty else { return nil }
      let playing = property(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
      return AudioProcess(object: object, bundleID: bundleID, isPlaying: playing)
    }
  }
}
