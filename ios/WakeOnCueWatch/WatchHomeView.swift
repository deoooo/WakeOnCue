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

  static func clock(_ value: TimeInterval) -> String {
    Duration.seconds(Int(value)).formatted(.time(pattern: .hourMinuteSecond))
  }
}

struct WatchHomeView: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          WatchStatusHeader()
          TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
              Text(clockCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
              Text(clockText(at: context.date))
                .font(.title3.weight(.semibold).monospacedDigit())
                .accessibilityIdentifier("watch-clock")
            }
          }
          if model.isWatchRecording {
            WatchLevelMeter(level: model.inputLevel)
          }

          Button {
            Task { await model.toggleRecording() }
          } label: {
            Group {
              if model.isWorking {
                ProgressView()
              } else {
                Label(
                  model.isWatchRecording ? "Stop" : "Record",
                  systemImage: model.isWatchRecording ? "stop.fill" : "record.circle")
              }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.borderedProminent)
          .tint(model.isWatchRecording ? .cueControl : .cueAccent)
          .foregroundStyle(model.isWatchRecording ? .white : .black)
          .disabled(model.isWorking)
          .accessibilityIdentifier("watch-toggle-recording")

          if let message = model.message {
            Text(message)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          WatchSyncSummary()

          NavigationLink {
            WatchRecordingsView()
          } label: {
            HStack {
              Text("Recordings")
              Spacer()
              Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("watch-recordings")
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

  private var clockCaption: LocalizedStringKey {
    model.isWatchRecording ? "This recording" : "Recorded today on Watch"
  }

  private func clockText(at date: Date) -> String {
    if let startedAt = model.watchRecordingStartedAt {
      return WatchDurationText.clock(date.timeIntervalSince(startedAt))
    }
    return WatchDurationText.hoursMinutes(model.todayDuration(at: date))
  }
}

struct WatchStatusHeader: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(model.isWatchRecording ? "Recording" : "Not recording")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(color)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("watch-status")
    .accessibilityValue(model.isWatchRecording ? "watch-recording" : "idle")
  }

  private var color: Color { model.isWatchRecording ? .cueRecording : .secondary }
}

/// One line on how much of the Watch audio has reached the iPhone.
struct WatchSyncSummary: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: symbol)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.footnote.weight(.semibold))
        if let detail {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(Color.cueControl, in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("watch-sync")
  }

  private var isWaiting: Bool { model.pendingSegments > 0 || model.pendingSummaries > 0 }

  private var symbol: String {
    if !isWaiting { return "checkmark.circle.fill" }
    return model.isReachable ? "arrow.up.circle" : "iphone.slash"
  }

  private var tint: Color {
    if !isWaiting { return .cueSaved }
    return model.isReachable ? .cueAccent : .secondary
  }

  private var title: LocalizedStringKey {
    if !isWaiting { return "All sent to iPhone" }
    if model.pendingSegments == 0 { return "Finishing up with iPhone" }
    return "\(model.pendingSegments) min waiting to send"
  }

  private var detail: LocalizedStringKey? {
    guard isWaiting else { return nil }
    return model.isReachable ? "Sending to iPhone" : "Sends when iPhone is nearby"
  }
}

struct WatchLevelMeter: View {
  let level: Float

  var body: some View {
    GeometryReader { proxy in
      Capsule()
        .fill(Color.cueControl)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(Color.cueAccent)
            .frame(width: max(4, proxy.size.width * CGFloat(min(1, level * 3))))
        }
    }
    .frame(height: 4)
    .accessibilityHidden(true)
  }
}

/// Watch recordings by day, each with how much reached the iPhone.
struct WatchRecordingsView: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    List {
      if model.recordings.isEmpty {
        Text("No recordings on this Watch in the last 7 days.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach(days, id: \.self) { day in
        Section {
          ForEach(model.recordings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }) {
            WatchRecordingRow(recording: $0)
          }
        } header: {
          Text(dayTitle(day))
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
      VStack(alignment: .leading, spacing: 2) {
        Text(timeRange(at: context.date))
          .font(.footnote.weight(.semibold).monospacedDigit())
        Text(WatchDurationText.hoursMinutes(recording.duration(at: context.date)))
          .font(.caption2)
          .foregroundStyle(.secondary)
        Label(status, systemImage: symbol)
          .font(.caption2)
          .foregroundStyle(tint)
        if let ending {
          Text(ending)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func timeRange(at now: Date) -> String {
    let start = recording.startedAt.formatted(date: .omitted, time: .shortened)
    guard recording.isEnded else { return "\(start) –" }
    let end = recording.startedAt.addingTimeInterval(recording.duration(at: now))
    return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
  }

  private var status: LocalizedStringKey {
    if !recording.isEnded {
      return "Recording · \(recording.deliveredSegments)/\(recording.segmentCount) min sent"
    }
    if recording.isFullyDelivered { return "On iPhone" }
    if recording.pendingSegments == 0 { return "Finishing up with iPhone" }
    return "Sent \(recording.deliveredSegments)/\(recording.segmentCount) min"
  }

  private var symbol: String {
    if !recording.isEnded { return "record.circle" }
    return recording.isFullyDelivered ? "checkmark.circle.fill" : "arrow.up.circle"
  }

  private var tint: Color {
    if !recording.isEnded { return .cueRecording }
    return recording.isFullyDelivered ? .cueSaved : .cueAccent
  }

  /// Only unusual endings are called out.
  private var ending: LocalizedStringKey? {
    guard recording.isEnded else { return nil }
    switch recording.state.summary.endReason {
    case WatchCaptureStopReason.interruption.rawValue: return "Stopped by a call or Siri"
    case WatchCaptureStopReason.writeFailure.rawValue: return "Stopped: couldn't save audio"
    case "recovered": return "App closed; recovered what was saved"
    default: return nil
    }
  }
}
