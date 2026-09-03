import AppIntents
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var isActionButtonSetupPresented = false
  @State private var isEditingS3Configuration = false

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
          Toggle(isOn: $settings.useS3) {
            Label("Store in S3", systemImage: "externaldrive.connected.to.line.below")
          }

          if settings.useS3 {
            if settings.s3HasStoredCredentials, !isEditingS3Configuration {
              Label("S3 connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
              LabeledContent("Bucket", value: settings.s3Bucket)
              LabeledContent("Region", value: settings.s3Region)
              LabeledContent("Endpoint", value: endpointSummary(settings.s3EndpointURL))

              Button {
                isEditingS3Configuration = true
              } label: {
                Label("Modify S3 configuration", systemImage: "pencil")
              }
            } else {
              TextField("Bucket", text: $settings.s3Bucket)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              TextField("Region, e.g. us-east-1", text: $settings.s3Region)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              TextField("Custom endpoint (optional)", text: $settings.s3EndpointURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
              TextField("Object prefix", text: $settings.s3Prefix)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              TextField(
                settings.s3HasStoredCredentials
                  ? settings.language.localized("Access key (leave blank to keep)")
                  : settings.language.localized("Access key"),
                text: $settings.s3AccessKeyID
              )
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              SecureField(
                settings.s3HasStoredCredentials
                  ? settings.language.localized("Secret key (leave blank to keep)")
                  : settings.language.localized("Secret key"),
                text: $settings.s3SecretAccessKey
              )
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              SecureField("Session token (optional)", text: $settings.s3SessionToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              Toggle("Force path-style URLs", isOn: $settings.s3ForcePathStyle)
            }
          }
        } header: {
          Text("Recording storage")
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
            Text("Without S3, recordings stay only on this iPhone.")
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

          if settings.useRealtimeProcessing {
            Picker("Spoken language", selection: $settings.spokenLanguage) {
              ForEach(SpokenLanguage.allCases) { language in
                Text(language.title).tag(language)
              }
            }
            if settings.realtimeHasStoredToken {
              Label("Realtime Gateway connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
            TextField("Gateway URL", text: $settings.realtimeGatewayURL)
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
              .autocorrectionDisabled()
            SecureField(
              settings.realtimeHasStoredToken
                ? settings.language.localized("Gateway token (leave blank to keep)")
                : settings.language.localized("Gateway token"),
              text: $settings.realtimeGatewayToken
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          }
        } header: {
          Text("Realtime processing")
        } footer: {
          Text(
            "Spoken language affects recognition only, not the app interface. Automatic detection locks the first reliably detected language for the recording. Audio still saves locally first; failures only affect live text."
          )
        }

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
      .background(Color(red: 0.035, green: 0.055, blue: 0.09))
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .sheet(isPresented: $isActionButtonSetupPresented) {
        ActionButtonSetupView()
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

  private func endpointSummary(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Amazon S3" }
    return URL(string: trimmed)?.host ?? trimmed
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
              .font(.system(size: 52))
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
            .shortcutsLinkStyle(.dark)
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
