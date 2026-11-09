import AVFoundation
import SwiftUI

/// First run in four steps: what all-day recording means (and the consent it needs), the
/// permissions, the transcription model, and getting transcription and summaries ready.
struct OnboardingView: View {
  @Environment(AppModel.self) private var model
  @State private var step = 1
  @State private var agreed = false
  @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
  @State private var launchAtLogin = true
  /// The model picked on the model step; the one suited to this Mac until the user picks another.
  /// It is only downloaded when the user goes on from that step.
  @State private var modelChoice = ASRModel.recommended().id

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("第 \(step) 步，共 4 步").font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
      Group {
        switch step {
        case 1: intro
        case 2: permissions
        case 3: modelStep
        default: readiness
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 20)
      HStack {
        if step == 1 {
          Button("退出") { NSApp.terminate(nil) }
        } else {
          Button("返回") { step -= 1 }
        }
        Spacer()
        if step < 4 {
          Button("继续") {
            if step == 3 { applyModelChoice() }
            step += 1
          }
            .buttonStyle(.borderedProminent)
            .disabled(step == 1 ? !agreed : microphone != .authorized)
            .keyboardShortcut(.defaultAction)
        } else {
          Button("开始录音") { finish() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(28)
    .frame(width: 520, height: 520)
    .interactiveDismissDisabled()
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("WakeOnCue 会全天录音").font(.title2.weight(.semibold))
      Text("登录后一直录下 Mac 麦克风的声音，转录并整理成每小时和每天的总结，方便你回顾。")
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        Label("录音、转录和总结都只存在这台 Mac 上，不会上传。", systemImage: "lock")
        Label("随时可以暂停，也可以把一段时间标为私人或删除。", systemImage: "pause.circle")
        Label("音频默认一直保留，转录和总结也一直保留，可在设置中改为 30 天或 7 天后清理音频。", systemImage: "externaldrive")
      }
      .foregroundStyle(.secondary)
      (Text("会录到其他人的声音。").fontWeight(.semibold)
        + Text("不同地区对录音是否要告知对方有不同规定。请在需要时告诉对方你在录音，或先暂停。"))
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.warningBackground))
      Toggle("我已了解，并会在需要时告知对方", isOn: $agreed).toggleStyle(.checkbox)
    }
  }

  private var permissions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("打开需要的权限").font(.title2.weight(.semibold))
      Text("每项都可以之后在“系统设置 › 隐私与安全性”里修改。").foregroundStyle(.secondary)
      permissionRow("麦克风", "录下你和身边的人说的话。必需。") {
        if microphone == .authorized {
          Text("✓ 已打开").foregroundStyle(.green)
        } else if microphone == .notDetermined {
          Button("打开…") {
            Task {
              _ = await MicrophoneCapture.requestAccess()
              microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            }
          }
        } else {
          Button("去系统设置…") { AppModel.openPrivacySettings("Privacy_Microphone") }
        }
      }
      permissionRow("登录时启动", "开机后自动开始录音。") {
        Toggle("登录时启动", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
      }
    }
  }

  /// The models that run on this Mac. The transcription service needs an address and a key, so it
  /// is left to 设置.
  private static let modelOptions: [ASRModel] = [.appleSpeech, .qwen3_0_6B, .qwen3_1_7B]

  private var modelStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("选择转录模型").font(.title2.weight(.semibold))
      Text("Apple 语音一直负责边录边转。再选一个模型，每句话会在几秒后重新转录，人名、术语和小声说的话会准很多。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      VStack(spacing: 0) {
        ForEach(Self.modelOptions) { option in
          modelOption(option)
          if option != Self.modelOptions.last { Divider() }
        }
      }
      .padding(.horizontal, 12)
      .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
      Text("继续后在后台下载，下完自动启用，下载期间照常录音和转录。之后可以在设置 › 转录模型里换。")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func modelOption(_ option: ASRModel) -> some View {
    let selected = modelChoice == option.id
    let installed = option.isDownloadable && model.models.state(of: option) == .installed
    return HStack(alignment: .center, spacing: 10) {
      Image(systemName: selected ? "largecircle.fill.circle" : "circle")
        .font(.title3)
        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(option.isBuiltIn ? "只用 Apple 语音" : option.name).fontWeight(.medium)
          if option == ASRModel.recommended() {
            Text("推荐")
              .font(.caption2.weight(.medium))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.tint.opacity(0.15), in: Capsule())
              .foregroundStyle(.tint)
          }
        }
        Text(option.isBuiltIn ? "不用下载，准确度一般" : "\(option.detail) · \(installed ? "已下载" : "下载\(option.size)")")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture { modelChoice = option.id }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  private func applyModelChoice() {
    guard let option = Self.modelOptions.first(where: { $0.id == modelChoice }) else { return }
    model.models.choose(option)
  }

  private var readiness: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("准备转录").font(.title2.weight(.semibold))
      permissionRow("Apple 语音 · 中文", "系统自带，支持边录边转。") {
        SpeechStatusText(status: model.transcription.status).font(.caption)
      }
      if let chosen = Self.modelOptions.first(where: { $0.id == modelChoice }), !chosen.isBuiltIn {
        Form { ModelRow(entry: chosen) }
          .formStyle(.columns)
          .padding(.vertical, 6)
          .overlay(alignment: .bottom) { Divider() }
      }
      permissionRow("总结", "优先由这台 Mac 上的 Apple 智能生成。不支持 Apple 智能的 Mac 可以在设置 › AI 服务里配置自己的网关。") {
        if let engine = model.summaries.engineName {
          Text("✓ \(engine)").foregroundStyle(.green)
        } else {
          VStack(alignment: .trailing, spacing: 4) {
            Text(model.summaries.unavailableReason ?? "").foregroundStyle(.secondary).font(.caption)
            Button("设置网关…") { model.showSettings(.ai) }
          }
        }
      }
      Text("需要 macOS 26 和 Apple 芯片的 Mac。").font(.caption).foregroundStyle(.secondary)
    }
    .task { await model.transcription.start() }
  }

  private func permissionRow(_ title: String, _ detail: String, @ViewBuilder trailing: () -> some View) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.semibold)
        Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      trailing()
    }
    .padding(.vertical, 8)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func finish() {
    model.launchesAtLogin = launchAtLogin
    model.preferences.onboarded = true
    model.preferences.alwaysRecord = true
    CrashRecovery.registerIfNeeded()
    Task {
      await model.recorder.startIfAllowed()
      await model.transcription.start()
    }
  }
}
