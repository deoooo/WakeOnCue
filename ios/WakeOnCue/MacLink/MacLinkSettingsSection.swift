import SwiftUI

/// Settings › Mac: whether a Mac is paired, what is still waiting for it, and how to pair.
struct MacLinkSettingsSection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let uploader = model.macUploader
    Section {
      if let pairing = uploader.pairing {
        LabeledContent("Mac", value: pairing.macName)
        LabeledContent("Waiting to send", value: String(format: AppLanguage.localized("%lld pieces"), uploader.pending))
        if let lastSync = pairing.lastSync {
          LabeledContent("Last sent", value: lastSync.formatted(date: .abbreviated, time: .shortened))
        }
        statusRow(uploader.status, needsRepair: pairing.needsRepair)
        Button("Send now") { Task { await uploader.sync() } }
          .disabled(uploader.pending == 0 || pairing.needsRepair)
        Button("Unpair this Mac", role: .destructive) { uploader.unpair() }
      } else {
        Text("Not connected to a Mac.")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Mac")
    } footer: {
      Text("On the Mac, open WakeOnCue › Settings › Devices and scan its pairing code with the Camera app. Watch and iPhone recordings then go to the Mac over your local network, encrypted with the pairing key, and are deleted here only after the Mac confirms it has them.")
    }
  }

  @ViewBuilder private func statusRow(_ status: MacUploader.Status, needsRepair: Bool) -> some View {
    switch status {
    case .idle:
      if needsRepair {
        Label("Scan the Mac's pairing code again.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
    case .sending(let done, let total):
      ProgressView(value: Double(done), total: Double(max(total, 1))) {
        Text(String(format: AppLanguage.localized("Sending %lld of %lld"), done + 1, total))
      }
    case .unreachable:
      Text("The Mac is not on this network. Waiting pieces are sent when it is.").foregroundStyle(.secondary)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }
  }
}
