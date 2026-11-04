import AppKit
import SwiftUI

/// The user's OpenAI-compatible transcription service. Unlike the summary gateway, this sends
/// audio, so turning it on needs its own confirmation that names the host.
struct TranscriptionServiceSection: View {
  @Environment(AppModel.self) private var model
  @State private var apiKey = ""
  @State private var savedKey = false
  @State private var testing = false
  @State private var testResult: Result<String, Error>?

  var body: some View {
    @Bindable var preferences = model.preferences
    let config = preferences.transcriptionService
    let consented = preferences.transcriptionConsentHost != nil && preferences.transcriptionConsentHost == config.host
    Section {
      TextField("Base URL", text: $preferences.transcriptionBaseURL, prompt: Text("https://api.openai.com/v1"))
      if let endpoint = config.endpoint {
        LabeledContent("请求地址", value: endpoint.absoluteString).font(.caption).foregroundStyle(.secondary)
      }
      TextField("模型", text: $preferences.transcriptionModel, prompt: Text("例如 whisper-1"))
      LabeledContent("API Key") {
        HStack {
          SecureField("API Key", text: $apiKey, prompt: Text(savedKey ? "已保存在钥匙串" : "粘贴 API Key"))
            .labelsHidden()
            .onSubmit(saveKey)
          Button("保存", action: saveKey).disabled(apiKey.isEmpty)
        }
      }
      HStack {
        Button(testing ? "正在测试…" : "测试连接", action: test).disabled(testing || !config.isComplete)
        if let testResult {
          switch testResult {
          case .success(let message): Text(message).foregroundStyle(.green).font(.caption)
          case .failure(let error): Text(error.localizedDescription).foregroundStyle(Color.recording).font(.caption)
          }
        }
      }
      Toggle(isOn: Binding(get: { consented }, set: { setConsent($0, host: config.host) })) {
        Text("把录音发送到这个服务转录")
        Text(consented ? "已同意发送到 \(config.host)" : "开启前会请你确认")
      }
      .disabled(config.endpoint == nil && !consented)
    } header: {
      Text("第三方转录服务（OpenAI 兼容）")
    } footer: {
      Text("使用 POST {Base URL}/audio/transcriptions。开启并在上面选用后，每句话的音频会在几秒后发到这个服务重新转录；标为私人或已删除的时段不会发送。API Key 只存在钥匙串里。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { savedKey = !GatewayKeychain.read(account: GatewayKeychain.transcriptionAccount).isEmpty }
    .onChange(of: preferences.transcriptionBaseURL) { changed() }
    .onChange(of: preferences.transcriptionModel) { changed() }
  }

  private func changed() {
    testResult = nil
    model.models.transcriptionServiceChanged()
  }

  private func saveKey() {
    guard !apiKey.isEmpty else { return }
    GatewayKeychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: GatewayKeychain.transcriptionAccount)
    apiKey = ""
    savedKey = true
    changed()
  }

  private func test() {
    let config = model.preferences.transcriptionService
    testing = true
    Task {
      testResult = await RemoteTranscriber(config: config).test()
      testing = false
    }
  }

  private func setConsent(_ on: Bool, host: String) {
    let preferences = model.preferences
    guard on else {
      preferences.transcriptionConsentHost = nil
      model.models.transcriptionServiceChanged()
      return
    }
    let alert = NSAlert()
    alert.messageText = "把录音发送到 \(host)？"
    alert.informativeText = """
      开启并选用后，每句话的音频会发送到这个服务重新转录（模型：\(preferences.transcriptionModel)）。\
      服务的运营方能听到这些录音，其中可能包括别人的声音。

      标为私人或已删除的时段不会发送。随时可以在这里关闭。
      """
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "同意并开启")
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    preferences.transcriptionConsentHost = host
    model.models.transcriptionServiceChanged()
  }
}
