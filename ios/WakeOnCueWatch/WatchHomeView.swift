import SwiftUI

extension Color {
  static let cueAccent = Color(red: 1, green: 159 / 255, blue: 10 / 255)
  static let cueRecording = Color(red: 1, green: 69 / 255, blue: 58 / 255)
  static let cueSaved = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
  static let cueControl = Color(white: 0.17)
}

enum WatchDurationText {
  /// "4 hr 30 min", or just "40 min" under an hour.
  static func hoursMinutes(_ value: TimeInterval) -> String {
    let allowed: Set<Duration.UnitsFormatStyle.Unit> = value < 3600 ? [.minutes] : [.hours, .minutes]
    return Duration.seconds(Int(value)).formatted(
      .units(allowed: allowed, width: .abbreviated, zeroValueUnits: .show(length: 1)))
  }

  /// "4:30" — today's total, hours and minutes.
  static func hourMinuteClock(_ value: TimeInterval) -> String {
    Duration.seconds(Int(value)).formatted(.time(pattern: .hourMinute))
  }

  static func clock(_ value: TimeInterval) -> String {
    Duration.seconds(Int(value)).formatted(.time(pattern: .hourMinuteSecond))
  }
}

/// One screen, one job: a big number on top, the record button under the thumb.
struct WatchHomeView: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        VStack(alignment: .leading, spacing: 4) {
          Text(model.isWatchRecording ? "This recording" : "Recorded today")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Text(bigNumber(at: context.date))
            .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .accessibilityIdentifier("watch-clock")
          if model.isWatchRecording {
            WatchLevelMeter(level: model.inputLevel)
              .padding(.vertical, 2)
          }
          if let message = model.message {
            Text(message)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .minimumScaleFactor(0.8)
          } else {
            WatchSyncLine()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .containerBackground(
        model.isWatchRecording ? Color.cueRecording.gradient : Color.black.gradient,
        for: .navigation
      )
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          WatchStatusHeader()
        }
        ToolbarItemGroup(placement: .bottomBar) {
          NavigationLink {
            WatchRecordingsView()
          } label: {
            Image(systemName: "list.bullet")
          }
          .accessibilityLabel("Recordings")
          .accessibilityIdentifier("watch-recordings")

          Button {
            Task { await model.toggleRecording() }
          } label: {
            Group {
              if model.isWorking {
                ProgressView()
              } else {
                Image(systemName: model.isWatchRecording ? "stop.fill" : "mic.fill")
                  .font(.title3)
              }
            }
            .frame(width: 44, height: 44)
          }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.circle)
          .tint(model.isWatchRecording ? Color.white : Color.cueAccent)
          .foregroundStyle(model.isWatchRecording ? Color.cueRecording : Color.black)
          .disabled(model.isWorking)
          .accessibilityLabel(model.isWatchRecording ? "Stop" : "Record")
          .accessibilityIdentifier("watch-toggle-recording")

          Spacer()
        }
      }
    }
    .task {
      // Delivery confirmations arrive in the background; refresh the counts while on screen.
      while !Task.isCancelled {
        model.refresh()
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  private func bigNumber(at date: Date) -> String {
    if let startedAt = model.watchRecordingStartedAt {
      return WatchDurationText.clock(date.timeIntervalSince(startedAt))
    }
    return WatchDurationText.hourMinuteClock(model.todayDuration(at: date))
  }
}

struct WatchStatusHeader: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    Group {
      if model.isWatchRecording {
        Label("Recording", systemImage: "circle.fill")
          .labelStyle(WatchDotLabelStyle())
          .foregroundStyle(.white)
      } else {
        Text("WakeOnCue")
          .foregroundStyle(Color.cueAccent)
      }
    }
    .font(.footnote.weight(.semibold))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("watch-status")
    .accessibilityValue(model.isWatchRecording ? "watch-recording" : "idle")
  }
}

private struct WatchDotLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.font(.system(size: 7))
      configuration.title
    }
  }
}

/// One line on how much of the Watch audio has reached the iPhone.
struct WatchSyncLine: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    if !model.recordings.isEmpty {
      Label(title, systemImage: symbol)
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .lineLimit(2)
        .accessibilityIdentifier("watch-sync")
    }
  }

  private var isWaiting: Bool { model.pendingSegments > 0 || model.pendingSummaries > 0 }

  private var symbol: String {
    if !isWaiting { return "checkmark.circle.fill" }
    return model.isReachable ? "arrow.up.circle" : "iphone.slash"
  }

  /// On the red recording background only white reads well.
  private var tint: Color {
    if model.isWatchRecording { return .white }
    if !isWaiting { return .cueSaved }
    return model.isReachable ? .cueAccent : .secondary
  }

  private var title: LocalizedStringKey {
    if !isWaiting { return "All sent to iPhone" }
    if model.pendingSegments == 0 { return "Finishing up with iPhone" }
    return model.isReachable
      ? "\(model.pendingSegments) min waiting for iPhone"
      : "\(model.pendingSegments) min waiting · iPhone not nearby"
  }
}

struct WatchLevelMeter: View {
  let level: Float

  var body: some View {
    GeometryReader { proxy in
      Capsule()
        .fill(Color.white.opacity(0.25))
        .overlay(alignment: .leading) {
          Capsule()
            .fill(Color.white)
            .frame(width: max(4, proxy.size.width * CGFloat(min(1, level * 3))))
        }
    }
    .frame(height: 4)
    .accessibilityHidden(true)
  }
}

/// Watch recordings by day, one compact row each.
struct WatchRecordingsView: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    List {
      if model.recordings.isEmpty {
        Text("No recordings on this Watch in the last 7 days.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .listRowBackground(Color.clear)
      }
      ForEach(days, id: \.self) { day in
        Section(dayTitle(day)) {
          ForEach(model.recordings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }) {
            WatchRecordingRow(recording: $0)
          }
        }
      }
    }
    .navigationTitle("Recordings")
  }

  private var days: [Date] {
    var seen = Set<Date>()
    return model.recordings.map { Calendar.current.startOfDay(for: $0.startedAt) }
      .filter { seen.insert($0).inserted }
  }

  private func dayTitle(_ day: Date) -> String {
    if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
    if Calendar.current.isDateInYesterday(day) { return String(localized: "Yesterday") }
    return day.formatted(.dateTime.month().day().weekday(.abbreviated))
  }
}

struct WatchRecordingRow: View {
  let recording: WatchRecordingStatus

  var body: some View {
    TimelineView(.periodic(from: .now, by: recording.isEnded ? 3600 : 1)) { context in
      HStack(spacing: 6) {
        VStack(alignment: .leading, spacing: 1) {
          Text(timeRange(at: context.date))
            .font(.footnote.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          Text(detail(at: context.date))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        Spacer(minLength: 2)
        trailing
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var trailing: some View {
    if !recording.isEnded {
      Image(systemName: "record.circle")
        .foregroundStyle(Color.cueRecording)
        .accessibilityLabel("Recording")
    } else if recording.isFullyDelivered {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.cueSaved)
        .accessibilityLabel("On iPhone")
    } else if recording.pendingSegments == 0 {
      Image(systemName: "arrow.up.circle")
        .foregroundStyle(Color.cueAccent)
        .accessibilityLabel("Finishing up with iPhone")
    } else {
      Text(verbatim: "\(recording.deliveredSegments)/\(recording.segmentCount)")
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(Color.cueAccent)
        .accessibilityLabel("Sent \(recording.deliveredSegments)/\(recording.segmentCount) min")
    }
  }

  private func timeRange(at now: Date) -> String {
    let start = recording.startedAt.formatted(date: .omitted, time: .shortened)
    guard recording.isEnded else { return "\(start)–" }
    let end = recording.startedAt.addingTimeInterval(recording.duration(at: now))
    return "\(start)–\(end.formatted(date: .omitted, time: .shortened))"
  }

  private func detail(at now: Date) -> String {
    let duration = WatchDurationText.hoursMinutes(recording.duration(at: now))
    guard let ending else { return duration }
    return "\(duration) · \(ending)"
  }

  /// Only unusual endings are called out.
  private var ending: String? {
    guard recording.isEnded else { return nil }
    switch recording.state.summary.endReason {
    case WatchCaptureStopReason.interruption.rawValue: return String(localized: "Call or Siri")
    case WatchCaptureStopReason.writeFailure.rawValue: return String(localized: "Couldn't save")
    case "recovered": return String(localized: "App closed")
    default: return nil
    }
  }
}
