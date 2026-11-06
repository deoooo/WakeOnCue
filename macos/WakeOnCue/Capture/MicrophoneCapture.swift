@preconcurrency import AVFoundation
import CoreAudio
import Foundation

enum CaptureError: LocalizedError {
  case microphoneDenied
  case noMicrophone

  var errorDescription: String? {
    switch self {
    case .microphoneDenied: "麦克风权限已关闭"
    case .noMicrophone: "没有可用的麦克风"
    }
  }
}

/// The microphone through AVCaptureSession, which can pick the built-in microphone without
/// changing the system's default input (AVAudioEngine deadlocks when switching devices). Reports
/// when the device goes away or the session fails, so the recorder can start over.
nonisolated final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  private let queue = DispatchQueue(label: "com.deoooo.WakeOnCue.macos.microphone", qos: .userInitiated)
  private var observers: [NSObjectProtocol] = []
  private var pipeline: ChannelPipeline?
  private(set) var deviceName = ""
  /// True when the built-in microphone was asked for but is unavailable, e.g. with the lid closed.
  private(set) var fellBack = false

  static func requestAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

  static func builtInDevice() -> AVCaptureDevice? {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
      .devices.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) && $0.isConnected }
  }

  func start(builtIn: Bool, into pipeline: ChannelPipeline, onInterrupted: @escaping @Sendable () -> Void) throws {
    var device = builtIn ? Self.builtInDevice() : nil
    fellBack = builtIn && device == nil
    if device == nil { device = AVCaptureDevice.default(for: .audio) }
    guard let device else { throw CaptureError.noMicrophone }
    deviceName = device.localizedName
    self.pipeline = pipeline

    session.beginConfiguration()
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input), session.canAddOutput(output) else {
      session.commitConfiguration()
      throw CaptureError.noMicrophone
    }
    session.addInput(input)
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: true,
      AVNumberOfChannelsKey: 1,
    ]
    output.setSampleBufferDelegate(self, queue: queue)
    session.addOutput(output)
    session.commitConfiguration()

    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
      onInterrupted()
    })
    observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { _ in
      onInterrupted()
    })
    session.startRunning()
  }

  func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    session.stopRunning()
    output.setSampleBufferDelegate(nil, queue: nil)
    pipeline = nil
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let pipeline, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
    pipeline.append(buffer)
  }

  private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    buffer.frameLength = frames
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
    return status == noErr ? buffer : nil
  }
}
