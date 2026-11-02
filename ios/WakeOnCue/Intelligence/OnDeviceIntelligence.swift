@preconcurrency import AVFoundation
import Foundation
import WakeOnCueCore

#if canImport(FoundationModels)
  import FoundationModels
#endif
#if canImport(Speech)
  import Speech
#endif

/// A short, structured summary of one recording.
struct RecordingSummary: Codable, Equatable, Sendable {
  var title: String
  var overview: String
  var keyPoints: [String]
  var actionItems: [String]
  var generatedAt: Date
  /// The configured service's model; nil when Apple Intelligence wrote it on this iPhone.
  var generatedBy: String? = nil
}

enum OnDeviceIntelligenceError: LocalizedError {
  case unsupportedLanguage
  case unavailable

  var errorDescription: String? {
    switch self {
    case .unsupportedLanguage:
      AppLanguage.localized("This iPhone cannot transcribe the selected spoken language.")
    case .unavailable:
      AppLanguage.localized("On-device transcription and summaries need iOS 26 or later with Apple Intelligence.")
    }
  }
}

/// Free transcription and summaries that run entirely on this iPhone (iOS 26+), used when
/// no third-party service is configured.
enum OnDeviceIntelligence {
  static var canTranscribe: Bool {
    if #available(iOS 26.0, *) { return SpeechTranscriber.isAvailable }
    return false
  }

  static var canSummarize: Bool {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        if case .available = SystemLanguageModel.default.availability { return true }
      }
    #endif
    return false
  }

  /// Why on-device transcription cannot run, and what the user can do instead.
  static var transcriptionUnavailableMessage: String {
    if #available(iOS 26.0, *) {
      return AppLanguage.localized(
        "On-device transcription is not available on this device. To transcribe recordings, add a transcription service in Settings."
      )
    }
    return AppLanguage.localized(
      "On-device transcription needs iOS 26 or later. To transcribe recordings on this iPhone, add a transcription service in Settings."
    )
  }

  /// Why on-device summaries cannot run, and what the user can do instead.
  static var summaryUnavailableMessage: String {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, *),
        case .unavailable(let reason) = SystemLanguageModel.default.availability
      {
        switch reason {
        case .deviceNotEligible:
          return AppLanguage.localized(
            "This device does not support Apple Intelligence. To get summaries, add a service in Settings."
          )
        case .appleIntelligenceNotEnabled:
          return AppLanguage.localized(
            "Apple Intelligence is turned off. Turn it on in iPhone Settings, or add a service in Settings."
          )
        case .modelNotReady:
          return AppLanguage.localized(
            "Apple Intelligence is still getting ready. Summaries can start once it finishes downloading."
          )
        @unknown default:
          break
        }
      }
    #endif
    return AppLanguage.localized(
      "On-device summaries need iOS 26 or later with Apple Intelligence. To get summaries, add a service in Settings."
    )
  }

  static func transcribe(
    audioURL: URL,
    recordingID: String,
    spokenLanguage: SpokenLanguage
  ) async throws -> [RealtimeTranscriptEvent] {
    guard #available(iOS 26.0, *) else { throw OnDeviceIntelligenceError.unavailable }
    let requested = Locale(identifier: spokenLanguage.recognitionCode.map {
      $0 == "zh" ? "zh-CN" : "en-US"
    } ?? Locale.current.identifier)
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
      throw OnDeviceIntelligenceError.unsupportedLanguage
    }
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [],
      attributeOptions: [.audioTimeRange]
    )
    if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await installation.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collector = Task {
      var segments: [RealtimeTranscriptEvent] = []
      for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let start = Int(max(0, result.range.start.seconds) * 1_000)
        let end = Int(max(0, result.range.end.seconds) * 1_000)
        segments.append(
          RealtimeTranscriptEvent(
            recordingID: recordingID,
            segmentID: "device_\(segments.count + 1)",
            revision: 1,
            startMilliseconds: start,
            endMilliseconds: max(start, end),
            text: text,
            isFinal: true,
            speaker: nil
          ))
      }
      return segments
    }
    do {
      let file = try AVAudioFile(forReading: audioURL)
      if let lastSample = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: lastSample)
      } else {
        await analyzer.cancelAndFinishNow()
      }
    } catch {
      collector.cancel()
      throw error
    }
    return try await collector.value
  }

  static func summarize(
    _ transcript: [RealtimeTranscriptEvent],
    title: String?,
    language: AppLanguage
  ) async throws -> RecordingSummary {
    #if canImport(FoundationModels)
      if #available(iOS 26.0, *) {
        return try await FoundationModelSummarizer(language: language).summarize(
          transcript, title: title)
      }
    #endif
    throw OnDeviceIntelligenceError.unavailable
  }
}

#if canImport(FoundationModels)
  @available(iOS 26.0, *)
  @Generable
  struct RecordingSummaryDraft {
    @Guide(description: "A short title for the conversation, at most 12 words")
    var title: String
    @Guide(description: "Two or three sentences on what the conversation was about")
    var overview: String
    @Guide(description: "Up to six key points, each one short sentence")
    var keyPoints: [String]
    @Guide(
      description:
        "Concrete commitments or follow-ups that someone agreed to, each naming who and what; empty if none"
    )
    var actionItems: [String]
  }

  /// Summarizes long transcripts within the on-device context window by first taking
  /// notes on consecutive parts, then summarizing the notes.
  @available(iOS 26.0, *)
  struct FoundationModelSummarizer {
    static let partCharacters = 6_000

    let language: AppLanguage

    func summarize(_ transcript: [RealtimeTranscriptEvent], title: String?) async throws
      -> RecordingSummary
    {
      let lines = transcript.sorted { $0.startMilliseconds < $1.startMilliseconds }.map(\.text)
      var parts: [String] = []
      var current = ""
      for line in lines {
        if current.count + line.count > Self.partCharacters, !current.isEmpty {
          parts.append(current)
          current = ""
        }
        current += line + "\n"
      }
      if !current.isEmpty { parts.append(current) }

      var material = parts.first ?? ""
      if parts.count > 1 {
        var notes: [String] = []
        for part in parts {
          let session = LanguageModelSession(instructions: instructions)
          let response = try await session.respond(
            to: "Write brief notes of the facts, decisions and commitments in this part of a transcript:\n\n\(part)"
          )
          notes.append(response.content)
        }
        material = notes.joined(separator: "\n\n")
      }

      let session = LanguageModelSession(instructions: instructions)
      let heading = title.map { "Recording title: \($0)\n\n" } ?? ""
      let draft = try await session.respond(
        to: "\(heading)Summarize this conversation:\n\n\(material)",
        generating: RecordingSummaryDraft.self
      ).content
      return RecordingSummary(
        title: draft.title,
        overview: draft.overview,
        keyPoints: Array(draft.keyPoints.prefix(6)),
        actionItems: draft.actionItems,
        generatedAt: .now
      )
    }

    private var instructions: String {
      let output = language == .simplifiedChinese ? "Simplified Chinese" : "English"
      return """
        You summarize recorded conversations for the person who recorded them. \
        Only use what the transcript says; never invent names, dates or decisions. \
        Write in \(output).
        """
    }
  }
#endif
