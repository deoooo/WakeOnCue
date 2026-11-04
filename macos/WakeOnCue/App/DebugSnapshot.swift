#if DEBUG
  import AppKit
  import Darwin
  import OSLog

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

    private static func runCommands(at commandFile: String, model: AppModel) {
      let path = commandFile.replacingOccurrences(of: ".cmd", with: "")
      guard let text = try? String(contentsOfFile: commandFile, encoding: .utf8) else { return }
      try? FileManager.default.removeItem(atPath: commandFile)
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
        case "download": model.models.download(.qwen3_0_6B)
        case "pausedl": model.models.pause(.qwen3_0_6B)
        case "pairqr":
          model.sync.newInvitation()
          Task {
            for _ in 0..<30 where model.sync.invitation == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? model.sync.invitation?.url.absoluteString.write(toFile: path + ".pair", atomically: true, encoding: .utf8)
          }
        case "voicemodel": Task { _ = await model.voices.prepareModel() }
        case "ask":
          model.asking.ask(argument)
          Task {
            while model.asking.isWorking { try? await Task.sleep(for: .milliseconds(500)) }
            guard let last = model.asking.exchanges.last else { return }
            let cites = last.answer.flatMap(\.cites).compactMap { last.sources[$0] }.map { "\(TimeText.clock($0.start)) \($0.text)" }
            Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Debug").notice(
              "ASK \(last.question, privacy: .public) → \(last.error ?? last.answer.map(\.text).joined(separator: " / "), privacy: .public) | cites: \(cites.joined(separator: " ; "), privacy: .public)")
          }
        // "retranscribe 14" / "regenerate 14": that hour of the day shown; "retranscribe day".
        case "retranscribe", "regenerate", "regenday":
          let day = Calendar.current.startOfDay(for: model.ui.day)
          let interval = argument == "day" || parts[0] == "regenday"
            ? DateInterval(start: day, duration: 86_400)
            : DateInterval(start: day.addingTimeInterval(Double(Int(argument) ?? 0) * 3_600), duration: 3_600)
          if parts[0] == "retranscribe" {
            model.refiner.retranscribe(interval)
          } else {
            model.regenerateSummaries(in: interval)
          }
          Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Debug").notice(
            "\(parts[0], privacy: .public) \(interval, privacy: .public) with \(model.refiner.retranscribeName, privacy: .public) / \(model.summaries.engineName ?? "-", privacy: .public); remaining \(model.refiner.retranscribeRemaining)")
        case "stoptranscribe": model.refiner.cancelRetranscription()
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
        case "settings": model.showSettings(SettingsView.Section(rawValue: argument) ?? .recording)
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
