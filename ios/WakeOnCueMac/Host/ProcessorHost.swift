import Foundation
import Observation
import OSLog

/// Starts and stops the Python Gateway and Mac Processor the same way
/// `server/scripts/run_local_mac_stack.sh` does, reachable only from this Mac.
@MainActor
@Observable
final class ProcessorHost {
  enum State: Equatable {
    case stopped
    case starting
    /// The Gateway answers `/health`; `ownedByApp` is false when someone else started it.
    case running(ownedByApp: Bool)
    case failed(String)
  }

  static let port = 8090
  static let localGatewayURL = URL(string: "http://127.0.0.1:\(port)")!

  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.mac", category: "ProcessorHost")

  private(set) var state: State = .stopped
  private(set) var processorsAvailable = 0
  private(set) var checkout: ServerCheckout?

  var backend: ProcessorBackend {
    didSet { UserDefaults.standard.set(backend.rawValue, forKey: "processorBackend") }
  }

  private var gateway: Process?
  private var processor: Process?
  private var healthTask: Task<Void, Never>?
  private var stopping = false
  private var stoppedAt = Date.distantPast

  init() {
    backend = UserDefaults.standard.string(forKey: "processorBackend")
      .flatMap(ProcessorBackend.init(rawValue:)) ?? .whisper
    reloadCheckout()
    startHealthMonitor()
  }

  var isGatewayUp: Bool {
    if case .running = state { return true }
    return false
  }

  var isProcessorRegistered: Bool { isGatewayUp && processorsAvailable > 0 }

  var isBusy: Bool {
    if case .starting = state { return true }
    return false
  }

  /// A human-readable reason the stack cannot start yet, or nil when it can.
  var setupIssue: String? {
    guard let checkout else {
      return String(
        localized: "Choose your WakeOnCue checkout folder. It must contain server/recording_service.")
    }
    if !checkout.hasGatewayEnvironment {
      return String(
        localized: "Python environment missing. In Terminal, run server/scripts/setup_mac.sh from \(checkout.root.path).")
    }
    if backend == .qwen, !checkout.hasQwenEnvironment {
      return String(
        localized: "Qwen3-ASR environment missing. Run WAKEONCUE_ASR_BACKEND=qwen server/scripts/setup_mac.sh, or choose MLX Whisper.")
    }
    return nil
  }

  var logDirectory: URL? { checkout?.runtimeDirectory }

  func chooseCheckout(_ url: URL) {
    UserDefaults.standard.set(url.path, forKey: "checkoutPath")
    reloadCheckout()
  }

  func reloadCheckout() {
    let preferred = UserDefaults.standard.string(forKey: "checkoutPath").map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    checkout = ServerCheckout.locate(preferred: preferred)
  }

  func start() async {
    guard gateway == nil else { return }
    reloadCheckout()
    if await fetchHealth() != nil {
      // A Gateway started from Terminal already owns the port; monitor it instead.
      state = .running(ownedByApp: false)
      return
    }
    if let setupIssue {
      state = .failed(setupIssue)
      return
    }
    guard let checkout else { return }
    state = .starting
    stopping = false
    do {
      let token = try GatewayToken.loadOrCreate()
      try FileManager.default.createDirectory(
        at: checkout.runtimeDirectory, withIntermediateDirectories: true)

      gateway = try launch(
        checkout.gatewayPython,
        arguments: ["-m", "recording_service.realtime_main"],
        checkout: checkout,
        environment: [
          "WAKEONCUE_REALTIME_HOST": "127.0.0.1",
          "WAKEONCUE_REALTIME_PORT": String(Self.port),
          "WAKEONCUE_REALTIME_API_TOKEN": token,
        ],
        log: "gateway.log"
      )
      guard await waitFor(seconds: 30, { $0 != nil }) else {
        throw ProcessorHostError.gatewayDidNotStart
      }

      let processorPython = backend == .qwen ? checkout.qwenPython : checkout.gatewayPython
      let qwenModel =
        ProcessInfo.processInfo.environment["WAKEONCUE_QWEN_MODEL"] ?? checkout.defaultQwenModel.path
      processor = try launch(
        processorPython,
        arguments: [
          "-m", "recording_service.mac_processor",
          "--gateway", Self.localGatewayURL.absoluteString,
          "--backend", backend.rawValue,
          "--qwen-model", qwenModel,
          "--model", "mlx-community/whisper-large-v3-turbo",
        ],
        checkout: checkout,
        environment: [
          "WAKEONCUE_REALTIME_API_TOKEN": token,
          "WAKEONCUE_DIARIZATION_MODEL_DIR": checkout.diarizationModels.path,
        ],
        log: "processor.log"
      )
      state = .running(ownedByApp: true)
      // Loading a model can take a while; health polling shows when the processor registers.
    } catch {
      Self.logger.error("Processor host failed: \(error.localizedDescription, privacy: .public)")
      stop()
      state = .failed(error.localizedDescription)
    }
  }

  func stop() {
    stopping = true
    for process in [processor, gateway].compactMap({ $0 }) where process.isRunning {
      process.terminate()
    }
    processor = nil
    gateway = nil
    processorsAvailable = 0
    stoppedAt = Date()
    state = .stopped
  }

  /// Synchronous variant for app termination, so no Python process outlives the app.
  nonisolated func terminateChildren() {
    MainActor.assumeIsolated {
      for process in [processor, gateway].compactMap({ $0 }) where process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }
  }

  private func launch(
    _ executable: URL,
    arguments: [String],
    checkout: ServerCheckout,
    environment: [String: String],
    log: String
  ) throws -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = checkout.serverDirectory
    var merged = ProcessInfo.processInfo.environment
    merged["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    merged["PYTHONPATH"] = "."
    merged["PYTHONUNBUFFERED"] = "1"
    merged.merge(environment) { _, new in new }
    process.environment = merged

    let logURL = checkout.runtimeDirectory.appending(path: log)
    if !FileManager.default.fileExists(atPath: logURL.path) {
      FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: logURL)
    handle.seekToEndOfFile()
    process.standardOutput = handle
    process.standardError = handle
    process.terminationHandler = { [weak self] finished in
      let status = finished.terminationStatus
      Task { @MainActor in self?.childExited(finished, status: status, log: log) }
    }
    try process.run()
    return process
  }

  private func childExited(_ process: Process, status: Int32, log: String) {
    guard !stopping, process === gateway || process === processor else { return }
    Self.logger.error("\(log, privacy: .public) child exited with status \(status)")
    stop()
    state = .failed(
      String(localized: "A realtime service process stopped (exit \(status)). See \(log) in the logs folder."))
  }

  private func startHealthMonitor() {
    healthTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshHealth()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func refreshHealth() async {
    let health = await fetchHealth()
    processorsAvailable = health?.processorsAvailable ?? 0
    switch (state, health) {
    case (.stopped, .some), (.failed, .some):
      // Our own Gateway can still answer for a moment after stop(); don't adopt it.
      if Date().timeIntervalSince(stoppedAt) > 5 { state = .running(ownedByApp: false) }
    case (.running(ownedByApp: false), .none):
      state = .stopped
    default:
      break
    }
  }

  private func waitFor(seconds: Int, _ condition: (GatewayHealth?) -> Bool) async -> Bool {
    for _ in 0..<seconds {
      if condition(await fetchHealth()) { return true }
      if gateway?.isRunning == false { return false }
      try? await Task.sleep(for: .seconds(1))
    }
    return false
  }

  private func fetchHealth() async -> GatewayHealth? {
    var request = URLRequest(url: Self.localGatewayURL.appending(path: "health"))
    request.timeoutInterval = 1.5
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return try? JSONDecoder().decode(GatewayHealth.self, from: data)
  }
}

struct GatewayHealth: Decodable, Sendable {
  let status: String
  let processorsAvailable: Int

  enum CodingKeys: String, CodingKey {
    case status
    case processorsAvailable = "processors_available"
  }
}

enum ProcessorHostError: Error, LocalizedError {
  case gatewayDidNotStart

  var errorDescription: String? {
    String(localized: "The Gateway did not start. Check gateway.log in the logs folder.")
  }
}
