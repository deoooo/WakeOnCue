@preconcurrency import AVFoundation
import Foundation

/// The default input device through AVAudioEngine.
final class MicrophoneCapture {
  private let engine = AVAudioEngine()

  static func requestAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  func start(into recorder: ChannelRecorder) throws {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw CaptureError.noMicrophone
    }
    input.installTap(onBus: 0, bufferSize: 4_800, format: format) { buffer, _ in
      recorder.append(buffer)
    }
    engine.prepare()
    try engine.start()
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }
}

enum CaptureError: Error, LocalizedError {
  case microphoneDenied
  case noMicrophone
  case systemAudio(String, OSStatus)

  var errorDescription: String? {
    switch self {
    case .microphoneDenied:
      String(localized: "Microphone access is off. Allow WakeOnCue in System Settings › Privacy & Security › Microphone.")
    case .noMicrophone:
      String(localized: "No microphone is available.")
    case .systemAudio(let step, let status):
      String(localized: "Could not capture system audio (\(step), error \(status)). Allow WakeOnCue in System Settings › Privacy & Security › Screen & System Audio Recording.")
    }
  }
}
