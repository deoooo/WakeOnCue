import AppKit
import Foundation
import Observation

/// Owns the long-lived services and wires them together.
@Observable
final class AppModel {
  let preferences = Preferences()
  let store: Store
  let recorder: Recorder
  let transcription: Transcription
  let player: Player
  let summaries: Summaries
  let models: ASRModels
  let refiner: Refiner
  let asking: Asking
  let voices: Voices
  let sync: SyncServer
  let merger: Merger
  let meetings: Meetings
  let ui = MainState()
  /// SwiftUI's settings opener, handed over by the main window.
  @ObservationIgnored var openSettings: (() -> Void)?

  func showSettings(_ section: SettingsView.Section) {
    ui.settingsSection = section
    openSettings?()
  }

  init() {
    do {
      store = try Store()
    } catch {
      fatalError("无法打开资料库：\(error.localizedDescription)")
    }
    recorder = Recorder(store: store, preferences: preferences)
    transcription = Transcription(store: store, recorder: recorder)
    player = Player(store: store)
    summaries = Summaries(store: store, preferences: preferences)
    meetings = Meetings(store: store, summaries: summaries)
    refiner = Refiner(store: store)
    sync = SyncServer(store: store, preferences: preferences)
    merger = Merger(store: store, preferences: preferences, summaries: summaries)
    asking = Asking(store: store, summaries: summaries)
    models = ASRModels(preferences: preferences)
    let preferences = preferences
    models.onActiveChange = { [weak refiner, weak transcription] in
      refiner?.use($0, service: preferences.transcriptionService)
      // Live sentences come out sooner when a model re-transcribes them anyway.
      transcription?.setSentencesRetranscribed($0 != nil)
    }
    voices = Voices(store: store, preferences: preferences, models: models, recorder: recorder)
    summaries.knowsMyVoice = { [weak voices] in voices?.knowsMyVoice ?? false }
    // Once the user's voice is known, the hours whose speakers changed are summarized again.
    voices.onSpeakersChanged = { [weak self] hours in
      guard let self else { return }
      for hour in hours { summaries.invalidate(DateInterval(start: hour, duration: 3_600)) }
    }
    transcription.onSentence = { [weak refiner, weak voices] in
      refiner?.enqueue($0)
      voices?.enqueue($0)
    }
    recorder.onCaptureStopped = { [weak transcription] in transcription?.flush() }
    // New words make the old summaries wrong: redo the hours and meetings they fall in.
    // Each hour is summarized again as soon as its sentences are done; the day summary and the
    // meetings follow once the whole stretch is.
    summaries.holdsDays = { [weak refiner] in !(refiner?.retranscribing.isEmpty ?? true) }
    refiner.onHourRetranscribed = { [weak self] hour in
      self?.summaries.regenerate(hour: hour)
    }
    refiner.onRetranscribed = { [weak self] interval, starts, all in
      guard let self else { return }
      for meeting in store.meetings(overlapping: interval)
      where all || starts.contains(where: { $0 >= meeting.start && $0 < max(meeting.end, meeting.start.addingTimeInterval(1)) }) {
        summaries.regenerateMeeting(meeting.id)
      }
      summaries.releaseDays()
    }
  }

  /// Every summary of the stretch again: its hours, its day and its meetings.
  func regenerateSummaries(in interval: DateInterval) {
    summaries.invalidate(interval)
    for meeting in store.meetings(overlapping: interval) { summaries.regenerateMeeting(meeting.id) }
  }

  /// Development aid: `WAKEONCUE_VIEW_ONLY` (with `WAKEONCUE_DATA_DIR`) opens a library to look
  /// at, without recording, summarizing (nothing is sent to a gateway), or taking a paired
  /// phone's audio away from the installed app. Always false in release builds.
  nonisolated static var viewOnly: Bool {
    #if DEBUG
      ProcessInfo.processInfo.environment["WAKEONCUE_VIEW_ONLY"] != nil
    #else
      false
    #endif
  }

  func launch() async {
    if Self.viewOnly { return }
    await recorder.startIfAllowed()
    refiner.use(models.active, service: preferences.transcriptionService)
    transcription.setSentencesRetranscribed(models.active != nil)
    await transcription.start()
    summaries.start()
    meetings.start()
    startHousekeeping()
    sync.onSegment = { [weak merger] _, _ in Task { await merger?.mergePending() } }
    // Important and to-do marks steer the day summary, so the days they fall on are redone.
    sync.onMarks = { [weak summaries] marks in
      for day in Set(marks.map { Calendar.current.startOfDay(for: $0.start) }) { summaries?.redoDay(containing: day) }
    }
    sync.start()
    Task { await merger.mergePending() }
  }

  // MARK: Looking and playing

  /// A citation only finds and highlights the sentence; it never plays.
  func cite(_ id: Int64) {
    guard let sentence = store.sentences(ids: [id]).first else { return }
    let calendar = Calendar.current
    if !calendar.isDate(sentence.start, inSameDayAs: ui.day) { ui.show(day: sentence.start) }
    ui.page = .day
    let hour = calendar.hourStart(sentence.start)
    ui.expandedHours.insert(hour)
    let keys = store.hourSummaries(in: DateInterval(start: hour, duration: 3_600))[hour]?.keySentenceIDs ?? []
    if !keys.isEmpty, !keys.contains(id) { ui.fullHours.insert(hour) }
    ui.highlighted = id
    ui.scroll(to: MainState.sentenceAnchor(id))
  }

  func play(_ sentence: Sentence) {
    ui.highlighted = sentence.id
    ui.showTracks = true
    player.play(from: sentence.start)
  }

  func play(from date: Date) {
    ui.showTracks = true
    player.play(from: date)
  }

  func revealPlaying(at date: Date) {
    let calendar = Calendar.current
    if !calendar.isDate(date, inSameDayAs: ui.day) { ui.show(day: date) }
    let hour = calendar.hourStart(date)
    let sentences = store.sentences(in: DateInterval(start: hour, duration: 3_600))
    if let sentence = sentences.last(where: { $0.start <= date }) ?? sentences.first {
      ui.expandedHours.insert(hour)
      ui.fullHours.insert(hour)
      ui.highlighted = sentence.id
      ui.scroll(to: MainState.sentenceAnchor(sentence.id))
    } else {
      reveal(hour: hour)
    }
  }

  func openMeeting(_ id: Int64) {
    ui.asking = false
    ui.meetingID = id
    ui.draftingMinutes = false
  }

  func closeMeeting() {
    ui.meetingID = nil
    ui.draftingMinutes = false
  }

  func markMeeting(in hour: DateInterval) {
    if let id = meetings.markMeeting(in: hour) { openMeeting(id) }
  }

  func reveal(hour: Date) {
    ui.page = .day
    ui.scroll(to: MainState.hourAnchor(hour))
  }

  // MARK: Private and deleted hours

  func setPrivate(_ hour: DateInterval, _ isPrivate: Bool) {
    if isPrivate {
      store.addMark(.privateRange, start: hour.start, end: hour.end)
      ui.expandedHours.remove(hour.start)
      if let position = player.position, hour.contains(position) { player.stop() }
    } else {
      store.removeMarks(.privateRange, overlapping: hour)
    }
    summaries.invalidate(hour)
  }

  /// Asks with the standard macOS alert, Cancel as the default button and Esc to cancel.
  func confirmDelete(_ interval: DateInterval, spokenMinutes: Int, title: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "删除 \(title) 的录音？"
    alert.informativeText = "这段 \(spokenMinutes) 分钟的录音、转录和总结都会删除。删除后放进最近删除，30 天内可以恢复。"
    alert.addButton(withTitle: "取消")
    let delete = alert.addButton(withTitle: "删除")
    delete.hasDestructiveAction = true
    let handle = { [weak self] (response: NSApplication.ModalResponse) in
      guard response == .alertSecondButtonReturn else { return }
      self?.delete(interval)
    }
    if let window = NSApp.keyWindow {
      alert.beginSheetModal(for: window, completionHandler: handle)
    } else {
      handle(alert.runModal())
    }
  }

  func delete(_ interval: DateInterval) {
    store.addMark(.deleted, start: interval.start, end: interval.end)
    ui.expandedHours.remove(interval.start)
    if let position = player.position, interval.contains(position) { player.stop() }
    summaries.invalidate(interval)
  }

  func undoDelete(_ interval: DateInterval) {
    store.removeMarks(.deleted, overlapping: interval)
    summaries.invalidate(interval)
  }
}
