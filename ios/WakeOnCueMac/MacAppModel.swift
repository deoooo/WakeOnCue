import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class MacAppModel {
  let host = ProcessorHost()
  let recorder = MeetingRecorder()

  var startServicesOnLaunch: Bool {
    didSet { UserDefaults.standard.set(startServicesOnLaunch, forKey: "startServicesOnLaunch") }
  }

  /// Streams meetings to the local Gateway for live text. Recording works without it.
  var liveTranscription: Bool {
    didSet { UserDefaults.standard.set(liveTranscription, forKey: "liveTranscription") }
  }

  /// Anonymous Speaker 1 / 2 / … for the remote side; off by default like on iPhone.
  var tellSpeakersApart: Bool {
    didSet { UserDefaults.standard.set(tellSpeakersApart, forKey: "tellSpeakersApart") }
  }

  private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
  private(set) var loginItemMessage: String?

  init() {
    let defaults = UserDefaults.standard
    defaults.register(defaults: ["liveTranscription": true])
    startServicesOnLaunch = defaults.bool(forKey: "startServicesOnLaunch")
    liveTranscription = defaults.bool(forKey: "liveTranscription")
    tellSpeakersApart = defaults.bool(forKey: "tellSpeakersApart")
    if startServicesOnLaunch {
      Task { await host.start() }
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginItemMessage = nil
    } catch {
      loginItemMessage = error.localizedDescription
    }
    let status = SMAppService.mainApp.status
    launchAtLogin = status == .enabled
    if status == .requiresApproval {
      loginItemMessage = String(localized: "Approve WakeOnCue in System Settings › General › Login Items.")
    }
  }

  func startRecording() async {
    var realtime: (url: URL, token: String)?
    if liveTranscription, host.isGatewayUp, let token = GatewayToken.load() {
      realtime = (ProcessorHost.localGatewayURL, token)
    }
    await recorder.start(realtime: realtime, tellSpeakersApart: tellSpeakersApart)
  }

  func pairingPayload() -> String? {
    guard let token = GatewayToken.load() else { return nil }
    return try? PairingCode.payload(gatewayURL: host.lanGatewayURL, token: token)
  }

  func chooseCheckout() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = String(localized: "Choose the WakeOnCue folder that contains server/.")
    NSApp.activate()
    if panel.runModal() == .OK, let url = panel.url {
      host.chooseCheckout(url)
    }
  }

  func reveal(_ url: URL?) {
    guard let url else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}
