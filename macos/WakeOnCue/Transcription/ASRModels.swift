import CryptoKit
import Foundation
import Observation
import OSLog

/// A file from an official release, with the size and SHA-256 published there.
nonisolated struct ReleaseFile: Hashable, Sendable {
  let url: URL
  let bytes: Int64
  let sha256: String
  /// The folder the `.tar.bz2` unpacks to.
  let folder: String
}

/// A model published on Hugging Face as separate files, pinned to one commit, each file checked
/// against its SHA-256 (the LFS hash for weights, our own for the small text files).
nonisolated struct HubSnapshot: Hashable, Sendable {
  struct File: Hashable, Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
  }

  let repo: String
  let revision: String
  /// The folder under Models the files go to.
  let folder: String
  let files: [File]

  var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

  func url(of file: File) -> URL {
    URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
  }
}

/// One entry of the transcription model list. Apple speech is built in; downloadable models come
/// from their publisher's own releases only. Supporting another sherpa-onnx Qwen3-ASR package or
/// MLX snapshot is one more entry in `catalog`.
nonisolated struct ASRModel: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case appleSpeech
    /// sherpa-onnx Qwen3-ASR; files by role, relative to the package folder.
    case qwen3(files: [String: String])
    /// Qwen3-ASR in MLX format, run on the GPU with mlx-audio-swift.
    case mlxQwen3(HubSnapshot)
    /// The user's OpenAI-compatible transcription service; audio leaves this Mac.
    case remoteService
  }

  let id: String
  /// Shown in lists, with the size in the name where it matters ("Qwen3-ASR 0.6B").
  let name: String
  let detail: String
  let size: String
  let source: String
  let kind: Kind
  let package: ReleaseFile?

  var isBuiltIn: Bool { kind == .appleSpeech }
  var isRemote: Bool { kind == .remoteService }
  /// Downloaded to this Mac: a sherpa-onnx package or an MLX snapshot.
  var isDownloadable: Bool { package != nil || snapshot != nil }

  var snapshot: HubSnapshot? {
    if case .mlxQwen3(let snapshot) = kind { snapshot } else { nil }
  }

  /// The folder under Models the model unpacks or downloads to.
  var folder: String? { package?.folder ?? snapshot?.folder }

  static let appleSpeech = ASRModel(
    id: "apple-speech", name: "Apple 语音（系统自带）", detail: "系统提供，边录边转", size: "", source: "macOS",
    kind: .appleSpeech, package: nil)

  static let qwen3_0_6B = ASRModel(
    id: "qwen3-asr-0.6b-int8",
    name: "Qwen3-ASR 0.6B",
    detail: "中文、中英混说和方言更准 · 按句识别，比实时晚几秒",
    size: "约 0.94 GB",
    source: "sherpa-onnx 官方发布（GitHub）",
    kind: .qwen3(files: [
      "conv_frontend": "conv_frontend.onnx",
      "encoder": "encoder.int8.onnx",
      "decoder": "decoder.int8.onnx",
      "tokenizer": "tokenizer",
    ]),
    package: ReleaseFile(
      url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2")!,
      bytes: 878_702_423,
      sha256: "393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96",
      folder: "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"))

  /// On the 11-06 早会 it got names, jargon and mixed English right far more often than 0.6B
  /// ("你和 AI 再 review 一次" for "你和他再聚一次", "防御性的编程" for "忙碌性的编程"), and on the
  /// GPU it took 71 s where 0.6B on the CPU took 244 s for the same 25 minutes.
  static let qwen3_1_7B = ASRModel(
    id: "qwen3-asr-1.7b-mlx-8bit",
    name: "Qwen3-ASR 1.7B",
    detail: "比 0.6B 更准，人名、术语和中英混说尤其明显 · 用 GPU，需要 16 GB 内存以上",
    size: "约 2.5 GB",
    source: "mlx-community（Hugging Face）",
    kind: .mlxQwen3(HubSnapshot(
      repo: "mlx-community/Qwen3-ASR-1.7B-8bit",
      revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
      folder: "mlx-qwen3-asr-1.7b-8bit-a8379a2",
      files: [
        .init(path: "config.json", bytes: 7_188, sha256: "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"),
        .init(path: "generation_config.json", bytes: 142, sha256: "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"),
        .init(path: "chat_template.json", bytes: 1_161, sha256: "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"),
        .init(path: "preprocessor_config.json", bytes: 330, sha256: "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
        .init(path: "tokenizer_config.json", bytes: 12_487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        .init(path: "vocab.json", bytes: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        .init(path: "merges.txt", bytes: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        .init(path: "model.safetensors.index.json", bytes: 78_968, sha256: "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5"),
        .init(path: "model.safetensors", bytes: 2_463_307_541, sha256: "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"),
      ])),
    package: nil)

  static let transcriptionService = ASRModel(
    id: "openai-compatible-transcription",
    name: "第三方转录服务（OpenAI 兼容）",
    detail: "按句把音频发到你配置的服务转录，比实时晚几秒",
    size: "",
    source: "你配置的服务",
    kind: .remoteService,
    package: nil)

  static let catalog: [ASRModel] = [.appleSpeech, .qwen3_0_6B, .qwen3_1_7B, .transcriptionService]

  /// The model to suggest on this Mac. 1.7B keeps 3–4 GB in memory all day next to
  /// SpeechAnalyzer and the summaries, which an 8 GB Mac cannot spare; 0.6B is suggested there.
  /// Nothing is downloaded or switched on without the user: Apple speech stays the default.
  static func recommended(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ASRModel {
    memory >= 16 << 30 ? .qwen3_1_7B : .qwen3_0_6B
  }

  /// The sherpa-onnx libraries every downloadable model runs on (Apple silicon, without TTS).
  static let runtime = ReleaseFile(
    url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib.tar.bz2")!,
    bytes: 8_455_084,
    sha256: "ac5594ad237db56ec4a6c4b3fc48700441b33a07bb71c235f35530a52a93f2e3",
    folder: "sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib")
}

/// Downloads, verifies, unpacks and removes models, and remembers which one is in use.
@Observable
final class ASRModels {
  enum State: Equatable {
    case notDownloaded
    case downloading(fraction: Double)
    case paused(fraction: Double)
    case verifying
    case installed
    case failed(String)
  }

  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Models")

  nonisolated static var directory: URL {
    Store.rootDirectory.appending(path: "Models", directoryHint: .isDirectory)
  }

  private(set) var states: [String: State] = [:]
  /// The model that refines transcripts; Apple speech alone when nil.
  private(set) var activeID: String?

  @ObservationIgnored private let defaults = UserDefaults.standard
  @ObservationIgnored private var downloader: Downloader?
  /// Called when the active model changes, so the refiner can load or drop it.
  @ObservationIgnored var onActiveChange: ((ASRModel?) -> Void)?

  @ObservationIgnored private let preferences: Preferences

  init(preferences: Preferences) {
    self.preferences = preferences
    try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    for model in ASRModel.catalog where model.isDownloadable {
      states[model.id] = isInstalled(model) ? .installed : resumeData(for: model) != nil ? .paused(fraction: savedFraction(model)) : .notDownloaded
    }
    let saved = defaults.string(forKey: "asrModel")
    activeID = ASRModel.catalog.first { $0.id == saved && !$0.isBuiltIn && state(of: $0) == .installed }?.id
  }

  var active: ASRModel? { ASRModel.catalog.first { $0.id == activeID } }

  func state(of model: ASRModel) -> State {
    switch model.kind {
    case .appleSpeech: .installed
    case .remoteService: preferences.transcriptionServiceReady ? .installed : .notDownloaded
    case .qwen3, .mlxQwen3: states[model.id] ?? .notDownloaded
    }
  }

  /// The service's settings changed: drop it if it is no longer usable, reload it otherwise.
  func transcriptionServiceChanged() {
    guard active?.isRemote == true else { return }
    activate(state(of: .transcriptionService) == .installed ? .transcriptionService : nil)
  }

  func activate(_ model: ASRModel?) {
    activeID = model.flatMap { state(of: $0) == .installed && !$0.isBuiltIn ? $0.id : nil }
    defaults.set(activeID, forKey: "asrModel")
    onActiveChange?(active)
  }

  // MARK: Files

  nonisolated static var runtimeFolder: URL { directory.appending(path: ASRModel.runtime.folder).appending(path: "lib") }

  nonisolated static func folder(of model: ASRModel) -> URL? {
    model.folder.map { directory.appending(path: $0, directoryHint: .isDirectory) }
  }

  /// The MLX model's folder, if every file is there at its published size. Each file is checked
  /// against its SHA-256 before it is moved in, so being there means it was verified.
  nonisolated static func snapshotFolder(of model: ASRModel) -> URL? {
    guard let snapshot = model.snapshot, let folder = folder(of: model) else { return nil }
    let complete = snapshot.files.allSatisfy { file in
      let size = (try? folder.appending(path: file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
      return size == file.bytes
    }
    return complete ? folder : nil
  }

  /// The model's files by role, if they are all there.
  nonisolated static func files(of model: ASRModel) -> [String: URL]? {
    guard case .qwen3(let files) = model.kind, let folder = folder(of: model) else { return nil }
    let urls = files.mapValues { folder.appending(path: $0) }
    return urls.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? urls : nil
  }

  private func isInstalled(_ model: ASRModel) -> Bool {
    if model.snapshot != nil { return Self.snapshotFolder(of: model) != nil }
    return Self.files(of: model) != nil
      && FileManager.default.fileExists(atPath: Self.runtimeFolder.appending(path: "libsherpa-onnx-c-api.dylib").path)
  }

  private func resumeURL(_ file: ReleaseFile) -> URL { Self.directory.appending(path: file.folder + ".resume") }
  private func resumeData(for model: ASRModel) -> Data? {
    if let snapshot = model.snapshot {
      return snapshot.files.lazy.compactMap { try? Data(contentsOf: self.resumeURL(snapshot, $0)) }.first
    }
    return model.package.flatMap { try? Data(contentsOf: resumeURL($0)) }
  }
  private func resumeURL(_ snapshot: HubSnapshot, _ file: HubSnapshot.File) -> URL {
    Self.directory.appending(path: snapshot.folder + "." + file.path + ".resume")
  }
  private func savedFraction(_ model: ASRModel) -> Double { defaults.double(forKey: "asrProgress.\(model.id)") }

  func bytesOnDisk() -> Int64 {
    var total: Int64 = 0
    if let files = FileManager.default.enumerator(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey]) {
      for case let url as URL in files { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    return total
  }

  // MARK: Download

  /// Downloads the runtime (once) and the model, verifies both, unpacks them and switches to the
  /// model. Resumes from where a pause or a failure left off.
  func download(_ model: ASRModel) {
    if let snapshot = model.snapshot {
      download(model, snapshot: snapshot)
      return
    }
    guard let package = model.package, downloader == nil else { return }
    states[model.id] = .downloading(fraction: savedFraction(model))
    Task {
      do {
        let runtimeReady = FileManager.default.fileExists(atPath: Self.runtimeFolder.appending(path: "libsherpa-onnx-c-api.dylib").path)
        let total = Double(package.bytes + (runtimeReady ? 0 : ASRModel.runtime.bytes))
        let offset = runtimeReady ? 0 : Double(ASRModel.runtime.bytes)
        if !runtimeReady {
          try await fetch(ASRModel.runtime, model: model) { Double($0) / total }
        }
        try await fetch(package, model: model) { (offset + Double($0)) / total }
        guard Self.files(of: model) != nil else { throw DownloadError.incomplete }
        states[model.id] = .installed
        defaults.removeObject(forKey: "asrProgress.\(model.id)")
        activate(model)
      } catch DownloadError.paused {
        states[model.id] = .paused(fraction: savedFraction(model))
      } catch {
        Self.logger.error("Download failed: \(error.localizedDescription, privacy: .public)")
        states[model.id] = .failed(error.localizedDescription)
      }
      downloader = nil
    }
  }

  /// Downloads the snapshot's files one by one, skipping those already there. Each is checked
  /// against its SHA-256 before it is moved into the model's folder.
  private func download(_ model: ASRModel, snapshot: HubSnapshot) {
    guard downloader == nil, let folder = Self.folder(of: model) else { return }
    states[model.id] = .downloading(fraction: savedFraction(model))
    Task {
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let total = Double(snapshot.bytes)
        var done: Int64 = 0
        for file in snapshot.files {
          let target = folder.appending(path: file.path)
          let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
          if size == file.bytes {
            done += file.bytes
            continue
          }
          try? FileManager.default.removeItem(at: target)
          let offset = done
          try await fetch(snapshot, file, into: target, model: model) { (Double(offset) + Double($0)) / total }
          done += file.bytes
        }
        guard Self.snapshotFolder(of: model) != nil else { throw DownloadError.incomplete }
        states[model.id] = .installed
        defaults.removeObject(forKey: "asrProgress.\(model.id)")
        activate(model)
      } catch DownloadError.paused {
        states[model.id] = .paused(fraction: savedFraction(model))
      } catch {
        Self.logger.error("Download failed: \(error.localizedDescription, privacy: .public)")
        states[model.id] = .failed(error.localizedDescription)
      }
      downloader = nil
    }
  }

  private func fetch(
    _ snapshot: HubSnapshot, _ file: HubSnapshot.File, into target: URL, model: ASRModel, fraction: @escaping (Int64) -> Double
  ) async throws {
    let resume = resumeURL(snapshot, file)
    let downloader = Downloader(url: snapshot.url(of: file), resumeData: try? Data(contentsOf: resume))
    self.downloader = downloader
    downloader.onProgress = { [weak self] written in
      Task { @MainActor in
        guard let self else { return }
        let value = fraction(written)
        self.states[model.id] = .downloading(fraction: value)
        self.defaults.set(value, forKey: "asrProgress.\(model.id)")
      }
    }
    switch await downloader.run() {
    case .finished(let location):
      try? FileManager.default.removeItem(at: resume)
      defer { try? FileManager.default.removeItem(at: location) }
      if file.bytes > 100_000_000 { states[model.id] = .verifying }
      let hash = try await Task.detached(priority: .utility) { try Self.sha256(of: location) }.value
      guard hash == file.sha256 else { throw DownloadError.checksum }
      try FileManager.default.moveItem(at: location, to: target)
    case .stopped(let resumeData, let paused):
      if let resumeData { try? resumeData.write(to: resume) }
      if paused { throw DownloadError.paused }
      throw downloader.error ?? DownloadError.incomplete
    }
  }

  func pause(_ model: ASRModel) {
    downloader?.pause()
  }

  /// Removes the model and goes back to Apple speech. The shared runtime stays.
  func delete(_ model: ASRModel) {
    guard let folder = Self.folder(of: model) else { return }
    if activeID == model.id { activate(nil) }
    downloader?.cancel()
    try? FileManager.default.removeItem(at: folder)
    if let package = model.package { try? FileManager.default.removeItem(at: resumeURL(package)) }
    if let snapshot = model.snapshot {
      for file in snapshot.files { try? FileManager.default.removeItem(at: resumeURL(snapshot, file)) }
    }
    defaults.removeObject(forKey: "asrProgress.\(model.id)")
    states[model.id] = .notDownloaded
  }

  private enum DownloadError: LocalizedError {
    case paused
    case checksum
    case incomplete
    case unpack(String)

    var errorDescription: String? {
      switch self {
      case .paused: "已暂停"
      case .checksum: "下载的文件校验不通过，已删除，请重新下载"
      case .incomplete: "解压后缺少模型文件，请删除后重新下载"
      case .unpack(let detail): "解压失败：\(detail)"
      }
    }
  }

  private func fetch(_ file: ReleaseFile, model: ASRModel, fraction: @escaping (Int64) -> Double) async throws {
    let downloader = Downloader(url: file.url, resumeData: try? Data(contentsOf: resumeURL(file)))
    self.downloader = downloader
    downloader.onProgress = { [weak self] written in
      Task { @MainActor in
        guard let self else { return }
        let value = fraction(written)
        self.states[model.id] = .downloading(fraction: value)
        self.defaults.set(value, forKey: "asrProgress.\(model.id)")
      }
    }
    let result = await downloader.run()
    switch result {
    case .finished(let location):
      try? FileManager.default.removeItem(at: resumeURL(file))
      states[model.id] = .verifying
      let archive = Self.directory.appending(path: file.folder + ".tar.bz2")
      try? FileManager.default.removeItem(at: archive)
      try FileManager.default.moveItem(at: location, to: archive)
      defer { try? FileManager.default.removeItem(at: archive) }
      try await Self.verifyAndUnpack(archive, expected: file)
    case .stopped(let resumeData, let paused):
      if let resumeData { try? resumeData.write(to: resumeURL(file)) }
      if paused { throw DownloadError.paused }
      throw downloader.error ?? DownloadError.incomplete
    }
  }

  /// Downloads the shared sherpa-onnx runtime if it is not on this Mac yet.
  func ensureRuntime() async throws {
    guard !FileManager.default.fileExists(atPath: Self.runtimeFolder.appending(path: "libsherpa-onnx-c-api.dylib").path) else { return }
    let downloader = Downloader(url: ASRModel.runtime.url, resumeData: nil)
    guard case .finished(let location) = await downloader.run() else { throw downloader.error ?? DownloadError.incomplete }
    let archive = Self.directory.appending(path: ASRModel.runtime.folder + ".tar.bz2")
    try? FileManager.default.removeItem(at: archive)
    try FileManager.default.moveItem(at: location, to: archive)
    defer { try? FileManager.default.removeItem(at: archive) }
    try await Self.verifyAndUnpack(archive, expected: ASRModel.runtime)
  }

  /// SHA-256 of a file, read in chunks.
  nonisolated static func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Checks the archive against the published SHA-256, then unpacks it with the system tar.
  private nonisolated static func verifyAndUnpack(_ archive: URL, expected: ReleaseFile) async throws {
    try await Task.detached(priority: .utility) {
      guard try sha256(of: archive) == expected.sha256 else { throw DownloadError.checksum }

      let destination = archive.deletingLastPathComponent()
      try? FileManager.default.removeItem(at: destination.appending(path: expected.folder))
      let tar = Process()
      tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
      tar.arguments = ["-xjf", archive.path, "-C", destination.path]
      let errors = Pipe()
      tar.standardError = errors
      try tar.run()
      tar.waitUntilExit()
      guard tar.terminationStatus == 0 else {
        throw DownloadError.unpack(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
      }
    }.value
  }
}

/// One resumable URLSession download with progress.
nonisolated final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  enum Outcome {
    case finished(URL)
    case stopped(resumeData: Data?, paused: Bool)
  }

  var onProgress: ((Int64) -> Void)?
  private(set) var error: Error?
  private let url: URL
  private let resumeData: Data?
  private var session: URLSession!
  private var task: URLSessionDownloadTask?
  private var continuation: CheckedContinuation<Outcome, Never>?
  private var pausing = false
  private let lock = NSLock()

  init(url: URL, resumeData: Data?) {
    self.url = url
    self.resumeData = resumeData
    super.init()
    session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
  }

  func run() async -> Outcome {
    await withCheckedContinuation { continuation in
      lock.withLock { self.continuation = continuation }
      let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
      self.task = task
      task.resume()
    }
  }

  func pause() {
    lock.withLock { pausing = true }
    task?.cancel { [weak self] data in self?.finish(.stopped(resumeData: data, paused: true)) }
  }

  func cancel() {
    task?.cancel()
  }

  private func finish(_ outcome: Outcome) {
    let continuation = lock.withLock {
      let value = self.continuation
      self.continuation = nil
      return value
    }
    continuation?.resume(returning: outcome)
    session.finishTasksAndInvalidate()
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    onProgress?(totalBytesWritten)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
    onProgress?(fileOffset)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // The temporary file is removed when this returns; keep it.
    let kept = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    do {
      try FileManager.default.moveItem(at: location, to: kept)
      if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
        error = URLError(.badServerResponse)
        finish(.stopped(resumeData: nil, paused: false))
      } else {
        finish(.finished(kept))
      }
    } catch {
      self.error = error
      finish(.stopped(resumeData: nil, paused: false))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error else { return }
    if lock.withLock({ pausing }) { return }
    self.error = error
    let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    finish(.stopped(resumeData: data, paused: false))
  }
}
