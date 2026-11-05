import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Space plays or pauses and ← → skip 15 seconds, unless a text field or editor has focus.
enum PlaybackKeys {
  static func install(model: AppModel) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
        let window = event.window, window.identifier?.rawValue.hasPrefix("main") == true || window.title == "WakeOnCue",
        !(window.firstResponder is NSText), model.player.position != nil || event.keyCode == UInt16(kVK_Space)
      else { return event }
      switch Int(event.keyCode) {
      case kVK_Space:
        guard model.player.position != nil else { return event }
        model.player.toggle()
      case kVK_LeftArrow: model.player.skip(-15)
      case kVK_RightArrow: model.player.skip(15)
      default: return event
      }
      return nil
    }
  }
}

/// ⌃⌥P pauses or resumes recording from anywhere. Carbon hot keys need no accessibility access.
final class GlobalHotKey {
  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private static var action: (() -> Void)?

  func register(action: @escaping () -> Void) {
    Self.action = action
    var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.action?() } }
      return noErr
    }, 1, &type, nil, &handler)
    let id = EventHotKeyID(signature: OSType(0x574F_4351), id: 1)
    RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
  }
}

/// Menu commands for the day page; their shortcuts work wherever the main window is.
struct DayCommands: Commands {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .importExport) {
      Button("导出这一天…") {
        openWindow(id: "main")
        model.exportDay()
      }
      .keyboardShortcut("e")
    }
    CommandGroup(after: .textEditing) {
      Button("搜索全部录音") {
        openWindow(id: "main")
        model.ui.focusSearch += 1
      }
      .keyboardShortcut("f")
    }
    CommandMenu("前往") {
      Button("前一天") { model.ui.moveDay(by: -1) }.keyboardShortcut("[")
      Button("后一天") { model.ui.moveDay(by: 1) }.keyboardShortcut("]")
      Button("今天") { model.ui.show(day: .now) }.keyboardShortcut("t")
      Divider()
      Button("打开 WakeOnCue") { openWindow(id: "main") }.keyboardShortcut("o")
    }
    CommandMenu("录音") {
      Button(model.recorder.isRecording ? "暂停录音" : "继续录音") {
        Task { await model.recorder.togglePause() }
      }
      .keyboardShortcut("p", modifiers: [.control, .option])
      Button(model.player.isPlaying ? "暂停播放" : "播放") { model.player.toggle() }
        .disabled(model.player.position == nil)
    }
  }
}
