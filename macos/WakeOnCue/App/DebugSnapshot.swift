#if DEBUG
  import AppKit
  import Darwin

  /// Development aid. `defaults write com.deoooo.WakeOnCue.macos debugSnapshot <path.png>` makes
  /// the app capture its own windows into PNGs every few seconds, and run the commands it
  /// finds in `<path>.cmd` (one per line), so screens can be checked without a mouse.
  enum DebugSnapshot {
    static func startIfRequested(model: AppModel) {
      guard let path = UserDefaults.standard.string(forKey: "debugSnapshot") else { return }
      Task {
        while true {
          try? await Task.sleep(for: .seconds(2))
          runCommands(at: path + ".cmd", model: model)
          try? await Task.sleep(for: .seconds(1))
          capture(to: path)
        }
      }
    }

    private static func runCommands(at path: String, model: AppModel) {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
      try? FileManager.default.removeItem(atPath: path)
      for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let hour = Calendar.current.hourStart(.now)
        switch parts.first {
        case "expand": model.ui.expandedHours.insert(hour)
        case "all": model.ui.fullHours.insert(hour)
        case "play":
          if let sentence = model.store.sentences(in: DateInterval(start: hour, duration: 3_600)).first { model.play(sentence) }
        case "pause": model.player.pause()
        case "tracks": model.ui.showTracks.toggle()
        case "meeting": model.openMeeting(Int64(argument) ?? 0)
        case "markmeeting": model.markMeeting(in: DateInterval(start: hour, duration: 3_600))
        case "draft": model.ui.draftingMinutes = true
        case "close": model.closeMeeting()
        case "search": model.ui.searchText = argument; model.ui.submittedSearch = argument
        case "deleted": model.ui.page = .deleted
        case "day": model.ui.moveDay(by: Int(argument) ?? 0)
        case "today": model.ui.show(day: .now)
        case "private": model.setPrivate(DateInterval(start: hour, duration: 3_600), argument != "off")
        case "legend": model.ui.showLegend.toggle()
        case "size":
          let size = argument.split(separator: "x").compactMap { Double($0) }
          if size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width >= 900 }) {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
          }
        case "settings": model.openSettings?()
        default: break
        }
      }
    }

    private static func capture(to path: String) {
      typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
      guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
      let capture = unsafeBitCast(symbol, to: Capture.self)
      for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 200 {
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else { continue }
        let rep = NSBitmapImageRep(cgImage: image)
        let name = index == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(index).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
      }
    }
  }
#endif
