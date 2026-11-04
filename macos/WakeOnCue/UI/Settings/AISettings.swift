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
    let config = GatewayConfig(baseURL: preferences.gatewayBaseURL, model: preferences.gatewayModel, apiKey: apiKey)
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
        TextField("Base URL", text: $preferences.gatewayBaseURL, prompt: Text("https://example.com/v1"))
        TextField("模型", text: $preferences.gatewayModel, prompt: Text("模型名称"))
        LabeledContent("API Key") {
          HStack {
            SecureField("API Key", text: $apiKey, prompt: Text(savedKey ? "已保存在钥匙串" : "粘贴 API Key"))
              .labelsHidden()
              .onSubmit(saveKey)
            Button("保存", action: saveKey).disabled(apiKey.isEmpty || apiKey == GatewayKeychain.read())
          }
        }
        HStack {
          Button(testing ? "正在测试…" : "测试连接", action: test)
            .disabled(testing || !GatewayConfig(baseURL: preferences.gatewayBaseURL, model: preferences.gatewayModel, apiKey: GatewayKeychain.read()).isComplete)
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
        Text("OpenAI 兼容网关")
      } footer: {
        Text("API Key 只存在这台 Mac 的钥匙串里。使用网关时，每小时、当天和会议的转录文字会发送到网关生成总结；音频不会发送，标为私人或已删除的时段也不会发送。")
          .font(.caption).foregroundStyle(.secondary)
      }
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
      开启后，生成每小时总结、当天总结和会议要点时，会把对应时段的转录文字发送到这个网关（模型：\(preferences.gatewayModel)）。\
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
