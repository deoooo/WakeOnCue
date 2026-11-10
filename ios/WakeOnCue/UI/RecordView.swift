import SwiftUI
import UniformTypeIdentifiers
import WakeOnCueCore

/// The Record tab: one large button when idle; the timer, sound level, Pause and Finish while
/// recording.
struct RecordView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var dismissedRecordingID: String?
  @State private var isImporting = false

  private var status: RecordingStatus? { model.currentRecording?.status }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          if model.microphonePermission != .granted { permissionBanner }
          switch status {
          case .recording, .paused: activeRecorder
          case .finishing, .uploading: finishing
          default: idle
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
      }
      .background(Color(uiColor: .systemBackground).ignoresSafeArea())
      .toolbar(.hidden, for: .navigationBar)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if status == .recording || status == .paused { controls }
      }
      .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
        guard case .success(let urls) = result else { return }
        Task { await model.importAudioFiles(urls) }
      }
    }
    .accessibilityIdentifier("record")
  }

  // MARK: Idle

  private var idle: some View {
    VStack(spacing: 22) {
      Label("iPhone microphone", systemImage: "iphone")
        .font(.footnote)
        .foregroundStyle(.secondary)

      Button {
        Task { await model.startRecording() }
      } label: {
        ZStack {
          Circle().fill(WakeOnCueColors.record.opacity(0.16)).frame(width: 148, height: 148)
          Circle().fill(WakeOnCueColors.record).frame(width: 120, height: 120)
            .shadow(color: WakeOnCueColors.record.opacity(0.35), radius: 18, y: 8)
          Image(systemName: "mic.fill").font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
        }
      }
      .buttonStyle(RecordButtonStyle())
      .disabled(model.isBusy || model.microphonePermission == .denied)
      .accessibilityLabel("Start recording")
      .accessibilityIdentifier("start-recording")
      .padding(.top, 24)

      VStack(spacing: 6) {
        Text("Tap to start recording").font(.title3.weight(.semibold))
        Text("When you finish, it is transcribed and gets a title and a summary.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      if let finished = model.lastFinishedRecording, dismissedRecordingID != finished.id {
        RecordingCompletionCard(recording: finished) { dismissedRecordingID = finished.id }
          .id(finished.id)
      }

      HStack(spacing: 12) {
        Image(systemName: "applewatch").foregroundStyle(.secondary)
        Text("You can also start on Apple Watch, the Lock Screen or the Action Button.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(14)
      .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

      Button {
        isImporting = true
      } label: {
        Label("Import audio file", systemImage: "square.and.arrow.down")
          .frame(minHeight: 44)
      }
      .accessibilityIdentifier("import-audio")
    }
  }

  // MARK: Recording

  private var activeRecorder: some View {
    VStack(spacing: 16) {
      HStack(spacing: 8) {
        Circle().fill(status == .paused ? Color.orange : WakeOnCueColors.record).frame(width: 9, height: 9)
        Text(status == .paused ? "Paused" : "Recording")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(status == .paused ? Color.orange : WakeOnCueColors.record)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("recording-status")
      .padding(.top, 24)

      Text(elapsedText)
        .font(.system(size: 60, weight: .light, design: .rounded))
        .monospacedDigit()
        .minimumScaleFactor(0.6)
        .accessibilityLabel("Elapsed recording time")

      Label("iPhone microphone", systemImage: "iphone")
        .font(.footnote)
        .foregroundStyle(.secondary)

      LiveCaptureFeedbackView()

      Text("Saved on this iPhone as you record. You can lock the screen.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }

  private var controls: some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 40))
    return layout {
      Button {
        Task { await model.finishRecording() }
      } label: {
        VStack(spacing: 6) {
          ZStack {
            Circle().stroke(WakeOnCueColors.record, lineWidth: 3).frame(width: 72, height: 72)
            RoundedRectangle(cornerRadius: 6).fill(WakeOnCueColors.record).frame(width: 24, height: 24)
          }
          Text("Finish").font(.footnote.weight(.semibold))
        }
      }
      .buttonStyle(RecordButtonStyle())
      .disabled(model.isBusy)
      .accessibilityIdentifier("finish-recording")

      Button {
        Task {
          if status == .paused { await model.resumeRecording() } else { await model.pauseRecording() }
        }
      } label: {
        VStack(spacing: 6) {
          Image(systemName: status == .paused ? "play.fill" : "pause.fill")
            .font(.title2)
            .frame(width: 60, height: 60)
            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
          Text(status == .paused ? "Resume" : "Pause").font(.footnote)
        }
      }
      .buttonStyle(RecordButtonStyle())
      .disabled(model.isBusy)
      .accessibilityIdentifier(status == .paused ? "resume-recording" : "pause-recording")
    }
    .foregroundStyle(.primary)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .background(.bar)
  }

  private var finishing: some View {
    VStack(spacing: 14) {
      ProgressView().controlSize(.large).padding(.top, 60)
      Text("Finishing your local recording")
        .font(.headline)
      Button {
        Task { await model.finishLocally() }
      } label: {
        Label("Save to this iPhone", systemImage: "iphone.and.arrow.forward")
      }
      .buttonStyle(.bordered)
      .disabled(model.isBusy)
    }
  }

  private var elapsedText: String {
    let seconds = max(0, Int(model.elapsed.rounded(.down)))
    if seconds >= 3_600 {
      return String(format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }

  private var permissionBanner: some View {
    HStack(spacing: 13) {
      Image(systemName: "mic.badge.plus")
        .font(.title3.weight(.semibold))
        .foregroundStyle(WakeOnCueColors.record)
      VStack(alignment: .leading, spacing: 3) {
        Text("Microphone access").font(.subheadline.weight(.semibold))
        Text("Audio always saves locally first.").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Button(
        model.microphonePermission == .denied
          ? model.settings.language.localized("Settings")
          : model.settings.language.localized("Allow")
      ) {
        if model.microphonePermission == .denied {
          model.openSystemSettings()
        } else {
          Task { _ = await model.requestMicrophonePermission() }
        }
      }
      .font(.subheadline.weight(.semibold))
      .buttonStyle(.bordered)
    }
    .padding(14)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}
