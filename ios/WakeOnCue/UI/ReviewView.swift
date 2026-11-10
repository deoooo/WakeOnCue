import SwiftUI
import WakeOnCueCore

/// One day at a time: a recap with the day's to-dos, then each conversation, newest first.
struct ReviewView: View {
  @Environment(AppModel.self) private var model
  @State private var selectedDay = Calendar.current.startOfDay(for: .now)
  @State private var weekRecordings: [RecordingRecord] = []
  @State private var loadedWeek: Date?
  @State private var isPickingMonth = false

  /// The iPhone's own calendar, so the week starts on the day the user's region expects.
  private var calendar: Calendar { Calendar.current }

  private var today: Date { calendar.startOfDay(for: .now) }
  private var isToday: Bool { calendar.isDate(selectedDay, inSameDayAs: today) }

  private var weekStart: Date {
    calendar.dateInterval(of: .weekOfYear, for: selectedDay)?.start ?? selectedDay
  }

  private var weekDays: [Date] {
    (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
  }

  private var isCapturing: Bool {
    guard let status = model.currentRecording?.status else { return false }
    return status == .recording || status == .paused
  }

  private var dayRecordings: [RecordingRecord] {
    weekRecordings.filter {
      calendar.isDate($0.startedAt, inSameDayAs: selectedDay)
        && !(isCapturing && $0.id == model.currentRecording?.id)
        && $0.status != .recording && $0.status != .paused
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header
          weekStrip
          if isToday, isCapturing { recordingNowCard }
          if dayRecordings.isEmpty {
            emptyDay
          } else {
            DayRecapCard(recordings: dayRecordings)
            conversations
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
      }
      .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
      .toolbar(.hidden, for: .navigationBar)
      .task(id: reloadKey) { await load() }
      .sheet(isPresented: $isPickingMonth) { monthPicker }
    }
    .accessibilityIdentifier("review")
  }

  // MARK: Header

  private var header: some View {
    HStack {
      Button {
        model.settingsPresented = true
      } label: {
        Image(systemName: "gearshape")
          .font(.body.weight(.semibold))
          .frame(width: 44, height: 44)
          .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Settings")
      .accessibilityIdentifier("open-settings")

      Spacer()

      Button {
        isPickingMonth = true
      } label: {
        HStack(spacing: 4) {
          Text(monthTitle).font(.headline)
          Image(systemName: "chevron.down").font(.caption.weight(.semibold))
        }
        .frame(minHeight: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Choose a date, \(monthTitle)"))

      Spacer()

      Button("Today") { select(today) }
        .frame(width: 60, height: 44, alignment: .trailing)
        .opacity(isToday ? 0 : 1)
        .disabled(isToday)
        .accessibilityHidden(isToday)
    }
    .padding(.top, 4)
  }

  /// The year appears only when it is not this year.
  private var monthTitle: String {
    let locale = model.settings.language.locale
    if calendar.isDate(selectedDay, equalTo: today, toGranularity: .year) {
      return selectedDay.formatted(Date.FormatStyle(locale: locale).month(.abbreviated))
    }
    return selectedDay.formatted(Date.FormatStyle(locale: locale).year().month(.abbreviated))
  }

  private var weekStrip: some View {
    let recordedDays = Set(weekRecordings.map { calendar.startOfDay(for: $0.startedAt) })
    return HStack(spacing: 4) {
      ForEach(weekDays, id: \.self) { day in
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let future = day > today
        let isTodayCell = calendar.isDate(day, inSameDayAs: today)
        Button {
          select(day)
        } label: {
          VStack(spacing: 3) {
            Text(day.formatted(Date.FormatStyle(locale: model.settings.language.locale).weekday(.narrow)))
              .font(.caption2.weight(.semibold))
            Text(verbatim: "\(calendar.component(.day, from: day))")
              .font(.headline)
            Circle()
              .fill(recordedDays.contains(day) ? (selected ? Color.white : Color.accentColor) : .clear)
              .frame(width: 5, height: 5)
          }
          .frame(maxWidth: .infinity, minHeight: 60)
          .foregroundStyle(
            selected ? Color(uiColor: .systemBackground)
              : future ? Color.secondary.opacity(0.5)
              : isTodayCell ? Color.accentColor : Color.primary
          )
          .background(
            selected ? Color.primary : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel(day.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(model.settings.language.locale)))
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .gesture(
      DragGesture(minimumDistance: 20).onEnded { value in
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        shiftWeek(value.translation.width < 0 ? 1 : -1)
      }
    )
  }

  private var monthPicker: some View {
    NavigationStack {
      DatePicker(
        "Date",
        selection: Binding(get: { selectedDay }, set: { select($0); isPickingMonth = false }),
        in: ...Date.now,
        displayedComponents: .date
      )
      .datePickerStyle(.graphical)
      .environment(\.locale, model.settings.language.locale)
      .padding()
      .navigationTitle("Choose a date")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { isPickingMonth = false }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  // MARK: Content

  private var recordingNowCard: some View {
    Button {
      model.selectedTab = .record
    } label: {
      HStack(spacing: 10) {
        Circle().fill(WakeOnCueColors.record).frame(width: 9, height: 9)
        Text(model.currentRecording?.status == .paused ? "Recording paused" : "Recording now")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(WakeOnCueColors.record)
        Text(elapsedText).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        Spacer()
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .padding(16)
      .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(WakeOnCueColors.record.opacity(0.3), lineWidth: 1.5))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("review-recording-now")
  }

  private var elapsedText: String {
    let seconds = max(0, Int(model.elapsed))
    return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
  }

  private var emptyDay: some View {
    VStack(spacing: 10) {
      Image(systemName: "waveform")
        .font(.title)
        .foregroundStyle(.secondary)
        .frame(width: 64, height: 64)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
      Text(isToday ? "No recordings today yet" : "No recordings this day")
        .font(.headline)
      if isToday {
        Text("Start one in Record, on your Apple Watch, or with the Action Button.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Go to Record") { model.selectedTab = .record }
          .frame(minHeight: 44)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 48)
    .padding(.horizontal, 16)
  }

  private var conversations: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Conversations")
        .font(.headline)
        .padding(.horizontal, 4)
        .padding(.top, 6)
      ForEach(dayRecordings) { recording in
        NavigationLink {
          RecordingDetailView(recording: recording).environment(model)
        } label: {
          ConversationCard(recording: recording)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recording-details-\(recording.id)")
        .contextMenu {
          if recording.canBeDeleted {
            Button(role: .destructive) {
              Task { await model.moveToTrash(recording) }
            } label: {
              Label("Delete recording", systemImage: "trash")
            }
          }
        }
      }
    }
  }

  // MARK: Data

  private var reloadKey: String {
    let current = model.currentRecording.map { "\($0.id)-\($0.status.rawValue)" } ?? "-"
    return "\(weekStart.timeIntervalSince1970)-\(model.libraryVersion)-\(model.transcriptVersion)-\(model.recentRecordings.first?.id ?? "")-\(current)"
  }

  private func load() async {
    let interval = DateInterval(
      start: weekStart, end: calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart)
    do {
      weekRecordings = try await model.recordings(startedIn: interval)
      loadedWeek = weekStart
    } catch is CancellationError {
      return
    } catch {
      model.errorMessage = error.localizedDescription
    }
  }

  private func select(_ day: Date) {
    let start = calendar.startOfDay(for: day)
    guard start <= today else { return }
    selectedDay = start
  }

  private func shiftWeek(_ weeks: Int) {
    guard let moved = calendar.date(byAdding: .weekOfYear, value: weeks, to: selectedDay) else { return }
    select(min(moved, today))
  }
}

/// How many conversations, how long, one sentence on the day, and the day's to-dos.
private struct DayRecapCard: View {
  @Environment(AppModel.self) private var model
  let recordings: [RecordingRecord]
  @State private var recap: String?

  var body: some View {
    let language = model.settings.language
    let todos = recordings.reversed().flatMap { recording in
      (model.summary(for: recording.id)?.actionItems ?? []).map { (recording.id, $0) }
    }
    VStack(alignment: .leading, spacing: 10) {
      Text(
        String(
          format: language.localized("%lld conversations · %@"), Int64(recordings.count),
          spokenDuration(recordings.reduce(0) { $0 + $1.duration }, language: language))
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      if let recap {
        Text(recap)
          .font(.title3.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("day-recap-text")
      }
      if !todos.isEmpty {
        Divider()
        Text(String(format: language.localized("To-dos %lld"), Int64(todos.count)))
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
          TodoRow(recordingID: todo.0, item: todo.1)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("day-recap")
    .task(id: recapKey) { await loadRecap() }
  }

  private var summarized: [(recording: RecordingRecord, summary: RecordingSummary)] {
    recordings.reversed().compactMap { recording in
      model.summary(for: recording.id).map { (recording, $0) }
    }
  }

  private var day: String {
    guard let first = recordings.first else { return "" }
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: first.startedAt)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  private var recapKey: String {
    "\(day)|\(DayRecap.fingerprint(summarized.map { ($0.recording.id, $0.summary.generatedAt) }))|\(model.settings.language.rawValue)"
  }

  /// One summarized conversation needs no model: its own overview is the recap.
  private func loadRecap() async {
    let items = summarized
    guard !items.isEmpty else { recap = nil; return }
    if items.count == 1 {
      recap = items[0].summary.overview
      return
    }
    let key = recapKey
    if let cached = DayRecapCache.text(day: day, fingerprint: key) {
      recap = cached
      return
    }
    guard model.canSummarizeRecordings else { recap = nil; return }
    let language = model.settings.language
    let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened).locale(language.locale)
    let conversations = items.map {
      DayRecap.Conversation(
        time: $0.recording.startedAt.formatted(timeStyle),
        title: $0.recording.resolvedTitle ?? $0.summary.title,
        overview: $0.summary.overview)
    }
    do {
      let text = try await DayRecap.write(
        conversations, language: language, provider: model.settings.activeLanguageModelProvider)
      guard !Task.isCancelled, !text.isEmpty else { return }
      DayRecapCache.save(text, day: day, fingerprint: key)
      recap = text
    } catch {
      recap = nil
    }
  }
}

/// One conversation: when, how long, where it came from, its title and a two-line summary.
struct ConversationCard: View {
  @Environment(AppModel.self) private var model
  let recording: RecordingRecord

  var body: some View {
    let language = model.settings.language
    let source = RecordingSource(recording)
    let todos = model.summary(for: recording.id)?.actionItems.count ?? 0
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(recordingTimeRange(recording, language: language)).monospacedDigit()
        Text("·")
        Text(spokenDuration(recording.duration, language: language))
        Spacer()
        Label(source.title, systemImage: source.symbol)
          .labelStyle(.titleAndIcon)
          .imageScale(.small)
      }
      .font(.footnote)
      .foregroundStyle(.secondary)

      Text(conversationTitle(recording, language: language))
        .font(.headline)
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)

      if model.onDeviceProcessingRecordingIDs.contains(recording.id) {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text("Transcribing and summarizing…")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      } else if let overview = recording.overview {
        Text(overview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }

      if todos > 0 {
        Text(String(format: language.localized("%lld to-dos"), Int64(todos)))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.orange.opacity(0.12), in: Capsule())
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}
