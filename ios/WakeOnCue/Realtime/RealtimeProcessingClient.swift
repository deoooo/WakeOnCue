@preconcurrency import AVFoundation
import Foundation
import OSLog
import WakeOnCueCore

enum RealtimeConnectionState: Equatable, Sendable {
  case disabled
  case connecting
  case waitingForProcessor
  case processing
  case reconnecting
  case unavailable(String)

  var isEnabled: Bool {
    if case .disabled = self { return false }
    return true
  }
}

enum RealtimeProcessingEvent: Sendable {
  case state(RealtimeConnectionState)
  case transcript(RealtimeTranscriptEvent)
  case completed
}

struct RealtimeAudioFrame: Sendable {
  let sequence: Int
  let startMilliseconds: Int
  let pcm16LittleEndian: Data
}

actor RealtimeProcessingClient {
  private static let logger = Logger(
    subsystem: "com.deoooo.WakeOnCue",
    category: "RealtimeTransport"
  )
  private let configuration: RealtimeProcessingConfiguration
  private let eventHandler: @Sendable (RealtimeProcessingEvent) -> Void
  private let urlSession: URLSession
  private let gatewayDiscovery: any RealtimeGatewayDiscovering
  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var sessionResponse: RealtimeSessionResponse?
  private var activeGatewayURL: URL?
  private var queuedFrames: [RealtimeAudioFrame] = []
  private var lastRevision = 0
  private var shouldStayConnected = false

  init(
    configuration: RealtimeProcessingConfiguration,
    urlSession: URLSession = .shared,
    gatewayDiscovery: any RealtimeGatewayDiscovering = BonjourRealtimeGatewayDiscovery(),
    eventHandler: @escaping @Sendable (RealtimeProcessingEvent) -> Void
  ) {
    self.configuration = configuration
    self.urlSession = urlSession
    self.gatewayDiscovery = gatewayDiscovery
    self.eventHandler = eventHandler
  }

  static func validate(configuration: RealtimeProcessingConfiguration) async throws {
    let url = configuration.gatewayURL.appending(path: "v1/realtime/validate")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue(
      "Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw RealtimeClientError.validationFailed
    }
  }

  func start(recordingID: String, language: String?) async {
    shouldStayConnected = true
    eventHandler(.state(.connecting))
    do {
      let selectedGateway = try await RealtimeGatewaySelector.select(
        configuration: configuration,
        discovery: gatewayDiscovery,
        urlSession: urlSession
      )
      let (created, sessionGateway) = try await createSession(
        recordingID: recordingID,
        language: language,
        gateways: uniqueGateways([selectedGateway, configuration.gatewayURL])
      )
      sessionResponse = created
      Self.logger.info(
        "Realtime session created through \(sessionGateway.absoluteString, privacy: .public)"
      )
      #if DEBUG
        print("WakeOnCue realtime transport: session created through \(sessionGateway.absoluteString)")
      #endif
      var lastError: Error = RealtimeClientError.disconnected
      for socketGateway in uniqueGateways([
        sessionGateway, selectedGateway, configuration.gatewayURL,
      ]) {
        do {
          try await connectSocket(created, through: socketGateway)
          activeGatewayURL = socketGateway
          Self.logger.info(
            "Realtime session connected through \(socketGateway.absoluteString, privacy: .public)"
          )
          #if DEBUG
            print(
              "WakeOnCue realtime transport: WebSocket connected through \(socketGateway.absoluteString)"
            )
          #endif
          return
        } catch {
          lastError = error
        }
      }
      throw lastError
    } catch {
      eventHandler(.state(.unavailable(error.localizedDescription)))
    }
  }

  func appendAudio(_ frame: RealtimeAudioFrame) async {
    guard shouldStayConnected else { return }
    guard socket != nil else {
      queuedFrames.append(frame)
      if queuedFrames.count > 120 { queuedFrames.removeFirst(queuedFrames.count - 120) }
      return
    }
    do {
      try await send(frame)
    } catch {
      queuedFrames.append(frame)
      if queuedFrames.count > 120 { queuedFrames.removeFirst(queuedFrames.count - 120) }
      socket?.cancel(with: .goingAway, reason: nil)
    }
  }

  func pause() async { try? await sendControl(type: "session.pause") }
  func resume() async { try? await sendControl(type: "session.resume") }

  func finish() async {
    try? await sendControl(type: "session.finish")
  }

  func stop() {
    shouldStayConnected = false
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    activeGatewayURL = nil
    queuedFrames.removeAll(keepingCapacity: false)
  }

  private func createSession(
    recordingID: String,
    language: String?,
    gateways: [URL]
  ) async throws -> (RealtimeSessionResponse, URL) {
    var lastError: Error = RealtimeClientError.sessionCreationFailed
    for gateway in gateways {
      do {
        return (
          try await createSession(
            gateway: gateway,
            recordingID: recordingID,
            language: language
          ),
          gateway
        )
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  private func createSession(
    gateway: URL,
    recordingID: String,
    language: String?
  ) async throws -> RealtimeSessionResponse {
    let endpoint = gateway.appending(path: "v1/realtime/sessions")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 12
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(configuration.bearerToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(
      RealtimeSessionRequest(recordingID: recordingID, language: language)
    )
    let (data, response) = try await urlSession.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
      throw RealtimeClientError.sessionCreationFailed
    }
    let created = try JSONDecoder().decode(RealtimeSessionResponse.self, from: data)
    guard created.protocolVersion == RealtimeProtocol.version else {
      throw RealtimeClientError.unsupportedProtocol
    }
    return created
  }

  private func connectSocket(
    _ response: RealtimeSessionResponse,
    through gateway: URL
  ) async throws {
    let websocketURL = try Self.websocketURL(
      sessionURL: response.websocketURL,
      through: gateway
    )
    var request = URLRequest(url: websocketURL)
    request.timeoutInterval = 4
    request.setValue("Bearer \(response.sessionToken)", forHTTPHeaderField: "Authorization")
    let task = urlSession.webSocketTask(with: request)
    socket = task
    task.resume()
    do {
      try await sendJSON([
        "protocol_version": RealtimeProtocol.version,
        "type": "session.replay",
        "after_revision": lastRevision,
      ])
      let frames = queuedFrames
      queuedFrames.removeAll(keepingCapacity: true)
      for frame in frames { try await send(frame) }
      receiveTask?.cancel()
      receiveTask = Task { [weak self] in await self?.receiveLoop() }
    } catch {
      task.cancel(with: .goingAway, reason: nil)
      socket = nil
      throw error
    }
  }

  private func receiveLoop() async {
    var retryDelay: UInt64 = 1
    while shouldStayConnected, !Task.isCancelled {
      do {
        guard let socket else { throw RealtimeClientError.disconnected }
        let message = try await socket.receive()
        guard case .string(let text) = message, let data = text.data(using: .utf8) else {
          continue
        }
        try handle(data)
        retryDelay = 1
      } catch {
        socket = nil
        guard shouldStayConnected, let sessionResponse else { return }
        eventHandler(.state(.reconnecting))
        try? await Task.sleep(for: .seconds(retryDelay))
        retryDelay = min(retryDelay * 2, 30)
        let localGateways = await gatewayDiscovery.discoverGateways(timeout: .milliseconds(400))
        let gateways = uniqueGateways(
          [activeGatewayURL].compactMap { $0 } + localGateways + [configuration.gatewayURL]
        )
        for gateway in gateways {
          do {
            try await connectSocket(sessionResponse, through: gateway)
            activeGatewayURL = gateway
            Self.logger.info(
              "Realtime session reconnected through \(gateway.absoluteString, privacy: .public)"
            )
            return
          } catch {
            continue
          }
        }
      }
    }
  }

  private func handle(_ data: Data) throws {
    let envelope = try JSONDecoder().decode(RealtimeServerEnvelope.self, from: data)
    switch envelope.type {
    case "transcript.upsert", "speaker.corrected":
      let event = try JSONDecoder().decode(RealtimeTranscriptEvent.self, from: data)
      lastRevision = max(lastRevision, event.revision)
      eventHandler(.transcript(event))
    case "session.ready", "processor.status":
      eventHandler(
        .state(envelope.status == "processing" ? .processing : .waitingForProcessor))
    case "session.completed":
      shouldStayConnected = false
      eventHandler(.completed)
      eventHandler(.state(.disabled))
      socket?.cancel(with: .normalClosure, reason: nil)
      socket = nil
    default:
      break
    }
  }

  private func send(_ frame: RealtimeAudioFrame) async throws {
    try await sendJSON([
      "protocol_version": RealtimeProtocol.version,
      "type": "audio.append",
      "sequence": frame.sequence,
      "start_ms": frame.startMilliseconds,
      "audio_base64": frame.pcm16LittleEndian.base64EncodedString(),
    ])
  }

  private func sendControl(type: String) async throws {
    try await sendJSON(["protocol_version": RealtimeProtocol.version, "type": type])
  }

  private func sendJSON(_ object: [String: Any]) async throws {
    guard let socket else { throw RealtimeClientError.disconnected }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
      throw RealtimeClientError.invalidMessage
    }
    try await socket.send(.string(text))
  }

  static func websocketURL(sessionURL: URL, through gateway: URL) throws -> URL {
    guard var sessionComponents = URLComponents(url: sessionURL, resolvingAgainstBaseURL: false),
      let gatewayComponents = URLComponents(url: gateway, resolvingAgainstBaseURL: false),
      let gatewayScheme = gatewayComponents.scheme,
      let gatewayHost = gatewayComponents.host
    else { throw RealtimeClientError.invalidWebSocketURL }
    sessionComponents.scheme = gatewayScheme == "https" ? "wss" : "ws"
    sessionComponents.host = gatewayHost
    sessionComponents.port = gatewayComponents.port
    guard let url = sessionComponents.url else {
      throw RealtimeClientError.invalidWebSocketURL
    }
    return url
  }

  private func uniqueGateways(_ gateways: [URL]) -> [URL] {
    var seen = Set<String>()
    return gateways.filter { seen.insert($0.absoluteString).inserted }
  }
}

enum RealtimeClientError: Error, LocalizedError {
  case validationFailed
  case sessionCreationFailed
  case unsupportedProtocol
  case invalidWebSocketURL
  case disconnected
  case invalidMessage

  var errorDescription: String? {
    switch self {
    case .validationFailed:
      AppLanguage.localized("Could not validate the realtime Gateway and token.")
    case .sessionCreationFailed:
      AppLanguage.localized("The realtime Gateway could not create a session.")
    case .unsupportedProtocol:
      AppLanguage.localized("The realtime Gateway uses an unsupported protocol version.")
    case .invalidWebSocketURL:
      AppLanguage.localized("The realtime Gateway returned an invalid WebSocket URL.")
    case .disconnected:
      AppLanguage.localized("Realtime processing is disconnected.")
    case .invalidMessage:
      AppLanguage.localized("Could not encode a realtime processing message.")
    }
  }
}

struct RealtimeAudioFileFrame: Sendable {
  let audio: RealtimeAudioFrame
  let progress: Double
}

enum RealtimeAudioFileReader {
  private static let samplesPerFrame = RealtimeProtocol.sampleRate / 2

  static func frames(
    from url: URL
  ) async throws -> RealtimeAudioFileFrameSequence {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw AudioCaptureError.invalidInputFormat
    }
    let duration = try await asset.load(.duration).seconds
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: RealtimeProtocol.sampleRate,
        AVNumberOfChannelsKey: RealtimeProtocol.channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw AudioCaptureError.converterUnavailable }
    reader.add(output)
    guard reader.startReading() else {
      throw AudioCaptureError.conversionFailed(
        reader.error?.localizedDescription
          ?? AppLanguage.localized("Could not start reading audio")
      )
    }
    return RealtimeAudioFileFrameSequence(
      state: RealtimeAudioFileFrameState(
        reader: reader,
        output: output,
        duration: duration,
        samplesPerFrame: samplesPerFrame
      )
    )
  }
}

struct RealtimeAudioFileFrameSequence: AsyncSequence, Sendable {
  typealias Element = RealtimeAudioFileFrame

  fileprivate let state: RealtimeAudioFileFrameState

  func makeAsyncIterator() -> Iterator { Iterator(state: state) }

  struct Iterator: AsyncIteratorProtocol {
    fileprivate let state: RealtimeAudioFileFrameState

    mutating func next() async throws -> RealtimeAudioFileFrame? {
      let readerState = state
      return try await Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        return try readerState.next()
      }.value
    }
  }
}

private final class RealtimeAudioFileFrameState: @unchecked Sendable {
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let duration: Double
  private let samplesPerFrame: Int
  private let bytesPerFrame: Int
  private var pending = Data()
  private var sequence = 1
  private var emittedSamples = 0
  private var progress = 0.0
  private var finished = false

  init(
    reader: AVAssetReader,
    output: AVAssetReaderTrackOutput,
    duration: Double,
    samplesPerFrame: Int
  ) {
    self.reader = reader
    self.output = output
    self.duration = duration
    self.samplesPerFrame = samplesPerFrame
    bytesPerFrame = samplesPerFrame * MemoryLayout<Int16>.size
  }

  func next() throws -> RealtimeAudioFileFrame? {
    while pending.count < bytesPerFrame, !finished {
      if let sampleBuffer = output.copyNextSampleBuffer() {
        try append(sampleBuffer)
      } else {
        finished = true
        if reader.status == .failed {
          throw AudioCaptureError.conversionFailed(
            reader.error?.localizedDescription ?? AppLanguage.localized("Audio reader failed")
          )
        }
      }
    }
    guard !pending.isEmpty else { return nil }

    let byteCount = min(bytesPerFrame, pending.count)
    let data = Data(pending.prefix(byteCount))
    pending.removeFirst(byteCount)
    let frame = RealtimeAudioFileFrame(
      audio: RealtimeAudioFrame(
        sequence: sequence,
        startMilliseconds: emittedSamples * 1_000 / RealtimeProtocol.sampleRate,
        pcm16LittleEndian: data
      ),
      progress: finished && pending.isEmpty ? 1 : progress
    )
    sequence += 1
    emittedSamples += byteCount / MemoryLayout<Int16>.size
    return frame
  }

  private func append(_ sampleBuffer: CMSampleBuffer) throws {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    let byteCount = CMBlockBufferGetDataLength(blockBuffer)
    var data = Data(count: byteCount)
    let status = data.withUnsafeMutableBytes { bytes in
      CMBlockBufferCopyDataBytes(
        blockBuffer,
        atOffset: 0,
        dataLength: byteCount,
        destination: bytes.baseAddress!
      )
    }
    guard status == kCMBlockBufferNoErr else {
      throw AudioCaptureError.conversionFailed(
        AppLanguage.localized("Could not read converted audio data"))
    }
    pending.append(data)
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
    let sampleDuration = CMSampleBufferGetDuration(sampleBuffer).seconds
    progress = duration.isFinite && duration > 0
      ? min(1, max(0, (presentationTime + max(0, sampleDuration)) / duration))
      : 0
  }
}
