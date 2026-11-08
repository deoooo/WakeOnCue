import Darwin
import Foundation

/// An offline sherpa-onnx recognizer, loaded at run time from the official libraries the user
/// downloaded. One utterance at a time on its own queue; Qwen3-ASR is not a streaming model.
nonisolated final class SherpaRecognizer: @unchecked Sendable {
  enum Failure: LocalizedError {
    case library(String)
    case model

    var errorDescription: String? {
      switch self {
      case .library(let detail): "无法载入 sherpa-onnx 运行库：\(detail)"
      case .model: "无法载入模型，文件可能不完整，请删除后重新下载"
      }
    }
  }

  private typealias Create = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerConfig>?) -> OpaquePointer?
  private typealias CreateStream = @convention(c) (OpaquePointer?) -> OpaquePointer?
  private typealias Accept = @convention(c) (OpaquePointer?, Int32, UnsafePointer<Float>?, Int32) -> Void
  private typealias Decode = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
  private typealias Result = @convention(c) (OpaquePointer?) -> UnsafePointer<SherpaOnnxOfflineRecognizerResult>?
  private typealias DestroyResult = @convention(c) (UnsafePointer<SherpaOnnxOfflineRecognizerResult>?) -> Void
  private typealias Destroy = @convention(c) (OpaquePointer?) -> Void

  private let library: UnsafeMutableRawPointer
  private let recognizer: OpaquePointer
  private let createStream: CreateStream
  private let accept: Accept
  private let decode: Decode
  private let result: Result
  private let destroyResult: DestroyResult
  private let destroyStream: Destroy
  private let destroyRecognizer: Destroy
  private let lock = NSLock()

  /// - Parameters:
  ///   - runtime: the folder with `libsherpa-onnx-c-api.dylib` and `libonnxruntime.dylib`.
  ///   - files: the Qwen3-ASR files by role (`conv_frontend`, `encoder`, `decoder`, `tokenizer`).
  ///   - hotwords: the user's 常用词, comma-separated (`Vocabulary.hotwords`); Qwen3-ASR reads
  ///     them as context and spells names and jargon the way they are written there.
  init(runtime: URL, qwen3 files: [String: URL], threads: Int32 = 4, hotwords: String? = nil) throws {
    let path = runtime.appending(path: "libsherpa-onnx-c-api.dylib").path
    guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      throw Failure.library(String(cString: dlerror()))
    }
    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
      guard let pointer = dlsym(library, name) else { throw Failure.library("缺少 \(name)") }
      return unsafeBitCast(pointer, to: type)
    }
    let create = try symbol("SherpaOnnxCreateOfflineRecognizer", as: Create.self)
    createStream = try symbol("SherpaOnnxCreateOfflineStream", as: CreateStream.self)
    accept = try symbol("SherpaOnnxAcceptWaveformOffline", as: Accept.self)
    decode = try symbol("SherpaOnnxDecodeOfflineStream", as: Decode.self)
    result = try symbol("SherpaOnnxGetOfflineStreamResult", as: Result.self)
    destroyResult = try symbol("SherpaOnnxDestroyOfflineRecognizerResult", as: DestroyResult.self)
    destroyStream = try symbol("SherpaOnnxDestroyOfflineStream", as: Destroy.self)
    destroyRecognizer = try symbol("SherpaOnnxDestroyOfflineRecognizer", as: Destroy.self)

    // The recognizer copies every string while it is created, so they only need to live until then.
    var strings: [UnsafeMutablePointer<CChar>] = []
    defer { strings.forEach { free($0) } }
    func c(_ value: String) -> UnsafePointer<CChar> {
      let pointer = strdup(value)!
      strings.append(pointer)
      return UnsafePointer(pointer)
    }
    var config = SherpaOnnxOfflineRecognizerConfig()
    config.feat_config.sample_rate = 16_000
    config.feat_config.feature_dim = 80
    config.model_config.num_threads = threads
    config.model_config.provider = c("cpu")
    config.model_config.qwen3_asr.conv_frontend = c(files["conv_frontend"]?.path ?? "")
    config.model_config.qwen3_asr.encoder = c(files["encoder"]?.path ?? "")
    config.model_config.qwen3_asr.decoder = c(files["decoder"]?.path ?? "")
    config.model_config.qwen3_asr.tokenizer = c(files["tokenizer"]?.path ?? "")
    config.model_config.qwen3_asr.max_total_len = 512
    config.model_config.qwen3_asr.max_new_tokens = 256
    config.model_config.qwen3_asr.top_p = 1
    if let hotwords, !hotwords.isEmpty { config.model_config.qwen3_asr.hotwords = c(hotwords) }
    config.decoding_method = c("greedy_search")
    guard let recognizer = create(&config) else {
      dlclose(library)
      throw Failure.model
    }
    self.library = library
    self.recognizer = recognizer
  }

  deinit {
    destroyRecognizer(recognizer)
    dlclose(library)
  }

  /// Recognizes 16 kHz mono samples. Blocks; call off the main thread.
  func transcribe(_ samples: [Float]) -> String {
    lock.withLock {
      guard !samples.isEmpty, let stream = createStream(recognizer) else { return "" }
      defer { destroyStream(stream) }
      samples.withUnsafeBufferPointer { accept(stream, 16_000, $0.baseAddress, Int32($0.count)) }
      decode(recognizer, stream)
      guard let output = result(stream) else { return "" }
      defer { destroyResult(output) }
      return output.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
  }
}
