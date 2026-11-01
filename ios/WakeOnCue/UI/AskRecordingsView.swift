import SwiftUI
import WakeOnCueCore

/// Questions over local transcripts. Answers are written on this iPhone from retrieved
/// passages only, and every answer lists the passages it used.
struct AskRecordingsView: View {
  @Environment(AppModel.self) private var model
  @State private var question = ""
  @State private var askedQuestion: String?
  @State private var answer: RecordingAnswer?
  @State private var isAnswering = false
  @State private var errorMessage: String?
  @FocusState private var isQuestionFocused: Bool

  var body: some View {
    List {
      Section {
        TextField("Ask about your recordings", text: $question)
          .focused($isQuestionFocused)
          .submitLabel(.search)
          .onSubmit { ask() }
          .accessibilityIdentifier("ask-question-field")
        Button {
          ask()
        } label: {
          Label("Ask", systemImage: "text.magnifyingglass")
        }
        .disabled(trimmedQuestion.isEmpty || isAnswering)
        .accessibilityIdentifier("ask-submit")
      } footer: {
        Text(
          model.settings.activeLanguageModelProvider != nil
            ? "Matching passages are sent to the service you configured to write the answer. Speaker names stay on this iPhone."
            : OnDeviceIntelligence.canSummarize
              ? "Answers are written on this iPhone from your local transcripts only."
              : "Apple Intelligence is not available, so matching passages are shown without a written answer."
        )
      }

      if isAnswering {
        HStack(spacing: 10) {
          ProgressView()
          Text("Searching your recordings…").foregroundStyle(.secondary)
        }
      } else if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      } else if let answer {
        answerSection(answer)
        if !answer.sources.isEmpty {
          Section(answer.text == nil ? "Matching passages" : "Sources") {
            ForEach(answer.sources) { citation in
              sourceRow(citation)
            }
          }
        }
      }
    }
    .navigationTitle("Ask recordings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .accessibilityIdentifier("ask-recordings")
    .onAppear { if answer == nil { isQuestionFocused = true } }
  }

  @ViewBuilder
  private func answerSection(_ answer: RecordingAnswer) -> some View {
    Section {
      if let askedQuestion {
        Text(askedQuestion).font(.subheadline.weight(.semibold))
      }
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
            .foregroundStyle(.cyan)
        }
        Text("“\(citation.segment.text)”")
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(4)
      }
      .padding(.vertical, 2)
    }
    .accessibilityHint(model.settings.language.localized("Play from this transcript position"))
    .accessibilityIdentifier("ask-source-\(citation.id)")
  }

  private var trimmedQuestion: String {
    question.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func ask() {
    let asked = trimmedQuestion
    guard !asked.isEmpty, !isAnswering else { return }
    isQuestionFocused = false
    isAnswering = true
    errorMessage = nil
    askedQuestion = asked
    let language = model.settings.language
    Task { @MainActor in
      defer { isAnswering = false }
      do {
        let service = try RecordingLibraryService(layout: RecordingFileLayout())
        let sources = try await service.questionSources()
        var citations = RecordingQuestionRetriever.retrieve(question: asked, sources: sources)
        for index in citations.indices {
          citations[index].speakerName = speakerName(for: citations[index])
        }
        let result = await RecordingQuestionAnswering.answer(
          question: asked, citations: citations, language: language,
          provider: model.settings.activeLanguageModelProvider)
        guard askedQuestion == asked else { return }
        answer = result
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func speakerName(for citation: RecordingCitation) -> String? {
    guard citation.segment.speaker != nil else { return nil }
    return effectiveSpeakerName(
      citation.segment.speaker,
      aliases: RecordingAnnotationsService.shared
        .annotations(for: citation.recording.id).speakerAliases,
      personNames: model.settings.personNames,
      unknownSpeakerName: localizedSpeakerName(nil, language: model.settings.language)
    )
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
