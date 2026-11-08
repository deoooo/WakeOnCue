import Foundation
import Observation

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
  /// Days to keep audio; 0 keeps it forever.
  var audioRetentionDays: Int { didSet { defaults.set(audioRetentionDays, forKey: "audioRetentionDays") } }
  /// Days to keep transcripts and summaries; 0 keeps them forever.
  var textRetentionDays: Int { didSet { defaults.set(textRetentionDays, forKey: "textRetentionDays") } }
  var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
  /// Recording is paused until this time; `.distantFuture` pauses until the user resumes.
  var pausedUntil: Date? { didSet { defaults.set(pausedUntil, forKey: "pausedUntil") } }
  /// Last time the recorder was known to be recording; cleared when it stops for a reason it
  /// records itself (pause, sleep, an error). Still set on the next launch means the app was not
  /// running for a while, and that time is recorded as a gap.
  var recordingHeartbeat: Date? { didSet { defaults.set(recordingHeartbeat, forKey: "recordingHeartbeat") } }
  /// The app quit normally after `recordingHeartbeat`, rather than crashing or losing power.
  var quitCleanly: Bool { didSet { defaults.set(quitCleanly, forKey: "quitCleanly") } }
  /// The user closed the "录入你的声音" hint on the day page.
  var voiceHintDismissed: Bool { didSet { defaults.set(voiceHintDismissed, forKey: "voiceHintDismissed") } }
  /// Tell other people apart as 说话人 1, 2… without keeping voiceprints.
  var splitSpeakers: Bool { didSet { defaults.set(splitSpeakers, forKey: "splitSpeakers") } }
  /// Keep named people's voiceprints in the keychain and recognize them later.
  var rememberVoices: Bool { didSet { defaults.set(rememberVoices, forKey: "rememberVoices") } }
  /// 自动回传: paired phones may send Watch and iPhone audio.
  var autoSync: Bool { didSet { defaults.set(autoSync, forKey: "autoSync") } }
  /// 内容相同时自动合并 (used when merging).
  var mergeSameContent: Bool { didSet { defaults.set(mergeSameContent, forKey: "mergeSameContent") } }
  var summaryEngine: SummaryEngineChoice { didSet { defaults.set(summaryEngine.rawValue, forKey: "summaryEngine") } }
  var gatewayProtocol: GatewayProtocol { didSet { defaults.set(gatewayProtocol.rawValue, forKey: "gatewayProtocol") } }
  var gatewayBearerForAnthropic: Bool { didSet { defaults.set(gatewayBearerForAnthropic, forKey: "gatewayBearerForAnthropic") } }
  var gatewayBaseURL: String { didSet { defaults.set(gatewayBaseURL, forKey: "gatewayBaseURL") } }
  var gatewayModel: String { didSet { defaults.set(gatewayModel, forKey: "gatewayModel") } }
  var transcriptionBaseURL: String { didSet { defaults.set(transcriptionBaseURL, forKey: "transcriptionBaseURL") } }
  var transcriptionModel: String { didSet { defaults.set(transcriptionModel, forKey: "transcriptionModel") } }
  /// The transcription host the user agreed to send audio to.
  var transcriptionConsentHost: String? { didSet { defaults.set(transcriptionConsentHost, forKey: "transcriptionConsentHost") } }
  /// The gateway host the user agreed to send transcripts to; another host needs a new consent.
  var gatewayConsentHost: String? { didSet { defaults.set(gatewayConsentHost, forKey: "gatewayConsentHost") } }
  /// 常用词: names, products and jargon, as the user typed them; see `Vocabulary`.
  var vocabularyText: String { didSet { defaults.set(vocabularyText, forKey: "vocabularyText") } }
  /// 每日例会: the hour summaries that overlap it are written as meeting notes.
  var meetingEnabled: Bool { didSet { defaults.set(meetingEnabled, forKey: "meetingEnabled") } }
  /// Minutes after midnight.
  var meetingStart: Int { didSet { defaults.set(meetingStart, forKey: "meetingStart") } }
  var meetingEnd: Int { didSet { defaults.set(meetingEnd, forKey: "meetingEnd") } }
  var meetingWeekdaysOnly: Bool { didSet { defaults.set(meetingWeekdaysOnly, forKey: "meetingWeekdaysOnly") } }

  init() {
    alwaysRecord = defaults.object(forKey: "alwaysRecord") as? Bool ?? true
    microphone = MicrophoneChoice(rawValue: defaults.string(forKey: "microphone") ?? "") ?? .builtIn
    audioRetentionDays = defaults.object(forKey: "audioRetentionDays") as? Int ?? 0
    textRetentionDays = defaults.object(forKey: "textRetentionDays") as? Int ?? 0
    onboarded = defaults.bool(forKey: "onboarded")
    pausedUntil = defaults.object(forKey: "pausedUntil") as? Date
    recordingHeartbeat = defaults.object(forKey: "recordingHeartbeat") as? Date
    quitCleanly = defaults.bool(forKey: "quitCleanly")
    voiceHintDismissed = defaults.bool(forKey: "voiceHintDismissed")
    splitSpeakers = defaults.bool(forKey: "splitSpeakers")
    rememberVoices = defaults.bool(forKey: "rememberVoices")
    autoSync = defaults.object(forKey: "autoSync") as? Bool ?? true
    mergeSameContent = defaults.object(forKey: "mergeSameContent") as? Bool ?? true
    summaryEngine = SummaryEngineChoice(rawValue: defaults.string(forKey: "summaryEngine") ?? "") ?? .automatic
    gatewayProtocol = GatewayProtocol(rawValue: defaults.string(forKey: "gatewayProtocol") ?? "") ?? .chatCompletions
    gatewayBearerForAnthropic = defaults.bool(forKey: "gatewayBearerForAnthropic")
    gatewayBaseURL = defaults.string(forKey: "gatewayBaseURL") ?? ""
    gatewayModel = defaults.string(forKey: "gatewayModel") ?? ""
    transcriptionBaseURL = defaults.string(forKey: "transcriptionBaseURL") ?? ""
    transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? ""
    transcriptionConsentHost = defaults.string(forKey: "transcriptionConsentHost")
    gatewayConsentHost = defaults.string(forKey: "gatewayConsentHost")
    vocabularyText = defaults.string(forKey: "vocabularyText") ?? ""
    meetingEnabled = defaults.bool(forKey: "meetingEnabled")
    meetingStart = defaults.object(forKey: "meetingStart") as? Int ?? 9 * 60
    meetingEnd = defaults.object(forKey: "meetingEnd") as? Int ?? 10 * 60
    meetingWeekdaysOnly = defaults.object(forKey: "meetingWeekdaysOnly") as? Bool ?? true
  }

  var vocabulary: [String] { Vocabulary.words(from: vocabularyText) }

  /// What the summaries need to know about the user's work: their words and their daily meeting.
  var summaryContext: SummaryContext {
    SummaryContext(
      vocabulary: vocabulary,
      meeting: meetingEnabled && meetingEnd > meetingStart
        ? DailyMeeting(start: meetingStart, end: meetingEnd, weekdaysOnly: meetingWeekdaysOnly) : nil)
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

extension Preferences {
  var transcriptionService: TranscriptionServiceConfig {
    TranscriptionServiceConfig(
      baseURL: transcriptionBaseURL, model: transcriptionModel,
      apiKey: GatewayKeychain.read(account: GatewayKeychain.transcriptionAccount))
  }

  /// Filled in, and the user agreed to send audio to its host.
  var transcriptionServiceReady: Bool {
    let config = transcriptionService
    return config.isComplete && transcriptionConsentHost == config.host
  }
}
