import Foundation
import MLX
import MLXAudioSTT

/// Qwen3-ASR in MLX format on the GPU, through mlx-audio-swift. Loaded once from the model's
/// folder; one utterance at a time, since MLX work on one model is not safe to interleave.
nonisolated final class MLXRecognizer: @unchecked Sendable {
  enum Failure: LocalizedError {
    case model(String)

    var errorDescription: String? {
      switch self {
      case .model(let detail): "无法载入模型，文件可能不完整，请删除后重新下载（\(detail)）"
      }
    }
  }

  private let model: Qwen3ASRModel
  /// The user's 常用词 as Qwen3-ASR's context, the way its own toolkit passes hotwords.
  private let context: String
  private let lock = NSLock()

  private init(model: Qwen3ASRModel, context: String) {
    self.model = model
    self.context = context
  }

  /// - Parameters:
  ///   - folder: the snapshot folder with `config.json`, the tokenizer files and the weights.
  ///   - words: the user's 常用词.
  static func load(folder: URL, words: [String]) async throws -> MLXRecognizer {
    do {
      let model = try await Qwen3ASRModel.fromModelDirectory(folder)
      return MLXRecognizer(model: model, context: words.joined(separator: "，"))
    } catch {
      throw Failure.model(error.localizedDescription)
    }
  }

  /// The text of 16 kHz mono `samples`. Settings as in the 11-06 comparison: greedy decoding,
  /// a light repetition penalty against loops on mumbled audio, and at most 512 new tokens.
  func transcribe(_ samples: [Float]) -> String {
    lock.withLock {
      let output = model.generate(
        audio: MLXArray(samples),
        maxTokens: 512,
        temperature: 0,
        context: context,
        language: nil,
        repetitionPenalty: 1.05)
      Memory.clearCache()
      return output.text
    }
  }
}

extension MLXRecognizer: SentenceRecognizer {
  /// Off the caller's actor: a group of sentences takes about half a second on the GPU.
  @concurrent nonisolated func recognize(_ samples: [Float]) async throws -> String {
    transcribe(samples)
  }
}
