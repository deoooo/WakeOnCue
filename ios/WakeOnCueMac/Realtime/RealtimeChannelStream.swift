import Foundation
import OSLog
import WakeOnCueCore

enum RealtimeStreamState: Equatable, Sendable {
  case connecting
  case waitingForProcessor
  case processing
  case reconnecting
  case completed
  case unavailable(String)
}

enum RealtimeStreamEvent: Sendable {
  case state(RealtimeAudioChannel, RealtimeStreamState)
  case transcript(RealtimeTranscriptEvent)
}

/// One realtime session for one channel of a meeting, speaking protocol v1 with the
/// `channel` field. Failures here only cost live text: audio is already on disk.
actor RealtimeChannelStream {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.mac", category: "Realtime")
  private static let maxQueuedFrames = 240

  let channel: RealtimeAudioChannel
  private let gatewayURL: URL
  private let token: String
  private let request: RealtimeSessionRequest
  private let eventHandler: @Sendable (RealtimeStreamEvent) -> Void
  private let urlSession = URLSession(configuration: .ephemeral)
  private var session: RealtimeSessionResponse?
  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var queuedFrames: [RealtimeAudioFrame] = []
  private var lastRevision = 0
  private var active = false
  private var finishRequested = false

  init(
    gatewayURL: URL,
    token: String,
    recordingID: String,
    language: String?,
    channel: RealtimeAudioChannel,
    speakerDiarization: Bool,
    eventHandler: @escaping @Sendable (RealtimeStreamEvent) -> Void
  ) {
    self.gatewayURL = gatewayURL
    self.token = token
    self.channel = channel
    request = RealtimeSessionRequest(
      recordingID: recordingID,
      language: language,
      channel: channel,
      speakerDiarization: channel == .system && speakerDiarization
    )
    self.eventHandler = eventHandler
  }

  func start() async {
    active = true
    eventHandler(.state(channel, .connecting))
    do {
      var urlRequest = URLRequest(url: gatewayURL.appending(path: "v1/realtime/sessions"))
      urlRequest.httpMethod = "POST"
      urlRequest.timeoutInterval = 10
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      urlRequest.httpBody = try JSONEncoder().encode(request)
      let (data, response) = try await urlSession.data(for: urlRequest)
      guard (response as? HTTPURLResponse)?.statusCode == 201 else {
        throw RealtimeStreamError.sessionRejected
      }
      let created = try JSONDecoder().decode(RealtimeSessionResponse.self, from: data)
      guard created.protocolVersion == RealtimeProtocol.version else {
        throw RealtimeStreamError.sessionRejected
      }
      session = created
      try await connect()
    } catch {
      Self.logger.error("\(self.channel.rawValue, privacy: .public) session failed: \(error.localizedDescription, privacy: .public)")
      eventHandler(.state(channel, .unavailable(error.localizedDescription)))
    }
  }

  func append(_ frame: RealtimeAudioFrame) async {
    guard active else { return }
    guard socket != nil else {
      enqueue(frame)
      return
    }
    do {
      try await send(frame)
    } catch {
      enqueue(frame)
      socket?.cancel(with: .goingAway, reason: nil)
    }
  }

  /// Asks the processor to finalize; the session ends when it sends `session.completed`.
  func finish() async {
    finishRequested = true
    try? await sendJSON(["protocol_version": RealtimeProtocol.version, "type": "session.finish"])
  }

  func stop() {
    active = false
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    queuedFrames.removeAll()
  }

  private func enqueue(_ frame: RealtimeAudioFrame) {
    queuedFrames.append(frame)
    if queuedFrames.count > Self.maxQueuedFrames {
      queuedFrames.removeFirst(queuedFrames.count - Self.maxQueuedFrames)
    }
  }

  private func connect() async throws {
    guard let session else { throw RealtimeStreamError.disconnected }
    var components = URLComponents(url: session.websocketURL, resolvingAgainstBaseURL: false)
    // Keep the session path but always talk to the Gateway this app was configured with.
    let gateway = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false)
    components?.scheme = gateway?.scheme == "https" ? "wss" : "ws"
    components?.host = gateway?.host
    components?.port = gateway?.port
    guard let url = components?.url else { throw RealtimeStreamError.disconnected }
    var urlRequest = URLRequest(url: url)
    urlRequest.timeoutInterval = 5
    urlRequest.setValue("Bearer \(session.sessionToken)", forHTTPHeaderField: "Authorization")
    let task = urlSession.webSocketTask(with: urlRequest)
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
      if finishRequested {
        try await sendJSON(["protocol_version": RealtimeProtocol.version, "type": "session.finish"])
      }
      receiveTask?.cancel()
      receiveTask = Task { [weak self] in await self?.receiveLoop() }
    } catch {
      task.cancel(with: .goingAway, reason: nil)
      socket = nil
      throw error
    }
  }

  private func receiveLoop() async {
    var retryDelay = 1
    while active, !Task.isCancelled {
      do {
        guard let socket else { throw RealtimeStreamError.disconnected }
        let message = try await socket.receive()
        if case .string(let text) = message { handle(Data(text.utf8)) }
        retryDelay = 1
      } catch {
        socket = nil
        guard active else { return }
        eventHandler(.state(channel, .reconnecting))
        try? await Task.sleep(for: .seconds(retryDelay))
        retryDelay = min(retryDelay * 2, 15)
        if (try? await connect()) != nil { return }
      }
    }
  }

  private func handle(_ data: Data) {
    guard let envelope = try? JSONDecoder().decode(RealtimeServerEnvelope.self, from: data) else {
      return
    }
    switch envelope.type {
    case "transcript.upsert", "speaker.corrected":
      guard let event = try? JSONDecoder().decode(RealtimeTranscriptEvent.self, from: data) else {
        return
      }
      lastRevision = max(lastRevision, event.revision)
      eventHandler(.transcript(event))
    case "session.ready", "processor.status":
      eventHandler(
        .state(channel, envelope.status == "processing" ? .processing : .waitingForProcessor))
    case "session.completed":
      eventHandler(.state(channel, .completed))
      stop()
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

  private func sendJSON(_ object: [String: Any]) async throws {
    guard let socket else { throw RealtimeStreamError.disconnected }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }
}

enum RealtimeStreamError: Error, LocalizedError {
  case sessionRejected
  case disconnected

  var errorDescription: String? {
    switch self {
    case .sessionRejected: String(localized: "The realtime Gateway could not create a session.")
    case .disconnected: String(localized: "Realtime processing is disconnected.")
    }
  }
}
