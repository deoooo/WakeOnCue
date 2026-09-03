import Foundation
import Network
import WakeOnCueCore

final class BackgroundUploadCoordinator: NSObject, @unchecked Sendable {
  static let sessionIdentifier = "com.deoooo.WakeOnCue.recording-uploads"

  private let store: RecordingStore
  private let stateLock = NSLock()
  private let monitor = NWPathMonitor()
  private let monitorQueue = DispatchQueue(label: "com.deoooo.WakeOnCue.network-monitor")
  private var responseBodies: [Int: Data] = [:]
  private var backgroundCompletionHandler: (@Sendable () -> Void)?
  private var configuration: S3Configuration?
  private var retryWakeTask: Task<Void, Never>?
  private var scheduling = false
  private var networkAvailable = true
  private var uploadsEnabled = true

  var onStateChanged: (@Sendable () -> Void)?
  var onFinalAudioUploaded: (@Sendable (String) -> Void)?

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.waitsForConnectivity = true
    configuration.isDiscretionary = false
    configuration.allowsCellularAccess = true
    configuration.httpMaximumConnectionsPerHost = 3
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 24 * 60 * 60
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  init(store: RecordingStore, configuration: S3Configuration?) {
    self.store = store
    self.configuration = configuration
    super.init()
  }

  func activate(uploadsEnabled: Bool) async throws -> [String] {
    stateLock.withLock { self.uploadsEnabled = uploadsEnabled }
    let tasks = await currentSessionTasks()
    if !uploadsEnabled { tasks.forEach { $0.cancel() } }
    let activeTaskIDs = Set(tasks.compactMap(\.taskDescription))
    let interruptedRecordings = try await store.recoverAfterProcessTermination(
      activeUploadTaskIDs: activeTaskIDs
    )
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.stateLock.withLock { self.networkAvailable = path.status == .satisfied }
      if path.status == .satisfied { self.schedule() }
    }
    monitor.start(queue: monitorQueue)
    schedule()
    return interruptedRecordings
  }

  func updateConfiguration(_ configuration: S3Configuration?) {
    stateLock.withLock { self.configuration = configuration }
    schedule()
  }

  func setUploadsEnabled(_ enabled: Bool) {
    stateLock.withLock {
      uploadsEnabled = enabled
      if !enabled {
        retryWakeTask?.cancel()
        retryWakeTask = nil
      }
    }
    if enabled {
      schedule()
    } else {
      Task { [weak self] in
        guard let self else { return }
        for task in await currentSessionTasks() { task.cancel() }
      }
    }
  }

  func schedule() {
    let shouldStart = stateLock.withLock { () -> Bool in
      guard uploadsEnabled, !scheduling, networkAvailable else { return false }
      scheduling = true
      return true
    }
    guard shouldStart else { return }
    Task {
      defer { stateLock.withLock { scheduling = false } }
      do {
        try await scheduleEligibleTasks()
      } catch {
        onStateChanged?()
      }
    }
  }

  func handleEvents(completionHandler: @escaping @Sendable () -> Void) {
    stateLock.withLock { backgroundCompletionHandler = completionHandler }
    _ = session
  }

  private func scheduleEligibleTasks() async throws {
    guard stateLock.withLock({ uploadsEnabled }) else { return }
    let tasks = try await store.eligibleUploadTasks(limit: 12)
    guard let currentConfiguration = stateLock.withLock({ configuration }) else { return }
    for task in tasks {
      let chunk: ChunkRecord?
      if let chunkID = task.chunkID {
        chunk = try await store.chunk(id: chunkID)
      } else {
        chunk = nil
      }
      let fileURL = URL(filePath: task.localFilePath)
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        try await store.markUploadTaskFailed(
          id: task.id,
          error: "Upload source file is missing",
          retryAt: .distantFuture
        )
        continue
      }
      let contentType = task.kind == .uploadChunk || task.kind == .finish
        ? "audio/mp4" : "application/json"
      let request = try S3RequestSigner.signedRequest(
        method: "PUT",
        objectKey: currentConfiguration.objectKey(for: task, chunk: chunk),
        contentType: contentType,
        payloadHash: S3RequestSigner.payloadHash(fileURL: fileURL),
        configuration: currentConfiguration
      )
      let upload = session.uploadTask(with: request, fromFile: fileURL)
      upload.taskDescription = task.id
      do {
        try await store.claimUploadTask(
          id: task.id,
          backgroundTaskIdentifier: upload.taskIdentifier
        )
      } catch {
        upload.cancel()
        throw error
      }
      upload.resume()
    }
    try await armNextRetry()
    if !tasks.isEmpty { onStateChanged?() }
  }

  private func armNextRetry() async throws {
    guard let retryDate = try await store.nextUploadRetryDate() else {
      stateLock.withLock {
        retryWakeTask?.cancel()
        retryWakeTask = nil
      }
      return
    }
    let delay = max(0, retryDate.timeIntervalSinceNow)
    let wakeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.schedule()
    }
    stateLock.withLock {
      retryWakeTask?.cancel()
      retryWakeTask = wakeTask
    }
  }

  private func currentSessionTasks() async -> [URLSessionTask] {
    await withCheckedContinuation { continuation in
      session.getAllTasks { continuation.resume(returning: $0) }
    }
  }

  private func complete(task: URLSessionTask, error: Error?) {
    guard let uploadTaskID = task.taskDescription else { return }
    let responseBody = stateLock.withLock {
      responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
    }
    let statusCode = (task.response as? HTTPURLResponse)?.statusCode
    Task {
      do {
        if let error {
          try await fail(uploadTaskID: uploadTaskID, message: error.localizedDescription)
        } else if let statusCode, 200..<300 ~= statusCode {
          let completedTask = try await store.uploadTask(id: uploadTaskID)
          try await store.markUploadTaskUploaded(id: uploadTaskID)
          if completedTask.kind == .finish {
            onFinalAudioUploaded?(completedTask.recordingID)
          }
        } else {
          let message = String(data: responseBody, encoding: .utf8) ?? "HTTP \(statusCode ?? -1)"
          try await fail(uploadTaskID: uploadTaskID, message: message)
        }
      } catch {
        try? await fail(uploadTaskID: uploadTaskID, message: error.localizedDescription)
      }
      onStateChanged?()
      schedule()
    }
  }

  private func fail(uploadTaskID: String, message: String) async throws {
    let task = try await store.uploadTask(id: uploadTaskID)
    let retryCount = task.retryCount + 1
    let delay = min(pow(2, Double(min(retryCount, 9))), 900)
    try await store.markUploadTaskFailed(
      id: uploadTaskID,
      error: message,
      retryAt: Date().addingTimeInterval(delay)
    )
  }
}

extension BackgroundUploadCoordinator: URLSessionDataDelegate, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    stateLock.withLock {
      responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    complete(task: task, error: error)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let completion = stateLock.withLock { () -> (@Sendable () -> Void)? in
      defer { backgroundCompletionHandler = nil }
      return backgroundCompletionHandler
    }
    DispatchQueue.main.async { completion?() }
  }
}
