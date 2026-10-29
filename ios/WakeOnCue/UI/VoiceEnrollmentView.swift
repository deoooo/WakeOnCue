import AVFoundation
import SwiftUI
import WakeOnCueCore

/// Settings for telling speakers apart, the user's own voice and remembered voices.
struct SpeakerSettingsSection: View {
  @Environment(AppModel.self) private var model
  @State private var isRememberConsentPresented = false
  @State private var isForgetAllConfirmationPresented = false
  @State private var errorMessage: String?

  var body: some View {
    @Bindable var settings = model.settings
    Section {
      Toggle(isOn: $settings.speakerDiarizationEnabled) {
        Label("Tell speakers apart", systemImage: "person.2.wave.2")
      }
      .accessibilityIdentifier("settings.speakers.diarization")
      if settings.speakerDiarizationEnabled {
        SelfVoiceSettingsRows()
        Toggle(isOn: rememberBinding) {
          Label("Remember voices", systemImage: "person.crop.circle.badge.checkmark")
        }
        .accessibilityIdentifier("settings.speakers.remember")
        if settings.rememberVoicesEnabled {
          NavigationLink {
            SavedVoicesView()
          } label: {
            LabeledContent("Saved voices", value: "\(settings.savedVoices.count)")
          }
        }
      }
    } header: {
      Text("Speakers")
    } footer: {
      Text(
        "Off by default. When on, your own realtime service labels each line Speaker 1, Speaker 2 and so on; you can name them per recording. Enroll your voice to be labeled Me."
      )
    }
    .alert("Remember voices?", isPresented: $isRememberConsentPresented) {
      Button("Cancel", role: .cancel) {}
      Button("Turn On") { setRemember(true) }
    } message: {
      Text(
        "When you name a speaker and choose Remember voice, WakeOnCue saves a voiceprint of that person on this iPhone and uses it to name them in later recordings. Voiceprints are biometric data: only remember people who agreed. Voices not heard for a year are deleted, and turning this off deletes them all."
      )
    }
    .confirmationDialog(
      "Delete all saved voices?",
      isPresented: $isForgetAllConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Turn Off and Delete", role: .destructive) { setRemember(false) }
    } message: {
      Text("Names already given to speakers in recordings stay.")
    }
    .alert("Could not update saved voices", isPresented: errorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var rememberBinding: Binding<Bool> {
    Binding(
      get: { model.settings.rememberVoicesEnabled },
      set: { enabled in
        if enabled {
          isRememberConsentPresented = true
        } else if model.settings.savedVoices.isEmpty {
          setRemember(false)
        } else {
          isForgetAllConfirmationPresented = true
        }
      }
    )
  }

  private func setRemember(_ enabled: Bool) {
    do {
      try model.settings.setRememberVoices(enabled)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }
}

/// Remembered voices: rename or delete each one.
struct SavedVoicesView: View {
  @Environment(AppModel.self) private var model
  @State private var renaming: SavedVoice?
  @State private var newName = ""
  @State private var errorMessage: String?

  var body: some View {
    List {
      Section {
        ForEach(model.settings.savedVoices) { voice in
          Button {
            newName = voice.name
            renaming = voice
          } label: {
            LabeledContent(voice.name) {
              Text(voice.lastHeardAt.formatted(date: .abbreviated, time: .omitted))
            }
          }
          .foregroundStyle(.primary)
        }
        .onDelete { offsets in
          do {
            for voice in offsets.map({ model.settings.savedVoices[$0] }) {
              try model.settings.deleteSavedVoice(id: voice.id)
            }
          } catch {
            errorMessage = error.localizedDescription
          }
        }
      } footer: {
        Text("Dates show when each voice was last heard. Voices not heard for a year are deleted.")
      }
    }
    .overlay {
      if model.settings.savedVoices.isEmpty {
        ContentUnavailableView(
          "No saved voices",
          systemImage: "person.wave.2",
          description: Text("Name a speaker in a recording and choose Remember voice.")
        )
      }
    }
    .navigationTitle("Saved voices")
    .alert("Rename voice", isPresented: renameBinding) {
      TextField("Name", text: $newName)
      Button("Cancel", role: .cancel) { renaming = nil }
      Button("Save") {
        if let voice = renaming,
          case let name = newName.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        {
          do { try model.settings.renameSavedVoice(id: voice.id, to: name) } catch {
            errorMessage = error.localizedDescription
          }
        }
        renaming = nil
      }
    }
    .alert("Could not update saved voices", isPresented: errorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var renameBinding: Binding<Bool> {
    Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
  }

  private var errorBinding: Binding<Bool> {
    Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
  }
}

/// Settings rows for the device owner's own voiceprint: enroll, re-enroll and delete.
struct SelfVoiceSettingsRows: View {
  @Environment(AppModel.self) private var model
  @State private var isEnrollmentPresented = false
  @State private var isDeleteConfirmationPresented = false
  @State private var deleteErrorMessage: String?

  var body: some View {
    let settings = model.settings
    Group {
      if let enrolledAt = settings.selfVoiceprintEnrolledAt {
        LabeledContent {
          Text(enrolledAt.formatted(date: .abbreviated, time: .omitted))
        } label: {
          Label("My voice enrolled", systemImage: "person.wave.2.fill")
        }
        .accessibilityIdentifier("settings.voice.enrolled")
        Button {
          isEnrollmentPresented = true
        } label: {
          Label("Enroll again", systemImage: "arrow.clockwise")
        }
        .disabled(!canEnroll)
        Button(role: .destructive) {
          isDeleteConfirmationPresented = true
        } label: {
          Label("Delete my voiceprint", systemImage: "trash")
        }
        .accessibilityIdentifier("settings.voice.delete")
      } else {
        Button {
          isEnrollmentPresented = true
        } label: {
          Label("Enroll my voice", systemImage: "person.wave.2")
        }
        .disabled(!canEnroll)
        .accessibilityIdentifier("settings.voice.enroll")
      }
      if !canEnroll {
        Text("Finish recording or playback before enrolling your voice.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .sheet(isPresented: $isEnrollmentPresented) {
      VoiceEnrollmentView()
    }
    .confirmationDialog(
      "Delete my voiceprint?",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        do {
          try settings.deleteSelfVoiceprint()
        } catch {
          deleteErrorMessage = error.localizedDescription
        }
      }
    } message: {
      Text("New transcripts will no longer label your lines as Me. Existing transcripts keep their labels.")
    }
    .alert("Could not delete voiceprint", isPresented: deleteErrorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(deleteErrorMessage ?? "")
    }
  }

  private var canEnroll: Bool {
    model.currentRecording == nil && model.audioBusyRecordingID == nil
      && model.playingRecordingID == nil
  }

  private var deleteErrorBinding: Binding<Bool> {
    Binding(
      get: { deleteErrorMessage != nil },
      set: { if !$0 { deleteErrorMessage = nil } }
    )
  }
}

/// Records a short sample of the user reading aloud, turns it into a voiceprint on the
/// user's own realtime service, and stores only the voiceprint on this iPhone.
struct VoiceEnrollmentView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var stage = Stage.consent
  @State private var progress = 0.0
  @State private var level: Float = 0
  @State private var enrollmentTask: Task<Void, Never>?

  private enum Stage: Equatable {
    case consent
    case recording
    case analyzing
    case enrolled
    case failed(String)
  }

  var body: some View {
    NavigationStack {
      Form {
        switch stage {
        case .consent:
          consent
        case .recording:
          recording
        case .analyzing:
          Section {
            HStack(spacing: 12) {
              ProgressView()
              Text("Analyzing your voice…")
            }
          }
        case .enrolled:
          Section {
            Label("Your voice is enrolled", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .accessibilityIdentifier("voice-enrollment.done")
            Text("New transcripts will label your lines as Me.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        case .failed(let message):
          Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Button("Try again") { stage = .consent }
          }
        }
      }
      .navigationTitle("My voice")
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(stage == .recording || stage == .analyzing)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if stage != .enrolled {
            Button("Cancel") {
              enrollmentTask?.cancel()
              dismiss()
            }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if stage == .enrolled {
            Button("Done") { dismiss() }
          }
        }
      }
    }
    .onDisappear { enrollmentTask?.cancel() }
  }

  private var consent: some View {
    Group {
      Section {
        Label(
          "Your voiceprint lets transcripts label your own lines as Me.",
          systemImage: "person.fill.checkmark"
        )
        Label(
          "Your voiceprint is stored only in this iPhone's Keychain. It is not backed up, synced, or uploaded to cloud storage.",
          systemImage: "lock.iphone"
        )
        Label(
          "The sample is sent once to your own realtime service to compute the voiceprint, and is not kept there or on this iPhone.",
          systemImage: "waveform.badge.minus"
        )
        Label(
          "You can delete your voiceprint at any time in Settings.",
          systemImage: "trash"
        )
      } header: {
        Text("Before you start")
      } footer: {
        Text("Your voiceprint is biometric data. Only enroll your own voice.")
      }
      Section {
        Button {
          startEnrollment()
        } label: {
          Label("Agree and record 20 seconds", systemImage: "mic.fill")
        }
        .accessibilityIdentifier("voice-enrollment.start")
      }
    }
  }

  private var recording: some View {
    Group {
      Section {
        Text(
          "Please read this aloud at a normal pace: Today I am setting up WakeOnCue so it can recognize my voice. I usually talk about plans, meetings, and new ideas, and I want my notes to show which words are mine. If I finish this text before the recording ends, I will keep talking naturally about what I am working on this week."
        )
        .font(.body)
        .padding(.vertical, 4)
      } header: {
        Text("Read aloud")
      } footer: {
        Text("Use a quiet place. Only your voice should be heard.")
      }
      Section {
        ProgressView(value: progress)
          .accessibilityLabel(Text("Recording progress"))
        ProgressView(value: Double(level))
          .tint(level > 0.15 ? .green : .orange)
          .accessibilityLabel(Text("Input level"))
      }
    }
  }

  private func startEnrollment() {
    enrollmentTask?.cancel()
    enrollmentTask = Task { await enroll() }
  }

  private func enroll() async {
    let settings = model.settings
    let configuration: RealtimeProcessingConfiguration
    do {
      configuration = try settings.voiceEnrollmentConfiguration()
    } catch {
      stage = .failed(error.localizedDescription)
      return
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      stage = .failed(
        AppLanguage.localized("Allow microphone access in iPhone Settings to enroll your voice."))
      return
    }

    let recorder = VoiceEnrollmentRecorder()
    do {
      try recorder.start()
    } catch {
      stage = .failed(error.localizedDescription)
      return
    }
    stage = .recording
    progress = 0
    let duration = RealtimeVoiceprintEnrollmentRequest.recommendedDuration
    while !Task.isCancelled, recorder.capturedDuration < duration {
      try? await Task.sleep(for: .milliseconds(100))
      progress = min(1, recorder.capturedDuration / duration)
      level = recorder.consumeLevel()
    }
    let sample = recorder.stop()
    guard !Task.isCancelled else { return }

    stage = .analyzing
    do {
      let response = try await RealtimeProcessingClient.enrollVoiceprint(
        configuration: configuration,
        pcm16LittleEndian: sample
      )
      try settings.persistSelfVoiceprint(response.voiceprint)
      stage = .enrolled
    } catch is CancellationError {
      return
    } catch let error as URLError where error.code == .cancelled {
      return
    } catch {
      stage = .failed(error.localizedDescription)
    }
  }
}
