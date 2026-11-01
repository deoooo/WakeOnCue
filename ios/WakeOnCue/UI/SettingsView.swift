import AppIntents
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var isActionButtonSetupPresented = false
  @State private var isForgetS3Presented = false

  var body: some View {
    @Bindable var settings = model.settings
    NavigationStack {
      Form {
        Section {
          Picker("App language", selection: $settings.language) {
            ForEach(AppLanguage.allCases) { language in
              Text(language.title).tag(language)
            }
          }
        } header: {
          Text("Language")
        } footer: {
          Text("The app follows your iPhone language until you choose a language here.")
        }

        Section {
          Picker("Appearance", selection: $settings.appearance) {
            ForEach(AppAppearance.allCases) { appearance in
              Text(appearance.title).tag(appearance)
            }
          }
          .accessibilityIdentifier("settings.appearance")
        } header: {
          Text("Appearance")
        } footer: {
          Text("Follow System updates automatically when your iPhone changes between Light and Dark Mode.")
        }

        if settings.hasLegacyS3Credentials {
          Section {
            Button("Forget S3 credentials", role: .destructive) {
              isForgetS3Presented = true
            }
            .accessibilityIdentifier("settings.storage.forget-s3")
          } header: {
            Text("Earlier S3 backups")
          } footer: {
            Text(
              "New recordings stay on this iPhone. Recordings backed up earlier still download from S3 when you open them, using the credentials saved on this iPhone."
            )
          }
          .confirmationDialog(
            "Forget S3 credentials?", isPresented: $isForgetS3Presented, titleVisibility: .visible
          ) {
            Button("Forget S3 credentials", role: .destructive) { model.forgetLegacyS3Storage() }
          } message: {
            Text("Recordings whose audio is only in S3 will no longer open on this iPhone.")
          }
        }

        Section {
          Picker(
            "Service",
            selection: Binding(
              get: { settings.speechEngine },
              set: { settings.selectSpeechEngine($0) })
          ) {
            Text("Apple Speech").tag(SpeechEngine.apple)
            Text("OpenAI-compatible API").tag(SpeechEngine.openAICompatible)
          }
          .accessibilityIdentifier("settings.ai.speech.engine")
          Picker("Spoken language", selection: $settings.spokenLanguage) {
            ForEach(SpokenLanguage.allCases) { language in
              Text(language.title).tag(language)
            }
          }
          if let defaultURL = settings.speechEngine.defaultBaseURL {
            ThirdPartyEndpointFields(
              identifier: "speech",
              defaultURL: defaultURL,
              modelPrompt: "Model, e.g. whisper-1",
              hasStoredKey: settings.activeSpeechEndpoint?.apiKey.isEmpty == false,
              baseURL: $settings.speechBaseURL,
              model: $settings.speechModel,
              apiKey: $settings.speechAPIKey
            )
          }
        } header: {
          Text("Transcription after recording")
        } footer: {
          if settings.speechEngine == .apple {
            Text("Runs on this iPhone with iOS 26 or later. Audio does not leave the device.")
          } else {
            Text(
              "Finished recordings are uploaded to this service automatically. Its privacy terms and charges apply. Save sends one second of silence to check the settings. Works with any service that implements /audio/transcriptions."
            )
          }
        }

        Section {
          Picker(
            "Service",
            selection: Binding(
              get: { settings.languageModelEngine },
              set: { settings.selectLanguageModelEngine($0) })
          ) {
            Text("Apple Intelligence").tag(LanguageModelEngine.apple)
            Text("OpenAI-compatible API").tag(LanguageModelEngine.openAICompatible)
            Text("Claude API").tag(LanguageModelEngine.anthropic)
          }
          .accessibilityIdentifier("settings.ai.language-model.engine")
          if let defaultURL = settings.languageModelEngine.defaultBaseURL {
            ThirdPartyEndpointFields(
              identifier: "language-model",
              defaultURL: defaultURL,
              modelPrompt: settings.languageModelEngine == .anthropic
                ? "Model, e.g. claude-sonnet-5-5" : "Model name",
              hasStoredKey: settings.activeLanguageModelProvider?.endpoint.apiKey.isEmpty == false,
              baseURL: $settings.languageModelBaseURL,
              model: $settings.languageModelName,
              apiKey: $settings.languageModelAPIKey
            )
          }
        } header: {
          Text("Summaries and questions")
        } footer: {
          if settings.languageModelEngine == .apple {
            Text("Runs on this iPhone with Apple Intelligence. Transcripts do not leave the device.")
          } else {
            Text(
              "Transcripts are sent to this service for summaries, and matching passages for questions, with recording titles. Its privacy terms and charges apply. Speaker names are not sent. API keys stay in this iPhone's Keychain."
            )
          }
        }

        Section {
          NavigationLink {
            PlacesView()
          } label: {
            LabeledContent {
              Text("\(model.places.places.count)")
            } label: {
              Label("Places", systemImage: "mappin.and.ellipse")
            }
          }
          .accessibilityIdentifier("settings.places")
        } footer: {
          Text("Start or finish recording when you arrive at or leave a place.")
        }

        CalendarSettingsSection()

        if let message = model.settingsStatusMessage {
          Section {
            Label(
              message,
              systemImage: model.settingsStatusIsError
                ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(model.settingsStatusIsError ? .orange : .green)
          }
        }

        Section {
          HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
              .foregroundStyle(.green)
            Text("Recording never depends on the network. Local audio remains the source of truth.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }

        Section {
          Button {
            isActionButtonSetupPresented = true
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "record.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
                .frame(width: 30)

              VStack(alignment: .leading, spacing: 3) {
                Text("Set Up Action Button")
                  .foregroundStyle(.primary)
                Text("Start recording with one press")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }

              Spacer()

              Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHint(
            "Shows instructions for assigning Start Recording to the iPhone Action Button")
        } header: {
          Text("Action Button")
        } footer: {
          Text(
            "Available on iPhone models with an Action Button. Apple requires this system setting to be selected manually once."
          )
        }
      }
      .disabled(model.isSavingSettings)
      .interactiveDismissDisabled(model.isSavingSettings)
      .scrollContentBackground(.hidden)
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .sheet(isPresented: $isActionButtonSetupPresented) {
        ActionButtonSetupView()
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { model.cancelSettings() }
            .disabled(model.isSavingSettings)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await model.saveSettings() }
          } label: {
            if model.isSavingSettings {
              ProgressView().controlSize(.small)
            } else {
              Text("Save")
            }
          }
          .fontWeight(.semibold)
          .disabled(model.isSavingSettings)
          .accessibilityIdentifier("settings.save")
        }
      }
    }
  }

}

private struct ThirdPartyEndpointFields: View {
  @Environment(AppModel.self) private var model

  let identifier: String
  let defaultURL: String
  let modelPrompt: LocalizedStringKey
  let hasStoredKey: Bool
  @Binding var baseURL: String
  @Binding var modelName: String
  @Binding var apiKey: String

  init(
    identifier: String,
    defaultURL: String,
    modelPrompt: LocalizedStringKey,
    hasStoredKey: Bool,
    baseURL: Binding<String>,
    model: Binding<String>,
    apiKey: Binding<String>
  ) {
    self.identifier = identifier
    self.defaultURL = defaultURL
    self.modelPrompt = modelPrompt
    self.hasStoredKey = hasStoredKey
    _baseURL = baseURL
    _modelName = model
    _apiKey = apiKey
  }

  var body: some View {
    TextField(defaultURL, text: $baseURL)
      .textInputAutocapitalization(.never)
      .keyboardType(.URL)
      .autocorrectionDisabled()
      .accessibilityLabel("Service URL")
      .accessibilityIdentifier("settings.ai.\(identifier).url")
    TextField(modelPrompt, text: $modelName)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .accessibilityIdentifier("settings.ai.\(identifier).model")
    SecureField(
      hasStoredKey
        ? model.settings.language.localized("API key (leave blank to keep)")
        : model.settings.language.localized("API key"),
      text: $apiKey
    )
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
    .accessibilityIdentifier("settings.ai.\(identifier).key")
  }
}

private struct ActionButtonSetupView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(spacing: 16) {
            Image(systemName: "record.circle.fill")
              .font(.largeTitle)
              .foregroundStyle(.red)

            VStack(spacing: 6) {
              Text("Start Recording in One Press")
                .font(.title3.weight(.semibold))
              Text(
                "Assign WakeOnCue's existing Start Recording shortcut to your iPhone Action Button."
              )
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
        }

        Section("In iPhone Settings") {
          setupStep(1, title: "Choose Action Button", icon: "button.programmable")
          setupStep(2, title: "Swipe to Shortcut", icon: "square.on.square")
          setupStep(3, title: "Tap Choose a Shortcut", icon: "hand.tap")
          setupStep(4, title: "Select Start Recording under WakeOnCue", icon: "record.circle")
        }

        Section("Shortcut to select") {
          HStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
              .font(.title2)
              .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
              Text("Start Recording")
                .fontWeight(.medium)
              Text("WakeOnCue")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 3)
        }

        Section {
          ShortcutsLink()
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        } header: {
          Text("WakeOnCue shortcuts")
        } footer: {
          Text(
            "The Start Recording App Shortcut is available automatically. Apple doesn't allow apps to open Action Button settings directly, so assign it once in Settings > Action Button > Shortcut."
          )
        }
      }
      .navigationTitle("Action Button")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private func setupStep(_ number: Int, title: LocalizedStringKey, icon: String) -> some View {
    HStack(spacing: 12) {
      Text("\(number)")
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(.red, in: Circle())
        .accessibilityHidden(true)

      Label(title, systemImage: icon)
    }
    .padding(.vertical, 2)
  }
}
