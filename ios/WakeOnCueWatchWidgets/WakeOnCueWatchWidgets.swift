import SwiftUI
import WidgetKit

private let recordingRed = Color(red: 1, green: 69 / 255, blue: 58 / 255)
private let accentOrange = Color(red: 1, green: 159 / 255, blue: 10 / 255)

struct WatchStatusEntry: TimelineEntry {
  let date: Date
  let snapshot: WatchRecordingSnapshot
  var watchRecordingStartedAt: Date? = nil
}

struct WatchStatusProvider: TimelineProvider {
  func placeholder(in context: Context) -> WatchStatusEntry {
    WatchStatusEntry(
      date: .now,
      snapshot: WatchRecordingSnapshot(phase: .recording, elapsed: 754)
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (WatchStatusEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : currentEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatusEntry>) -> Void) {
    // The Watch app reloads timelines whenever the iPhone state changes.
    completion(Timeline(entries: [currentEntry()], policy: .never))
  }

  private func currentEntry() -> WatchStatusEntry {
    var snapshot = WatchSnapshotStore.load()
    let watchStart = WatchSnapshotStore.watchRecordingStartedAt
    if let watchStart {
      // A Watch recording shows exactly like an iPhone one: red ring and a running clock.
      snapshot = WatchRecordingSnapshot(phase: .recording, elapsed: Date().timeIntervalSince(watchStart))
    }
    return WatchStatusEntry(
      date: .now,
      snapshot: snapshot,
      watchRecordingStartedAt: watchStart
    )
  }
}

struct WatchStatusWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: WatchStatusEntry

  private var phase: WatchRecordingPhase { entry.snapshot.phase }
  private var tint: Color {
    phase == .recording ? recordingRed : .secondary
  }

  var body: some View {
    switch family {
    case .accessoryRectangular:
      VStack(alignment: .leading, spacing: 1) {
        Text("WakeOnCue")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(accentOrange)
        Text(statusTitle)
          .font(.headline)
          .widgetAccentable()
        detail
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .accessoryInline:
      if phase == .recording {
        Text(entry.snapshot.timerStart, style: .timer)
      } else {
        Text(statusTitle)
      }
    case .accessoryCorner:
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(tint)
        .widgetLabel { Text(statusTitle) }
    default:
      ZStack {
        AccessoryWidgetBackground()
        Circle()
          .strokeBorder(tint, lineWidth: phase == .recording ? 3 : 1.5)
        Image(systemName: symbol)
          .font(.title3)
          .foregroundStyle(tint)
          .widgetAccentable()
      }
    }
  }

  @ViewBuilder private var detail: some View {
    switch phase {
    case .recording:
      Text(entry.snapshot.timerStart, style: .timer)
    case .paused:
      Text(Duration.seconds(Int(entry.snapshot.elapsed)).formatted(.time(pattern: .hourMinuteSecond)))
    case .idle, .finishing:
      Text("Tap to open")
    }
  }

  private var statusTitle: LocalizedStringKey {
    if entry.watchRecordingStartedAt != nil { return "Recording on Watch" }
    switch phase {
    case .recording: return "Recording"
    case .paused: return "Paused"
    case .finishing: return "Saving on iPhone"
    case .idle: return "Not recording"
    }
  }

  private var symbol: String {
    switch phase {
    case .recording: "record.circle.fill"
    case .paused: "pause.circle"
    case .finishing: "arrow.down.circle"
    case .idle: "mic"
    }
  }
}

struct WatchStatusWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WatchSnapshotStore.statusWidgetKind, provider: WatchStatusProvider()) {
      entry in
      WatchStatusWidgetView(entry: entry)
        .containerBackground(.black, for: .widget)
    }
    .configurationDisplayName("Recording status")
    .description("Shows whether WakeOnCue is recording.")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
  }
}

struct WatchCaptureWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WatchSnapshotStore.captureWidgetKind, provider: WatchStatusProvider()) {
      _ in
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: "mic.fill")
          .font(.title3)
          .widgetAccentable()
      }
      .widgetLabel { Text("Save that") }
      .widgetURL(WatchSnapshotStore.captureURL)
      .containerBackground(.black, for: .widget)
    }
    .configurationDisplayName("Save that")
    .description("Marks the last 2 minutes")
    .supportedFamilies([.accessoryCircular, .accessoryCorner])
  }
}

@main
struct WakeOnCueWatchWidgets: WidgetBundle {
  var body: some Widget {
    WatchStatusWidget()
    WatchCaptureWidget()
  }
}
