import SwiftUI
import WidgetKit

private let recordingRed = Color(red: 1, green: 69 / 255, blue: 58 / 255)
private let accentOrange = Color(red: 1, green: 159 / 255, blue: 10 / 255)

struct WatchStatusEntry: TimelineEntry {
  let date: Date
  /// Start of the Watch recording, or nil when it is not recording.
  var startedAt: Date?
}

struct WatchStatusProvider: TimelineProvider {
  func placeholder(in context: Context) -> WatchStatusEntry {
    WatchStatusEntry(date: .now, startedAt: Date().addingTimeInterval(-754))
  }

  func getSnapshot(in context: Context, completion: @escaping (WatchStatusEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : currentEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatusEntry>) -> Void) {
    // The Watch app reloads timelines whenever recording starts or stops.
    completion(Timeline(entries: [currentEntry()], policy: .never))
  }

  private func currentEntry() -> WatchStatusEntry {
    WatchStatusEntry(date: .now, startedAt: WatchSnapshotStore.watchRecordingStartedAt)
  }
}

struct WatchStatusWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: WatchStatusEntry

  private var isRecording: Bool { entry.startedAt != nil }
  private var tint: Color { isRecording ? recordingRed : .secondary }
  private var symbol: String { isRecording ? "record.circle.fill" : "mic" }
  private var statusTitle: LocalizedStringKey { isRecording ? "Recording" : "Not recording" }

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
        Group {
          if let startedAt = entry.startedAt {
            Text(startedAt, style: .timer)
          } else {
            Text("Tap to open")
          }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .accessoryInline:
      if let startedAt = entry.startedAt {
        Text(startedAt, style: .timer)
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
          .strokeBorder(tint, lineWidth: isRecording ? 3 : 1.5)
        Image(systemName: symbol)
          .font(.title3)
          .foregroundStyle(tint)
          .widgetAccentable()
      }
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
    .description("Shows whether the Watch is recording.")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
  }
}

@main
struct WakeOnCueWatchWidgets: WidgetBundle {
  var body: some Widget {
    WatchStatusWidget()
  }
}
