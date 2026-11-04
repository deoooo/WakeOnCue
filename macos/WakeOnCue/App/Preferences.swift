import Foundation
import Observation

/// An app whose sound may be recorded. Helper processes share a bundle ID prefix, so audio
/// from any process whose bundle ID starts with one of `bundlePrefixes` counts as this app.
struct MeetingApp: Codable, Hashable, Identifiable {
  var name: String
  var bundlePrefixes: [String]
  var enabled: Bool
  var note: String = ""

  var id: String { bundlePrefixes.first ?? name }

  func matches(_ bundleID: String) -> Bool {
    bundlePrefixes.contains { bundleID.hasPrefix($0) }
  }

  static let defaults: [MeetingApp] = [
    MeetingApp(name: "飞书", bundlePrefixes: ["com.bytedance.macos.feishu", "com.electron.lark", "com.larksuite"], enabled: true),
    MeetingApp(name: "腾讯会议", bundlePrefixes: ["com.tencent.meeting"], enabled: true),
    MeetingApp(name: "钉钉", bundlePrefixes: ["com.alibaba.DingTalkMac", "com.alibaba.dingtalk"], enabled: true),
    // FaceTime calls play through the conference daemon, not the app.
    MeetingApp(name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"], enabled: true),
    MeetingApp(name: "微信", bundlePrefixes: ["com.tencent.xinWeChat"], enabled: false, note: "也会录到视频和语音消息"),
    MeetingApp(name: "Google Chrome", bundlePrefixes: ["com.google.Chrome"], enabled: false, note: "分不出标签页，音乐也会被录"),
  ]
}

enum MicrophoneChoice: String, CaseIterable {
  case builtIn
  case systemDefault

  var label: String {
    switch self {
    case .builtIn: "内建麦克风（推荐）"
    case .systemDefault: "跟随系统默认设备"
    }
  }
}

enum SummaryEngineChoice: String, CaseIterable {
  /// Apple Intelligence when this Mac has it, otherwise the gateway.
  case automatic
  /// Always the gateway, even when Apple Intelligence is available.
  case gateway

  var label: String {
    switch self {
    case .automatic: "自动（优先本机 Apple 智能）"
    case .gateway: "始终使用网关"
    }
  }
}

/// User settings, stored in UserDefaults. The gateway's API key is in the keychain instead.
@Observable
final class Preferences {
  @ObservationIgnored private let defaults = UserDefaults.standard

  var alwaysRecord: Bool { didSet { defaults.set(alwaysRecord, forKey: "alwaysRecord") } }
  var microphone: MicrophoneChoice { didSet { defaults.set(microphone.rawValue, forKey: "microphone") } }
  var meetingApps: [MeetingApp] {
    didSet { defaults.set(try? JSONEncoder().encode(meetingApps), forKey: "meetingApps") }
  }
  /// Days to keep audio; 0 keeps it forever.
  var audioRetentionDays: Int { didSet { defaults.set(audioRetentionDays, forKey: "audioRetentionDays") } }
  /// Days to keep transcripts and summaries; 0 keeps them forever.
  var textRetentionDays: Int { didSet { defaults.set(textRetentionDays, forKey: "textRetentionDays") } }
  var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
  /// Recording is paused until this time; `.distantFuture` pauses until the user resumes.
  var pausedUntil: Date? { didSet { defaults.set(pausedUntil, forKey: "pausedUntil") } }
  var summaryEngine: SummaryEngineChoice { didSet { defaults.set(summaryEngine.rawValue, forKey: "summaryEngine") } }
  var gatewayProtocol: GatewayProtocol { didSet { defaults.set(gatewayProtocol.rawValue, forKey: "gatewayProtocol") } }
  var gatewayBearerForAnthropic: Bool { didSet { defaults.set(gatewayBearerForAnthropic, forKey: "gatewayBearerForAnthropic") } }
  var gatewayBaseURL: String { didSet { defaults.set(gatewayBaseURL, forKey: "gatewayBaseURL") } }
  var gatewayModel: String { didSet { defaults.set(gatewayModel, forKey: "gatewayModel") } }
  /// The gateway host the user agreed to send transcripts to; another host needs a new consent.
  var gatewayConsentHost: String? { didSet { defaults.set(gatewayConsentHost, forKey: "gatewayConsentHost") } }

  init() {
    alwaysRecord = defaults.object(forKey: "alwaysRecord") as? Bool ?? true
    microphone = MicrophoneChoice(rawValue: defaults.string(forKey: "microphone") ?? "") ?? .builtIn
    meetingApps = (defaults.data(forKey: "meetingApps")).flatMap { try? JSONDecoder().decode([MeetingApp].self, from: $0) }
      ?? MeetingApp.defaults
    audioRetentionDays = defaults.object(forKey: "audioRetentionDays") as? Int ?? 30
    textRetentionDays = defaults.object(forKey: "textRetentionDays") as? Int ?? 0
    onboarded = defaults.bool(forKey: "onboarded")
    pausedUntil = defaults.object(forKey: "pausedUntil") as? Date
    summaryEngine = SummaryEngineChoice(rawValue: defaults.string(forKey: "summaryEngine") ?? "") ?? .automatic
    gatewayProtocol = GatewayProtocol(rawValue: defaults.string(forKey: "gatewayProtocol") ?? "") ?? .chatCompletions
    gatewayBearerForAnthropic = defaults.bool(forKey: "gatewayBearerForAnthropic")
    gatewayBaseURL = defaults.string(forKey: "gatewayBaseURL") ?? ""
    gatewayModel = defaults.string(forKey: "gatewayModel") ?? ""
    gatewayConsentHost = defaults.string(forKey: "gatewayConsentHost")
  }
}

extension Preferences {
  /// The gateway as configured, with the key from the keychain.
  var gateway: GatewayConfig {
    GatewayConfig(
      kind: gatewayProtocol, baseURL: gatewayBaseURL, model: gatewayModel, apiKey: GatewayKeychain.read(),
      bearerForAnthropic: gatewayBearerForAnthropic)
  }
}
