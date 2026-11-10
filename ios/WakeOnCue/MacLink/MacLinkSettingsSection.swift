import SwiftUI

/// Settings › Mac: the paired Mac, what is still waiting for it, and connecting one.
struct MacLinkSettingsSection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let uploader = model.macUploader
    let flow = uploader.flow
    Section {
      if let pairing = uploader.pairing {
        if pairing.needsRepair {
          VStack(alignment: .leading, spacing: 6) {
            Label("Reconnect needed", systemImage: "exclamationmark.triangle.fill")
              .font(.headline).foregroundStyle(.orange)
            Text(String(format: AppLanguage.localized("The Mac unpaired this iPhone. %lld pieces are waiting."), uploader.pending))
              .font(.subheadline).foregroundStyle(.secondary)
            Button("Reconnect") { flow.open() }
              .buttonStyle(.borderedProminent)
              .padding(.top, 4)
          }
          .padding(.vertical, 4)
        }
        LabeledContent(pairing.macName) { statusPill(uploader.status, needsRepair: pairing.needsRepair) }
        LabeledContent("Waiting to send", value: String(format: AppLanguage.localized("%lld pieces"), uploader.pending))
        if let lastSync = pairing.lastSync {
          LabeledContent("Last sent", value: lastSync.formatted(date: .abbreviated, time: .shortened))
        }
        switch uploader.status {
        case .sending(let done, let total):
          ProgressView(value: Double(done), total: Double(max(total, 1))) {
            Text(String(format: AppLanguage.localized("Sending %lld of %lld"), done + 1, total))
          }
        case .failed(let message) where !pairing.needsRepair:
          Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default: EmptyView()
        }
        Picker("Keep the Mac's audio", selection: Binding(
          get: { MacAudioPlacement.current },
          set: { MacAudioPlacement.current = $0; if $0 == .both { Task { await uploader.sync() } } }
        )) {
          Text("On iPhone and Mac").tag(MacAudioPlacement.both)
          Text("On the Mac only").tag(MacAudioPlacement.macOnly)
        }
        .accessibilityIdentifier("settings.mac.audio-placement")
        if uploader.audioPausedForSpace {
          Label("This iPhone is nearly full, so downloading the Mac's audio is paused. Free up space and it continues.",
                systemImage: "externaldrive.badge.exclamationmark")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
        Button("Sync now") { Task { await uploader.sync() } }
          .disabled(pairing.needsRepair)
        Button("Change Mac…") { flow.open() }
        Button("Unpair", role: .destructive) { uploader.unpair() }
      } else {
        Button("Connect Mac") { flow.open() }
      }
    } header: {
      Text("Mac")
    } footer: {
      if uploader.pairing != nil {
        Text("The Mac's conversations and their text come to this iPhone on the same Wi‑Fi. With “On the Mac only”, audio plays from the Mac while you are on its network.")
      }
    }
  }

  private func statusPill(_ status: MacUploader.Status, needsRepair: Bool) -> some View {
    let (text, color): (LocalizedStringKey, Color) =
      if needsRepair { ("Not connected", .orange) }
      else if case .unreachable = status { ("Not nearby", .secondary) }
      else { ("Connected", .green) }
    return Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15), in: Capsule())
  }
}
