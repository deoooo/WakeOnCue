import AppIntents
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var isActionButtonSetupPresented = false
  @State private var isEditingS3Configuration = false
  @State private var isS3AdvancedPresented = false
  @State private var isRealtimeAdvancedPresented = false
  @State private var isRealtimePairingPresented = false
  @State private var realtimeConnectionCheck = RealtimeConnectionCheck.idle

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

        Section {
          Toggle(isOn: $settings.useS3) {
            Label("Sync to S3", systemImage: "externaldrive.connected.to.line.below")
          }
          .accessibilityIdentifier("settings.storage.s3.toggle")

          if settings.useS3 {
            if settings.s3HasStoredCredentials, !isEditingS3Configuration {
              Label("S3 configuration saved", systemImage: "key.fill")
                .foregroundStyle(.secondary)
              LabeledContent("Bucket", value: settings.s3Bucket)
              LabeledContent("Region", value: settings.s3Region)

              Button {
                isEditingS3Configuration = true
              } label: {
                Label("Modify S3 configuration", systemImage: "pencil")
              }
            } else {
              TextField("Bucket", text: $settings.s3Bucket)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.storage.s3.bucket")
              TextField("Region, e.g. us-east-1", text: $settings.s3Region)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.storage.s3.region")
              TextField(
                settings.s3HasStoredCredentials
                  ? settings.language.localized("Access key (leave blank to keep)")
                  : settings.language.localized("Access key"),
                text: $settings.s3AccessKeyID
              )
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("settings.storage.s3.access-key")
              SecureField(
                settings.s3HasStoredCredentials
                  ? settings.language.localized("Secret key (leave blank to keep)")
                  : settings.language.localized("Secret key"),
                text: $settings.s3SecretAccessKey
              )
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("settings.storage.s3.secret-key")

              DisclosureGroup("Advanced", isExpanded: $isS3AdvancedPresented) {
                TextField("Custom endpoint (optional)", text: $settings.s3EndpointURL)
                  .textInputAutocapitalization(.never)
                  .keyboardType(.URL)
                  .autocorrectionDisabled()
                  .accessibilityIdentifier("settings.storage.s3.endpoint")
                TextField("Object prefix", text: $settings.s3Prefix)
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                  .accessibilityIdentifier("settings.storage.s3.prefix")
                SecureField("Session token (optional)", text: $settings.s3SessionToken)
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                  .accessibilityIdentifier("settings.storage.s3.session-token")
                Toggle("Force path-style URLs", isOn: $settings.s3ForcePathStyle)
                  .accessibilityIdentifier("settings.storage.s3.path-style")
              }
            }
          }
        } header: {
          Text("Storage")
        } footer: {
          if settings.useS3 {
            if settings.s3HasStoredCredentials, !isEditingS3Configuration {
              Text("Credentials are securely stored in this iPhone's Keychain.")
            } else {
              Text(
                "Save verifies S3 with a tiny temporary object. Raw audio is removed only after the complete M4A reaches S3. Credentials stay in this iPhone's Keychain."
              )
            }
          } else {
            Text("Local is the default. Recordings stay on this iPhone without a cloud account.")
          }
        }

        if settings.useS3 {
          Section {
            Stepper(
              value: $settings.localAudioRetentionDays,
              in: AppSettings.localAudioRetentionDaysRange
            ) {
              LabeledContent("Keep complete M4A") {
                Text(retentionLabel(days: settings.localAudioRetentionDays))
                  .foregroundStyle(.secondary)
              }
            }
          } header: {
            Text("Local cache")
          } footer: {
            Text(
              "After this period, the local M4A is removed. Playing or sharing downloads the real file from S3 and caches it again."
            )
          }
        }

        Section {
          Toggle(isOn: $settings.useRealtimeProcessing) {
            Label("Live transcription", systemImage: "captions.bubble.fill")
          }
          .accessibilityIdentifier("settings.transcription.toggle")

          if settings.useRealtimeProcessing {
            Picker("Spoken language", selection: $settings.spokenLanguage) {
              ForEach(SpokenLanguage.allCases) { language in
                Text(language.title).tag(language)
              }
            }
            if settings.realtimeHasStoredToken {
              Label("Gateway credentials saved", systemImage: "key.fill")
                .foregroundStyle(.secondary)
            }

            Button {
              isRealtimePairingPresented = true
            } label: {
              Label("Pair self-hosted service", systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("settings.transcription.pair")

            Button {
              Task { await testRealtimeConnection(settings: settings) }
            } label: {
              if realtimeConnectionCheck.isTesting {
                HStack {
                  ProgressView().controlSize(.small)
                  Text("Testing connection…")
                }
              } else {
                Label("Test connection", systemImage: "network")
              }
            }
            .disabled(realtimeConnectionCheck.isTesting)
            .accessibilityIdentifier("settings.transcription.test-connection")

            if let result = realtimeConnectionCheck.result {
              Label(
                result.message,
                systemImage: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill"
              )
                .font(.footnote)
                .foregroundStyle(result.isError ? .orange : .green)
                .accessibilityIdentifier("settings.transcription.connection-result")
            }

            DisclosureGroup("Manual setup", isExpanded: $isRealtimeAdvancedPresented) {
              TextField("Gateway URL", text: $settings.realtimeGatewayURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.transcription.gateway-url")
                .onChange(of: settings.realtimeGatewayURL) { _, _ in
                  realtimeConnectionCheck = .idle
                }
              SecureField(
                settings.realtimeHasStoredToken
                  ? settings.language.localized("Gateway token (leave blank to keep)")
                  : settings.language.localized("Gateway token"),
                text: $settings.realtimeGatewayToken
              )
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("settings.transcription.gateway-token")
              .onChange(of: settings.realtimeGatewayToken) { _, _ in
                realtimeConnectionCheck = .idle
              }
            }
          }
        } header: {
          Text("Live transcription")
        } footer: {
          Text(
            "Optional. Pair your own Gateway by QR code or paste its pairing JSON. Save checks the service and token before storing them. Audio always saves locally first."
          )
        }

        if settings.useRealtimeProcessing {
          SpeakerSettingsSection()
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
      .scrollContentBackground(.hidden)
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .sheet(isPresented: $isActionButtonSetupPresented) {
        ActionButtonSetupView()
      }
      .sheet(isPresented: $isRealtimePairingPresented) {
        RealtimePairingView { pairing in
          settings.applyRealtimePairing(pairing)
          isRealtimePairingPresented = false
          Task { await model.saveSettings() }
        }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { model.cancelSettings() }
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

  private func retentionLabel(days: Int) -> String {
    days == 1
      ? model.settings.language.localized("1 day")
      : String(
        format: model.settings.language.localized("%d days"),
        locale: model.settings.language.locale,
        days
      )
  }

  @MainActor
  private func testRealtimeConnection(settings: AppSettings) async {
    realtimeConnectionCheck = .testing
    do {
      let configuration = try settings.candidateRealtimeConfiguration()
      try await RealtimeProcessingClient.validate(configuration: configuration)
      realtimeConnectionCheck = .success(
        AppLanguage.localized("Connection verified just now. Save to keep this configuration."))
    } catch let error as RealtimeClientError {
      switch error {
      case .validationFailed:
        realtimeConnectionCheck = .failure(
          AppLanguage.localized(
            "The Gateway rejected the token or does not support WakeOnCue protocol v1. Check the token and service version."
          ))
      default:
        realtimeConnectionCheck = .failure(error.localizedDescription)
      }
    } catch let error as URLError {
      realtimeConnectionCheck = .failure(
        String(
          format: AppLanguage.localized(
            "Could not reach the Gateway: %@ Check the URL, network, and Gateway process."
          ),
          error.localizedDescription
        ))
    } catch {
      realtimeConnectionCheck = .failure(error.localizedDescription)
    }
  }

}

private enum RealtimeConnectionCheck: Equatable {
  case idle
  case testing
  case success(String)
  case failure(String)

  var isTesting: Bool { self == .testing }

  var result: (message: String, isError: Bool)? {
    switch self {
    case .success(let message): (message, false)
    case .failure(let message): (message, true)
    case .idle, .testing: nil
    }
  }
}

private struct RealtimePairingView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var mode = PairingInputMode.camera
  @State private var pastedPayload = ""
  @State private var candidate: RealtimeServicePairing?
  @State private var errorMessage: String?

  let onConfirm: (RealtimeServicePairing) -> Void

  var body: some View {
    NavigationStack {
      Form {
        if let candidate {
          Section("Review service") {
            LabeledContent("Gateway", value: candidate.gatewayURL.absoluteString)
            LabeledContent("Transport", value: transportLabel(candidate.gatewayURL))
            LabeledContent("Token", value: maskedToken(candidate.gatewayToken))
          }

          Section {
            Button {
              onConfirm(candidate)
            } label: {
              Label("Verify and save", systemImage: "checkmark.shield")
            }
            Button("Scan or paste a different code") {
              self.candidate = nil
              errorMessage = nil
            }
          } footer: {
            Text("WakeOnCue will contact this Gateway and validate the token before saving it.")
          }
        } else {
          Section {
            Picker("Pair using", selection: $mode) {
              ForEach(PairingInputMode.allCases) { inputMode in
                Text(inputMode.title).tag(inputMode)
              }
            }
            .pickerStyle(.segmented)

            if mode == .camera {
              RealtimePairingScanner(
                onPayload: decode,
                onError: { errorMessage = $0 }
              )
              .frame(height: 300)
              .clipShape(RoundedRectangle(cornerRadius: 12))
              .overlay {
                RoundedRectangle(cornerRadius: 12)
                  .stroke(.white.opacity(0.7), lineWidth: 2)
                  .frame(width: 210, height: 210)
              }
              .accessibilityLabel("QR code scanner")
            } else {
              TextEditor(text: $pastedPayload)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: 150)
                .font(.system(.footnote, design: .monospaced))
              Button("Review pairing") { decode(pastedPayload) }
                .disabled(pastedPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          } header: {
            Text("Self-hosted Gateway")
          } footer: {
            Text("Pairing data contains a service URL and secret token. Review both before saving.")
          }
        }

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          } footer: {
            if mode == .camera {
              Text("Try again, or choose Paste and enter the complete pairing JSON.")
            } else {
              Text("Copy the complete JSON generated by the WakeOnCue pairing command.")
            }
          }
        }
      }
      .navigationTitle("Pair service")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private func decode(_ payload: String) {
    do {
      candidate = try RealtimeServicePairing(payload: payload)
      errorMessage = nil
    } catch {
      candidate = nil
      errorMessage = error.localizedDescription
    }
  }

  private func maskedToken(_ token: String) -> String {
    guard token.count > 8 else { return String(repeating: "•", count: token.count) }
    return "\(token.prefix(4))••••\(token.suffix(4))"
  }

  private func transportLabel(_ url: URL) -> String {
    url.scheme?.lowercased() == "https"
      ? AppLanguage.localized("Encrypted HTTPS")
      : AppLanguage.localized("HTTP (use only on a trusted private network)")
  }
}

private enum PairingInputMode: String, CaseIterable, Identifiable {
  case camera
  case paste

  var id: Self { self }
  var title: LocalizedStringKey {
    switch self {
    case .camera: "Scan QR"
    case .paste: "Paste"
    }
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
