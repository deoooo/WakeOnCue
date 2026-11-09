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
      let detail: String
      if preferences.microphone == .builtIn, recorder.microphoneFellBack {
        detail = "\(recorder.microphoneName)（内建麦克风不可用，已改用外接）"
      } else {
        detail = preferences.microphone == .builtIn ? "内建麦克风" : recorder.microphoneName
      }
      return RecordingStatus(title: "录音中", detail: detail, isProblem: false)
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
    return nil
  }

  /// Status dots read like an indicator light: green working, grey idle or offline, yellow
  /// needs a look, red broken.
  enum Light {
    static let working = Color.green
    static let idle = Color.gray
    static let attention = Color.yellow
    static let broken = Color.red
  }

  var macStatus: (text: String, dot: Color) {
    switch recorder.state {
    case .recording:
      switch transcription.status {
      case .ready: return ("录音中，转录已跟上", Light.working)
      case .preparing, .downloading: return ("录音中，转录正在准备", Light.working)
      case .failed: return ("录音中，但没有转录", Light.attention)
      }
    case .paused: return ("已暂停", Light.idle)
    case .unavailable(let reason): return ("录不了：\(reason)", Light.broken)
    case .off: return ("没有在录音", Light.idle)
    }
  }

  /// One icon in the sidebar's status row: a paired iPhone, or the Watch behind it.
  struct DeviceStatus: Identifiable {
    let id: String
    let symbol: String
    let text: String
    let dot: Color?
  }

  /// The paired phones and the Watch, for the sidebar. Without a paired phone, one grey iPhone
  /// that leads to pairing.
  var deviceStatuses: [DeviceStatus] {
    _ = store.revision
    let devices = sync.devices
    guard !devices.isEmpty else {
      return [DeviceStatus(id: "none", symbol: "iphone", text: "还没有配对的 iPhone，点此添加", dot: nil)]
    }
    let counts = store.remoteSegmentCounts()
    var statuses = devices.map { device -> DeviceStatus in
      var text: String
      var dot: Color
      if case .some(let transfer) = sync.connected[device.id] {
        text = transfer.map { "正在接收 \(TimeText.bytes($0.received)) / \(TimeText.bytes($0.total))" } ?? "已连接"
        dot = Light.working
      } else if let lastSeen = device.lastSeen {
        // A phone connects only to hand over what is waiting, then hangs up: recently seen is
        // as good as connected.
        let recent = Date.now.timeIntervalSince(lastSeen) < 30 * 60
        text = (recent ? "正常，" : "有一阵没连上了，") + "上次连接 \(TimeText.relativeDay(lastSeen)) \(TimeText.clock(lastSeen))"
        dot = recent ? Light.working : Light.idle
      } else {
        text = "已配对，但还没有连接过"
        dot = Light.attention
      }
      if let waiting = counts[device.id]?.waiting, waiting > 0 { text += "，\(waiting) 段等待合并" }
      return DeviceStatus(id: device.id, symbol: "iphone", text: "\(device.name)：\(text)", dot: dot)
    }
    if let latest = store.latestWatchAudio() {
      statuses.append(DeviceStatus(
        id: "watch", symbol: "applewatch",
        text: "Apple Watch：经 iPhone 转发，最近收到的录音到 \(TimeText.relativeDay(latest)) \(TimeText.clock(latest))",
        dot: Date.now.timeIntervalSince(latest) < 3_600 ? Light.working : Light.idle))
    }
    return statuses
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
