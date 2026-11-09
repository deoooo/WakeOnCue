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
          Button("继续") { goOn() }
            .buttonStyle(.borderedProminent)
            .disabled(!canGoOn)
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
    #if DEBUG
      .onReceive(NotificationCenter.default.publisher(for: DebugSnapshot.onboarding)) { note in
        debugCommand(note.object as? String ?? "")
      }
    #endif
  }

  private var canGoOn: Bool { step == 1 ? agreed : microphone == .authorized }

  private func goOn() {
    if step == 3 { applyModelChoice() }
    step += 1
  }

  private func requestMicrophone() {
    Task {
      _ = await MicrophoneCapture.requestAccess()
      microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    }
  }

  #if DEBUG
    /// What a click would do, for `DebugSnapshot`'s `onboard` command. 继续 only goes on when the
    /// button is enabled (`step N` jumps regardless); 开始录音 is left out, since it registers the
    /// login item and watchdog.
    private func debugCommand(_ command: String) {
      let words = command.split(separator: " ").map(String.init)
      switch words.first {
      case "agree": agreed = true
      case "next": if step < 4, canGoOn { goOn() }
      case "back": if step > 1 { step -= 1 }
      case "pick": if let id = words.last, Self.modelOptions.contains(where: { $0.id == id }) { modelChoice = id }
      case "mic": if microphone == .notDetermined { requestMicrophone() }
      case "login": launchAtLogin = words.last == "on"
      // Skips the gates, to look at a later step without granting the microphone again.
      case "step":
        if let n = Int(words.last ?? ""), (1...4).contains(n) {
          if step <= 3, n == 4 { applyModelChoice() }
          step = n
        }
      default: break
      }
    }
  #endif

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
          Button("打开…") { requestMicrophone() }
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
        Text(option.isBuiltIn ? "不用下载，准确度一般" : option.detail)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      // The size on its own, so the description never wraps around it.
      if !option.isBuiltIn {
        Text(installed ? "已下载" : option.size)
          .font(.callout).foregroundStyle(.secondary).monospacedDigit()
      }
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

  /// Three rows of the same shape: what it is on the left, whether it is ready on the right.
  private var readiness: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("准备转录").font(.title2.weight(.semibold))
      permissionRow("Apple 语音 · 中文", "系统自带，边录边转。") {
        SpeechStatusText(status: model.transcription.status)
      }
      if let chosen = Self.modelOptions.first(where: { $0.id == modelChoice }), !chosen.isBuiltIn {
        chosenModelRow(chosen)
      }
      summaryRow
      Text("需要 macOS 26 和 Apple 芯片的 Mac。").font(.caption).foregroundStyle(.secondary)
    }
    .font(.body)
    .task { await model.transcription.start() }
  }

  /// The model picked on the step before, with its download; picking again is done there.
  private func chosenModelRow(_ chosen: ASRModel) -> some View {
    let models = model.models
    let state = models.state(of: chosen)
    return row(title: chosen.name) {
      switch state {
      case .downloading(let fraction):
        HStack(spacing: 6) {
          ProgressView(value: fraction).frame(width: 100)
          Text("下载中 \(Int(fraction * 100))%，下完自动启用").monospacedDigit()
        }
      case .verifying: Text("正在校验下载的文件…")
      case .paused(let fraction): Text("已暂停在 \(Int(fraction * 100))%")
      case .failed(let reason): Text(reason).foregroundStyle(Color.recording).lineLimit(2)
      case .installed: Text("每句话会在几秒后重新转录。")
      case .notDownloaded: Text("\(chosen.size)，等待下载")
      }
    } trailing: {
      switch state {
      case .downloading: Button("暂停") { models.pause(chosen) }
      case .paused: Button("继续下载") { models.choose(chosen) }
      case .failed: Button("重试") { models.choose(chosen) }
      case .installed: Text("✓ 已就绪").foregroundStyle(.green)
      case .verifying, .notDownloaded: EmptyView()
      }
    }
  }

  /// Summaries come from Apple Intelligence on this Mac, or from the user's own gateway on Macs
  /// without it. Recording and transcription work either way.
  private var summaryRow: some View {
    row(title: "总结") {
      if let engine = model.summaries.engineName {
        Text("由\(engine)生成每小时和每天的总结。")
      } else {
        Text("\(model.summaries.unavailableReason ?? "现在没有可用的总结方式")，可以配置自己的 AI 网关来生成总结。不配置也能照常录音和转录。")
      }
    } trailing: {
      if model.summaries.engineName != nil {
        Text("✓ 已就绪").foregroundStyle(.green)
      } else {
        Button("设置网关…") { model.showSettings(.ai) }
      }
    }
  }

  private func permissionRow(_ title: String, _ detail: String, @ViewBuilder trailing: () -> some View) -> some View {
    row(title: title) { Text(detail) } trailing: { trailing() }
  }

  private func row(title: String, @ViewBuilder detail: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).fontWeight(.semibold)
        detail()
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
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
