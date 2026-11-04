import AppKit
import SwiftUI

/// What to tell the user about recording, shared by the toolbar, the banner and the menu bar.
struct RecordingStatus {
  var title: String
  var detail: String
  var isProblem: Bool
}

struct Issue {
  struct Action {
    let title: String
    let run: () -> Void
  }

  var title: String
  var detail: String
  var action: Action?
}

extension AppModel {
  var recordingStatus: RecordingStatus {
    switch recorder.state {
    case .recording:
      var parts = [preferences.microphone == .builtIn ? "内建麦克风" : recorder.microphoneName]
      parts += recorder.activeMeetingApps
      return RecordingStatus(title: "录音中", detail: parts.joined(separator: " · "), isProblem: false)
    case .paused(let until):
      return RecordingStatus(
        title: "已暂停", detail: until == .distantFuture ? "手动继续" : "\(TimeText.clock(until)) 自动继续", isProblem: false)
    case .unavailable(let reason):
      return RecordingStatus(title: "没有在录音", detail: reason, isProblem: true)
    case .off:
      return RecordingStatus(
        title: "没有在录音", detail: !preferences.onboarded ? "还没有完成设置" : preferences.alwaysRecord ? "正在启动" : "全天录音已关闭", isProblem: false)
    }
  }

  /// The problem the banner and the menu bar show, with a way to fix it.
  var currentIssue: Issue? {
    if case .unavailable(let reason) = recorder.state {
      let since = store.gaps(overlapping: DateInterval(start: .now.addingTimeInterval(-86_400), end: .now)).last?.start
      let detail = (since.map { "从 \(TimeText.clock($0)) 起这台 Mac 没有录到声音，" } ?? "") + "问题解决后会自动继续。"
      let action: Issue.Action? =
        reason == CaptureError.microphoneDenied.localizedDescription
        ? Issue.Action(title: "打开系统设置") { Self.openPrivacySettings("Privacy_Microphone") } : nil
      return Issue(title: reason, detail: detail, action: action)
    }
    if let issue = recorder.writeIssue {
      return Issue(title: issue, detail: "录音可能不完整。", action: nil)
    }
    if let issue = transcription.issue {
      return Issue(title: issue, detail: "录音会继续，但不会转录。", action: nil)
    }
    if let warning = recorder.diskWarning {
      return Issue(title: warning, detail: "不到 2 GB 时会暂停录音，不会自动删除录音。", action: Issue.Action(title: "存储设置") { [weak self] in
        self?.openSettings?()
      })
    }
    if recorder.isRecording, let issue = recorder.meetingAudioIssue {
      return Issue(title: "没有录到会议 App 的声音", detail: issue, action: Issue.Action(title: "打开系统设置") {
        Self.openPrivacySettings("Privacy_AudioCapture")
      })
    }
    return nil
  }

  var macStatus: (text: String, dot: Color) {
    switch recorder.state {
    case .recording:
      switch transcription.status {
      case .ready: return ("录音中，转录已跟上", .recording)
      case .preparing, .downloading: return ("录音中，转录正在准备", .recording)
      case .failed: return ("录音中，没有转录", .recording)
      }
    case .paused: return ("已暂停", .secondary)
    case .unavailable(let reason): return ("没有在录音，\(reason)", .orange)
    case .off: return ("没有在录音", .secondary)
    }
  }

  var deletedMarks: [TimeMark] {
    _ = store.revision
    return store.marks().filter { $0.kind == .deleted }
  }

  static func openPrivacySettings(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
      NSWorkspace.shared.open(url)
    }
  }
}
