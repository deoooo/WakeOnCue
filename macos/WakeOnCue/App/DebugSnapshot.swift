#if DEBUG
  import AVFoundation
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
        // "playhour 9": the first sentence of 09:00 on the day shown; "cite 123": as if its
        // time link in a summary was clicked.
        case "playhour":
          let start = Calendar.current.startOfDay(for: model.ui.day).addingTimeInterval(Double(Int(argument) ?? 0) * 3_600)
          if let sentence = model.store.sentences(in: DateInterval(start: start, duration: 3_600)).first { model.play(sentence) }
        case "cite": model.cite(Int64(argument) ?? 0)
        // Every hour of the day shown, expanded with all its sentences.
        case "expandday":
          let day = Calendar.current.startOfDay(for: model.ui.day)
          for offset in 0..<24 {
            let start = day.addingTimeInterval(Double(offset) * 3_600)
            model.ui.expandedHours.insert(start)
            model.ui.fullHours.insert(start)
          }
        // "export day md", "export 9 srt": writes what 导出 would save to
        // <path>.export.<format>, without the save panel.
        case "export":
          let words = argument.split(separator: " ").map(String.init)
          let format = ExportFormat(rawValue: words.last ?? "") ?? .markdown
          let day = Calendar.current.startOfDay(for: model.ui.day)
          let source: ExportSource? =
            switch words.first {
            case "day": .day(day, store: model.store)
            default: .hour(day.addingTimeInterval(Double(Int(words.first ?? "") ?? 0) * 3_600), store: model.store)
            }
          if let source {
            try? Exporter.render(source, as: format).write(toFile: path + ".export." + format.rawValue, atomically: true, encoding: .utf8)
          }
        case "exportpanel": model.exportDay()
        // The menu bar's commands and their shortcuts, one per line, into <path>.menus.
        case "menus":
          let lines = (NSApp.mainMenu?.items ?? []).flatMap { top in
            (top.submenu?.items ?? []).filter { !$0.isSeparatorItem }.map { item in
              "\(top.title) › \(item.title)" + (item.keyEquivalent.isEmpty ? "" : " ⌘\(item.keyEquivalent)")
            }
          }
          try? lines.joined(separator: "\n").write(toFile: path + ".menus", atomically: true, encoding: .utf8)
        case "pause": model.player.pause()
        case "tracks": model.ui.showTracks.toggle()
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
        // "retranscribe 14" / "regenerate 14": that hour of the day shown; "retranscribe day";
        // "redoday" re-transcribes the day shown and then writes all its summaries again.
        // "replay <from> <to>" (Unix seconds): feeds the stored microphone audio of that stretch
        // into live transcription with its original times, faster than real time. For
        // WAKEONCUE_REPLAY on a copy whose sentences were cleared.
        case "replay":
          let bounds = argument.split(separator: " ").compactMap { Double($0) }
          guard bounds.count == 2 else { break }
          Task { await Replay.run(DateInterval(start: Date(timeIntervalSince1970: bounds[0]), end: Date(timeIntervalSince1970: bounds[1])), model: model) }
        case "retranscribe", "regenerate", "regenday", "redoday":
          let day = Calendar.current.startOfDay(for: model.ui.day)
          let interval = argument == "day" || parts[0] == "regenday" || parts[0] == "redoday"
            ? DateInterval(start: day, duration: 86_400)
            : DateInterval(start: day.addingTimeInterval(Double(Int(argument) ?? 0) * 3_600), duration: 3_600)
          if parts[0] == "retranscribe" || parts[0] == "redoday" {
            model.refiner.retranscribe(interval, summarizeAll: parts[0] == "redoday")
          } else {
            model.regenerateSummaries(in: interval)
          }
          Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Debug").notice(
            "\(parts[0], privacy: .public) \(interval, privacy: .public) with \(model.refiner.retranscribeName, privacy: .public) / \(model.summaries.engineName ?? "-", privacy: .public)")
        case "scrollhour": model.reveal(hour: Calendar.current.startOfDay(for: model.ui.day).addingTimeInterval(Double(Int(argument) ?? 0) * 3_600))
        case "stoptranscribe": model.refiner.cancelRetranscription()
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
  /// Feeds stored audio into live transcription. Keeps at most ten minutes of audio ahead of
  /// what the analyzer has given back, so a day of audio is never held in memory at once.
  enum Replay {
    private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Replay")

    @MainActor static func run(_ interval: DateInterval, model: AppModel) async {
      let segments = model.store.segments(overlapping: interval).filter { $0.channel == .microphone }.sorted { $0.start < $1.start }
      logger.notice("Replay: \(segments.count) segments")
      var progress = Date.distantPast
      var progressChanged = Date.now
      for segment in segments {
        guard let file = try? AVAudioFile(forReading: Store.audioDirectory.appending(path: segment.path)) else { continue }
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate)
        var position: AVAudioFramePosition = 0
        while position < file.length {
          let start = segment.start.addingTimeInterval(Double(position) / format.sampleRate)
          // Back pressure: the analyzer reports where it is through live text and sentences.
          while true {
            let heard = max(model.transcription.live[.microphone]?.start ?? .distantPast, model.transcription.lastSentence?.end ?? .distantPast)
            if heard > progress { progress = heard; progressChanged = .now }
            if start.timeIntervalSince(progress) < 600 || Date.now.timeIntervalSince(progressChanged) > 5 { break }
            try? await Task.sleep(for: .milliseconds(50))
          }
          guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
          file.framePosition = position
          guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
          model.recorder.audioOut.send(.microphone, TimedBuffer(buffer: buffer, start: start))
          position += AVAudioFramePosition(buffer.frameLength)
          await Task.yield()
        }
        logger.notice("Replay: fed \(segment.path, privacy: .public)")
      }
      model.transcription.flush()
      logger.notice("Replay: done")
    }
  }
#endif
