import Darwin
import Foundation

/// Speaker embeddings from a sherpa-onnx speaker model, loaded at run time like the recognizer.
/// Two embeddings of the same voice have a high cosine similarity.
nonisolated final class SpeakerEmbedder: @unchecked Sendable {
  private typealias Create = @convention(c) (UnsafePointer<SherpaOnnxSpeakerEmbeddingExtractorConfig>?) -> OpaquePointer?
  private typealias Dim = @convention(c) (OpaquePointer?) -> Int32
  private typealias CreateStream = @convention(c) (OpaquePointer?) -> OpaquePointer?
  private typealias Accept = @convention(c) (OpaquePointer?, Int32, UnsafePointer<Float>?, Int32) -> Void
  private typealias Finish = @convention(c) (OpaquePointer?) -> Void
  private typealias IsReady = @convention(c) (OpaquePointer?, OpaquePointer?) -> Int32
  private typealias Compute = @convention(c) (OpaquePointer?, OpaquePointer?) -> UnsafePointer<Float>?
  private typealias DestroyEmbedding = @convention(c) (UnsafePointer<Float>?) -> Void
  private typealias Destroy = @convention(c) (OpaquePointer?) -> Void

  private let library: UnsafeMutableRawPointer
  private let extractor: OpaquePointer
  private let dimension: Int
  private let createStream: CreateStream
  private let accept: Accept
  private let finish: Finish
  private let isReady: IsReady
  private let compute: Compute
  private let destroyEmbedding: DestroyEmbedding
  private let destroyStream: Destroy
  private let destroyExtractor: Destroy
  private let lock = NSLock()

  /// Shorter audio does not carry enough of a voice to compare.
  static let minimumSeconds = 1.5

  init(runtime: URL, model: URL) throws {
    guard let library = dlopen(runtime.appending(path: "libsherpa-onnx-c-api.dylib").path, RTLD_NOW | RTLD_LOCAL) else {
      throw SherpaRecognizer.Failure.library(String(cString: dlerror()))
    }
    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
      guard let pointer = dlsym(library, name) else { throw SherpaRecognizer.Failure.library("缺少 \(name)") }
      return unsafeBitCast(pointer, to: type)
    }
    let create = try symbol("SherpaOnnxCreateSpeakerEmbeddingExtractor", as: Create.self)
    let dim = try symbol("SherpaOnnxSpeakerEmbeddingExtractorDim", as: Dim.self)
    createStream = try symbol("SherpaOnnxSpeakerEmbeddingExtractorCreateStream", as: CreateStream.self)
    accept = try symbol("SherpaOnnxOnlineStreamAcceptWaveform", as: Accept.self)
    finish = try symbol("SherpaOnnxOnlineStreamInputFinished", as: Finish.self)
    isReady = try symbol("SherpaOnnxSpeakerEmbeddingExtractorIsReady", as: IsReady.self)
    compute = try symbol("SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding", as: Compute.self)
    destroyEmbedding = try symbol("SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding", as: DestroyEmbedding.self)
    destroyStream = try symbol("SherpaOnnxDestroyOnlineStream", as: Destroy.self)
    destroyExtractor = try symbol("SherpaOnnxDestroySpeakerEmbeddingExtractor", as: Destroy.self)

    let modelPath = strdup(model.path)!
    let provider = strdup("cpu")!
    defer {
      free(modelPath)
      free(provider)
    }
    var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
    config.model = UnsafePointer(modelPath)
    config.num_threads = 2
    config.provider = UnsafePointer(provider)
    guard let extractor = create(&config) else {
      dlclose(library)
      throw SherpaRecognizer.Failure.model
    }
    self.library = library
    self.extractor = extractor
    dimension = Int(dim(extractor))
  }

  deinit {
    destroyExtractor(extractor)
    dlclose(library)
  }

  /// A unit-length embedding of 16 kHz mono samples, or nil when the audio is too short.
  func embedding(_ samples: [Float]) -> [Float]? {
    guard Double(samples.count) / 16_000 >= Self.minimumSeconds else { return nil }
    return lock.withLock {
      guard let stream = createStream(extractor) else { return nil }
      defer { destroyStream(stream) }
      samples.withUnsafeBufferPointer { accept(stream, 16_000, $0.baseAddress, Int32($0.count)) }
      finish(stream)
      guard isReady(extractor, stream) != 0, let output = compute(extractor, stream) else { return nil }
      defer { destroyEmbedding(output) }
      return Self.normalized(Array(UnsafeBufferPointer(start: output, count: dimension)))
    }
  }

  static func normalized(_ vector: [Float]) -> [Float] {
    let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    return length > 0 ? vector.map { $0 / length } : vector
  }

  /// Cosine similarity of two unit-length embeddings.
  static func similarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return 0 }
    return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
  }

  /// The average of several embeddings, as a voiceprint.
  static func mean(_ vectors: [[Float]]) -> [Float]? {
    guard let first = vectors.first else { return nil }
    var sum = [Float](repeating: 0, count: first.count)
    for vector in vectors where vector.count == sum.count {
      for index in sum.indices { sum[index] += vector[index] }
    }
    return normalized(sum)
  }
}
