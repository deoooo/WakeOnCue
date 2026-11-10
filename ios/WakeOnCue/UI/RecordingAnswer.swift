import SwiftUI
import WakeOnCueCore

/// A question asked from the Search tab, answered on this iPhone (or by the configured
/// service) from matching passages only. Every answer lists the passages it used.
@MainActor
@Observable
final class RecordingAnswerState {
  private(set) var question: String?
  private(set) var answer: RecordingAnswer?
  private(set) var isAnswering = false
  private(set) var errorMessage: String?

  func clear() {
    question = nil
    answer = nil
    errorMessage = nil
  }

  func ask(_ text: String, model: AppModel) {
    let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !asked.isEmpty, !isAnswering || question != asked else { return }
    question = asked
    answer = nil
    errorMessage = nil
    isAnswering = true
    let language = model.settings.language
    Task { @MainActor in
      defer { if question == asked { isAnswering = false } }
      do {
        let service = try RecordingLibraryService(layout: RecordingFileLayout())
        let sources = try await service.questionSources()
        var citations = RecordingQuestionRetriever.retrieve(question: asked, sources: sources)
        for index in citations.indices {
          citations[index].speakerName = Self.speakerName(for: citations[index], model: model)
        }
        let result = await RecordingQuestionAnswering.answer(
          question: asked, citations: citations, language: language,
          provider: model.settings.activeLanguageModelProvider)
        guard question == asked else { return }
        answer = result
      } catch {
        guard question == asked else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  private static func speakerName(for citation: RecordingCitation, model: AppModel) -> String? {
    guard citation.segment.speaker != nil else { return nil }
    return effectiveSpeakerName(
      citation.segment.speaker,
      aliases: RecordingAnnotationsService.shared
        .annotations(for: citation.recording.id).speakerAliases,
      personNames: model.settings.personNames,
      unknownSpeakerName: localizedSpeakerName(nil, language: model.settings.language)
    )
  }
}

/// The answer card and the passages it came from, at the top of search results.
struct RecordingAnswerSection: View {
  @Environment(AppModel.self) private var model
  let state: RecordingAnswerState
  @State private var deletedRecordingIDs: Set<String> = []

  var body: some View {
    Section {
      if state.isAnswering {
        HStack(spacing: 10) {
          ProgressView()
          Text("Searching your recordings…").foregroundStyle(.secondary)
        }
      } else if let errorMessage = state.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      } else if let answer = state.answer {
        if let text = answer.text {
          Text(text)
            .textSelection(.enabled)
            .accessibilityIdentifier("ask-answer")
        }
        if let notice = answer.notice {
          Label(noticeText(notice), systemImage: noticeIcon(notice))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ask-notice")
        }
      }
    } header: {
      Label("Answer", systemImage: "sparkles")
    } footer: {
      Text(footer)
    }
    .task(id: "\(model.libraryVersion)-\(state.answer?.sources.map(\.id) ?? [])") {
      let recordingIDs = Set(state.answer?.sources.map(\.recording.id) ?? [])
      deletedRecordingIDs = await model.deletedRecordingIDs(among: recordingIDs)
    }

    if let answer = state.answer, !state.isAnswering {
      let sources = answer.sources.filter { !deletedRecordingIDs.contains($0.recording.id) }
      if !sources.isEmpty {
        Section(answer.text == nil ? "Matching passages" : "Sources") {
          ForEach(sources) { citation in
            sourceRow(citation)
          }
        }
      }
    }
  }

  private var footer: String {
    let language = model.settings.language
    if model.settings.activeLanguageModelProvider != nil {
      return language.localized(
        "Matching passages are sent to the service you configured to write the answer. Speaker names stay on this iPhone.")
    }
    return OnDeviceIntelligence.canSummarize
      ? language.localized("Answers are written on this iPhone from your local transcripts only.")
      : language.localized(
        "Apple Intelligence is not available, so matching passages are shown without a written answer.")
  }

  private func sourceRow(_ citation: RecordingCitation) -> some View {
    NavigationLink {
      RecordingDetailView(recording: citation.recording, initialSeek: citation.startTime)
        .environment(model)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(
            citation.recordingTitle
              ?? citation.recording.libraryDisplayTitle(language: model.settings.language)
          )
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          Spacer(minLength: 8)
          Text(citation.timestamp)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if let speakerName = citation.speakerName {
          Text(speakerName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text("“\(citation.segment.text)”")
          .font(.callout)
          .lineLimit(4)
      }
      .padding(.vertical, 2)
    }
    .accessibilityHint(model.settings.language.localized("Play from this transcript position"))
    .accessibilityIdentifier("ask-source-\(citation.id)")
  }

  private func noticeText(_ notice: RecordingAnswer.Notice) -> String {
    let language = model.settings.language
    switch notice {
    case .nothingFound:
      return language.localized("Nothing in your local transcripts matches this question.")
    case .notInRecordings:
      return language.localized(
        "The matching passages do not answer this question, so no answer was written.")
    case .intelligenceUnavailable:
      return language.localized("Apple Intelligence is not available. These passages match your question.")
    case .failed(let message):
      return String(
        format: language.localized("Could not write an answer: %@. These passages match your question."),
        message)
    }
  }

  private func noticeIcon(_ notice: RecordingAnswer.Notice) -> String {
    switch notice {
    case .nothingFound: "magnifyingglass"
    case .notInRecordings: "questionmark.circle"
    case .intelligenceUnavailable: "sparkles"
    case .failed: "exclamationmark.triangle"
    }
  }
}
