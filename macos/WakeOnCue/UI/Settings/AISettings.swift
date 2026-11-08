import AppKit
import SwiftUI

/// "AI 服务": which engine writes summaries, and the user's OpenAI-compatible gateway. The key
/// goes to the keychain; transcripts only go to the gateway after the user agreed for that host.
struct AISettings: View {
  @Environment(AppModel.self) private var model
  @State private var apiKey = ""
  @State private var savedKey = false
  @State private var testing = false
  @State private var testResult: Result<String, Error>?

  var body: some View {
    @Bindable var preferences = model.preferences
    let summaries = model.summaries
    let config = preferences.gateway
    let consented = preferences.gatewayConsentHost != nil && preferences.gatewayConsentHost == config.host
    Form {
      Section {
        Picker("总结引擎", selection: $preferences.summaryEngine) {
          ForEach(SummaryEngineChoice.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        LabeledContent("本机 Apple 智能", value: AppleIntelligenceEngine.unavailableReason ?? "可用")
        LabeledContent("现在使用") {
          if let engine = summaries.engineName {
            Text(engine).foregroundStyle(.green)
          } else {
            Text(summaries.unavailableReason ?? "").foregroundStyle(Color.recording)
          }
        }
        if let error = summaries.lastError {
          LabeledContent("最近一次失败", value: error).foregroundStyle(Color.recording)
        }
      } footer: {
        Text("自动：这台 Mac 支持 Apple 智能时在本机生成，不上传；不支持时改用下面的网关。")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        Picker("协议", selection: $preferences.gatewayProtocol) {
          ForEach(GatewayProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .onChange(of: preferences.gatewayProtocol) { old, new in
          // Follow the protocol's default address unless the user typed their own.
          if preferences.gatewayBaseURL.isEmpty || preferences.gatewayBaseURL == old.defaultBaseURL {
            preferences.gatewayBaseURL = new.defaultBaseURL
          }
          testResult = nil
          summaries.refreshEngine()
        }
        TextField("Base URL", text: $preferences.gatewayBaseURL, prompt: Text(preferences.gatewayProtocol.defaultBaseURL))
        if let endpoint = config.endpoint {
          LabeledContent("请求地址", value: endpoint.absoluteString).font(.caption).foregroundStyle(.secondary)
        }
        TextField("模型", text: $preferences.gatewayModel, prompt: Text("模型名称"))
        LabeledContent("API Key") {
          HStack {
            SecureField("API Key", text: $apiKey, prompt: Text(savedKey ? "已保存在钥匙串" : "粘贴 API Key"))
              .labelsHidden()
              .onSubmit(saveKey)
            Button("保存", action: saveKey).disabled(apiKey.isEmpty || apiKey == GatewayKeychain.read())
          }
        }
        if preferences.gatewayProtocol == .anthropic {
          Toggle(isOn: $preferences.gatewayBearerForAnthropic) {
            Text("用 Authorization: Bearer 发送 Key")
            Text("默认用 x-api-key。只认 Bearer 的网关才需要打开")
          }
          .onChange(of: preferences.gatewayBearerForAnthropic) { summaries.refreshEngine() }
        }
        HStack {
          Button(testing ? "正在测试…" : "测试连接", action: test)
            .disabled(testing || !config.isComplete)
          if let testResult {
            switch testResult {
            case .success(let message): Text(message).foregroundStyle(.green).font(.caption)
            case .failure(let error): Text(error.localizedDescription).foregroundStyle(Color.recording).font(.caption)
            }
          }
        }
        Toggle(isOn: Binding(get: { consented }, set: { setConsent($0, host: config.host) })) {
          Text("把转录文字发送到这个网关")
          Text(consented ? "已同意发送到 \(config.host)" : "开启前会请你确认")
        }
        .disabled(config.endpoint == nil && !consented)
      } header: {
        Text("网关")
      } footer: {
        Text("API Key 只存在这台 Mac 的钥匙串里。使用网关时，每小时和当天的转录文字会发送到网关生成总结；音频不会发送，标为私人或已删除的时段也不会发送。")
          .font(.caption).foregroundStyle(.secondary)
      }

      MeetingSection()
    }
    .onAppear {
      savedKey = !GatewayKeychain.read().isEmpty
      apiKey = ""
    }
    .onChange(of: preferences.summaryEngine) { summaries.refreshEngine() }
    .onChange(of: preferences.gatewayBaseURL) {
      testResult = nil
      summaries.refreshEngine()
    }
    .onChange(of: preferences.gatewayModel) {
      testResult = nil
      summaries.refreshEngine()
    }
  }

  private func saveKey() {
    guard !apiKey.isEmpty else { return }
    GatewayKeychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    apiKey = ""
    savedKey = true
    testResult = nil
    model.summaries.refreshEngine()
  }

  private func test() {
    let config = model.summaries.gatewayConfig
    testing = true
    Task {
      testResult = await GatewayEngine(config: config).test()
      testing = false
    }
  }

  /// Turning the gateway on needs its own confirmation that names where transcripts go.
  private func setConsent(_ on: Bool, host: String) {
    let preferences = model.preferences
    if !on {
      preferences.gatewayConsentHost = nil
      model.summaries.refreshEngine()
      return
    }
    let alert = NSAlert()
    alert.messageText = "把转录文字发送到 \(host)？"
    alert.informativeText = """
      开启后，生成每小时总结和当天总结时，会把对应时段的转录文字发送到这个网关（模型：\(preferences.gatewayModel)）。\
      网关的运营方能看到这些内容，其中可能包括别人说的话。

      音频不会发送，标为私人或已删除的时段也不会发送。随时可以在这里关闭。
      """
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "同意并开启")
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    preferences.gatewayConsentHost = host
    model.summaries.refreshEngine()
  }
}

/// 每日例会: the hours it falls in are summarized as meeting notes instead of one or two lines.
private struct MeetingSection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var preferences = model.preferences
    Section {
      Toggle("每天有固定的例会", isOn: $preferences.meetingEnabled)
      if preferences.meetingEnabled {
        LabeledContent("时间") {
          HStack {
            MinutePicker(minutes: $preferences.meetingStart)
            Text("到")
            MinutePicker(minutes: $preferences.meetingEnd)
          }
        }
        Toggle("只在工作日", isOn: $preferences.meetingWeekdaysOnly)
        if preferences.meetingEnd <= preferences.meetingStart {
          Text("结束时间要晚于开始时间").font(.caption).foregroundStyle(Color.recording)
        }
      }
    } header: {
      Text("每日例会")
    } footer: {
      Text("例会所在小时的总结写成纪要：每人的进展、今天的计划、卡住的问题和待办。之后生成的总结按这里的设置；以前的可以在小时菜单里重新生成。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// A time of day as minutes after midnight, in 5-minute steps.
private struct MinutePicker: View {
  @Binding var minutes: Int

  var body: some View {
    Picker("", selection: $minutes) {
      ForEach(Array(stride(from: 0, to: 24 * 60, by: 5)), id: \.self) { value in
        Text(String(format: "%02d:%02d", value / 60, value % 60)).tag(value)
      }
    }
    .labelsHidden()
    .fixedSize()
  }
}
