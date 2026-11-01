import SwiftUI
import WakeOnCueCore

struct MenuBarView: View {
  let model: MacAppModel
  @Environment(\.openWindow) private var openWindow

  private var host: ProcessorHost { model.host }
  private var recorder: MeetingRecorder { model.recorder }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      recordingSection
      Divider()
      serviceSection
      Divider()
      settingsSection
      Divider()
      HStack {
        Button("Show Recordings") { model.reveal(recorder.lastFolder ?? MeetingRecorder.meetingsDirectory) }
        Spacer()
        Button("Quit WakeOnCue") { NSApp.terminate(nil) }
      }
      .buttonStyle(.borderless)
    }
    .padding(14)
    .frame(width: 340)
  }

  // MARK: Recording

  @ViewBuilder private var recordingSection: some View {
    Text("Online meeting").font(.headline)
    switch recorder.state {
    case .idle:
      Button {
        Task { await model.startRecording() }
      } label: {
        Label("Record Meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      Text(
        model.liveTranscription && host.isGatewayUp
          ? "Records your microphone as you and this Mac’s audio as the other participants, with live text."
          : "Records your microphone as you and this Mac’s audio as the other participants. Start the realtime service for live text."
      )
      .font(.caption).foregroundStyle(.secondary)
    case .recording(let since):
      HStack {
        Image(systemName: "record.circle.fill").foregroundStyle(.red)
        Text(since, style: .timer).monospacedDigit()
        Spacer()
        Button("Stop") { Task { await recorder.stop() } }
          .keyboardShortcut(.defaultAction)
      }
      levelRow(String(localized: "Me (microphone)"), channel: .microphone)
      levelRow(String(localized: "Others (system audio)"), channel: .system)
      if !recorder.streamStates.isEmpty {
        Text(streamSummary).font(.caption).foregroundStyle(.secondary)
      }
      Button("Show Live Transcript") { openTranscript() }
    case .finishing:
      HStack {
        ProgressView().controlSize(.small)
        Text("Saving recording…")
      }
    }
    if let warning = recorder.warning {
      Label(warning, systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func levelRow(_ title: String, channel: RealtimeAudioChannel) -> some View {
    HStack {
      Text(title).font(.caption).frame(width: 130, alignment: .leading)
      ProgressView(value: Double(recorder.levels[channel] ?? 0))
    }
  }

  private var streamSummary: String {
    let states = Array(recorder.streamStates.values)
    if states.contains(where: \.isUnavailable) {
      return String(localized: "Live text unavailable; the recording continues on this Mac.")
    }
    if states.contains(.reconnecting) { return String(localized: "Live text reconnecting…") }
    if states.contains(.waitingForProcessor) {
      return String(localized: "Live text is waiting for the processor.")
    }
    if states.contains(.processing) { return String(localized: "Live text is on.") }
    return String(localized: "Connecting live text…")
  }

  private func openTranscript() {
    openWindow(id: WindowID.transcript)
    NSApp.activate()
  }

  // MARK: Realtime service

  @ViewBuilder private var serviceSection: some View {
    HStack {
      Text("Realtime service").font(.headline)
      Spacer()
      switch host.state {
      case .stopped, .failed:
        Button("Start") { Task { await host.start() } }
          .disabled(host.setupIssue != nil)
      case .starting:
        ProgressView().controlSize(.small)
      case .running(let owned):
        if owned { Button("Stop") { host.stop() } }
      }
    }
    statusRow(String(localized: "Gateway"), ok: host.isGatewayUp, detail: gatewayDetail)
    statusRow(
      String(localized: "Processor"),
      ok: host.isProcessorRegistered,
      detail: host.isProcessorRegistered
        ? String(localized: "Registered")
        : host.isGatewayUp ? String(localized: "Loading model…") : String(localized: "Not running")
    )
    if case .failed(let message) = host.state {
      Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    } else if let issue = host.setupIssue, !host.isGatewayUp {
      Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
    HStack {
      Spacer()
      if let logs = host.logDirectory {
        Button("Logs") { model.reveal(logs) }.buttonStyle(.borderless)
      }
    }
  }

  private var gatewayDetail: String {
    switch host.state {
    case .running(ownedByApp: false): String(localized: "Running (started outside the app)")
    case .running: String(localized: "Running on port \(ProcessorHost.port)")
    case .starting: String(localized: "Starting…")
    case .stopped, .failed: String(localized: "Not running")
    }
  }

  private func statusRow(_ title: String, ok: Bool, detail: String) -> some View {
    HStack(spacing: 6) {
      Circle().fill(ok ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
      Text(title).font(.caption).frame(width: 70, alignment: .leading)
      Text(detail).font(.caption).foregroundStyle(.secondary)
    }
  }

  // MARK: Settings

  @ViewBuilder private var settingsSection: some View {
    Toggle("Live transcription", isOn: Binding(get: { model.liveTranscription }, set: { model.liveTranscription = $0 }))
    Toggle(
      "Tell remote speakers apart",
      isOn: Binding(get: { model.tellSpeakersApart }, set: { model.tellSpeakersApart = $0 })
    )
    .help(Text("Labels the other participants Speaker 1, 2, … No voiceprints are saved."))
    Picker(
      "Speech model",
      selection: Binding(get: { host.backend }, set: { host.backend = $0 })
    ) {
      ForEach(ProcessorBackend.allCases) { Text($0.title).tag($0) }
    }
    .disabled(host.gatewayIsOwnedRunning)
    Toggle(
      "Start realtime service when WakeOnCue opens",
      isOn: Binding(get: { model.startServicesOnLaunch }, set: { model.startServicesOnLaunch = $0 })
    )
    Toggle(
      "Open WakeOnCue at login",
      isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
    )
    if let message = model.loginItemMessage {
      Text(message).font(.caption).foregroundStyle(.orange)
    }
    HStack {
      Text(host.checkout?.root.path ?? String(localized: "No checkout selected"))
        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      Spacer()
      Button("Choose…") { model.chooseCheckout() }.buttonStyle(.borderless).font(.caption)
    }
  }
}

extension ProcessorHost {
  var gatewayIsOwnedRunning: Bool { state == .running(ownedByApp: true) || state == .starting }
}
