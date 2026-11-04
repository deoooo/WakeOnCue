import AVFoundation
import EventKit
import SwiftUI

/// First run in three steps: what all-day recording means (and the consent it needs), the
/// permissions, and getting transcription and summaries ready.
struct OnboardingView: View {
  @Environment(AppModel.self) private var model
  @State private var step = 1
  @State private var agreed = false
  @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
  @State private var meetingAudioAsked = false
  @State private var launchAtLogin = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("第 \(step) 步，共 3 步").font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
      Group {
        switch step {
        case 1: intro
        case 2: permissions
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
        if step < 3 {
          Button("继续") { step += 1 }
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
      Text("登录后一直录下 Mac 麦克风和会议 App 的声音，转录并整理成每小时和每天的总结，方便你回顾和发纪要。")
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        Label("录音、转录和总结都只存在这台 Mac 上，不会上传。", systemImage: "lock")
        Label("随时可以暂停，也可以把一段时间标为私人或删除。", systemImage: "pause.circle")
        Label("音频默认保留 30 天，转录和总结一直保留，可在设置中修改。", systemImage: "externaldrive")
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
      permissionRow("会议 App 的声音", "录下飞书、腾讯会议等会议里对方的声音。没有它只能录到你这边。") {
        if meetingAudioAsked {
          Button("去系统设置…") { AppModel.openPrivacySettings("Privacy_AudioCapture") }
        } else {
          Button("打开…") {
            MeetingAudioCapture.requestAccess()
            meetingAudioAsked = true
          }
        }
      }
      permissionRow("日历", "用会议名命名这段录音，并把参会人作为纪要的收件人。可选。") {
        if model.meetings.calendarAccess == .fullAccess {
          Text("✓ 已打开").foregroundStyle(.green)
        } else {
          Button("打开…") { Task { await model.meetings.requestCalendarAccess() } }
        }
      }
      permissionRow("登录时启动", "开机后自动开始录音。") {
        Toggle("登录时启动", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
      }
    }
  }

  private var readiness: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("准备转录").font(.title2.weight(.semibold))
      permissionRow("Apple 语音 · 中文", "系统自带，支持边录边转。") {
        SpeechStatusText(status: model.transcription.status).font(.caption)
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
    Task {
      await model.recorder.startIfAllowed()
      await model.transcription.start()
    }
  }
}
