import SwiftUI
import UIKit
import WakeOnCueCore

struct RecordingShareSheet: UIViewControllerRepresentable {
  let fileURL: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

func formattedStartDate(_ date: Date, language: AppLanguage) -> String {
  date.formatted(
    Date.FormatStyle(date: .abbreviated, time: .shortened)
      .locale(language.locale)
  )
}

func localizedSpeakerName(
  _ speaker: RealtimeSpeaker?,
  language: AppLanguage,
  personNames: [String: String] = [:]
) -> String {
  guard let speaker else { return language.localized("Unknown speaker") }
  if speaker.personID == RealtimeSpeaker.selfPersonID { return language.localized("Me") }
  if let personID = speaker.personID, let name = personNames[personID] { return name }
  let parts = speaker.displayName.split(separator: " ", omittingEmptySubsequences: true)
  if parts.count == 2, parts[0].localizedCaseInsensitiveCompare("Speaker") == .orderedSame,
    let number = Int(parts[1])
  {
    return String(format: language.localized("Speaker %d"), locale: language.locale, number)
  }
  if speaker.displayName.localizedCaseInsensitiveCompare("Unknown speaker") == .orderedSame {
    return language.localized("Unknown speaker")
  }
  return speaker.displayName
}

struct RecordButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.95 : 1))
      .opacity(configuration.isPressed ? 0.9 : 1)
      .animation(
        reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.72),
        value: configuration.isPressed
      )
  }
}

enum WakeOnCueColors {
  /// Only for recording: the record button, the recording dot and Finish.
  static let record = Color(red: 0.90, green: 0.13, blue: 0.23)
}

/// Where a recording came from, shown as a small grey symbol on its card.
enum RecordingSource {
  case iPhone
  case watch
  case importedFile

  @MainActor init(_ recording: RecordingRecord) {
    switch recording.metadata[WatchRecordingImporter.sourceMetadataKey] {
    case WatchRecordingImporter.sourceMetadataValue: self = .watch
    case AudioFileImporter.sourceMetadataValue: self = .importedFile
    default: self = .iPhone
    }
  }

  var symbol: String {
    switch self {
    case .iPhone: "iphone"
    case .watch: "applewatch"
    case .importedFile: "doc"
    }
  }

  var title: LocalizedStringKey {
    switch self {
    case .iPhone: "iPhone"
    case .watch: "Apple Watch"
    case .importedFile: "Imported"
    }
  }
}

/// "10:02 – 10:48" for a recording, in the app's language.
func recordingTimeRange(_ recording: RecordingRecord, language: AppLanguage) -> String {
  let style = Date.FormatStyle(date: .omitted, time: .shortened).locale(language.locale)
  let end = recording.startedAt.addingTimeInterval(max(0, recording.duration))
  return "\(recording.startedAt.formatted(style)) – \(end.formatted(style))"
}

/// The title on a day's page: the recording's own or automatic title, else "Recording at 15:00",
/// since the date is already on the page.
func conversationTitle(_ recording: RecordingRecord, language: AppLanguage) -> String {
  if let title = recording.resolvedTitle { return title }
  let time = recording.startedAt.formatted(
    Date.FormatStyle(date: .omitted, time: .shortened).locale(language.locale))
  return String(format: language.localized("Recording at %@"), time)
}

/// "46 min" or "1 hr 5 min", rounded to the minute, never "0 min".
func spokenDuration(_ interval: TimeInterval, language: AppLanguage) -> String {
  let seconds = max(0, interval)
  if seconds < 60 {
    return String(format: language.localized("%lld sec"), Int64(seconds.rounded()))
  }
  let minutes = Int((seconds / 60).rounded())
  if minutes < 60 { return String(format: language.localized("%lld min"), Int64(minutes)) }
  return String(
    format: language.localized("%lld hr %lld min"), Int64(minutes / 60), Int64(minutes % 60))
}

/// The to-dos a user has ticked off, kept on this iPhone. Keyed by the recording and the text
/// of the follow-up, so a regenerated summary with the same item keeps its tick.
@MainActor
@Observable
final class TodoCompletion {
  static let shared = TodoCompletion()
  private static let key = "todos.done.v1"
  private var done: Set<String>
  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    done = Set(defaults.stringArray(forKey: Self.key) ?? [])
  }

  func isDone(recordingID: String, item: String) -> Bool {
    done.contains(Self.id(recordingID, item))
  }

  func toggle(recordingID: String, item: String) {
    let id = Self.id(recordingID, item)
    if done.contains(id) { done.remove(id) } else { done.insert(id) }
    defaults.set(Array(done), forKey: Self.key)
  }

  private static func id(_ recordingID: String, _ item: String) -> String {
    "\(recordingID)\u{1F}\(item.trimmingCharacters(in: .whitespacesAndNewlines))"
  }
}

/// A round to-do checkbox and its text.
struct TodoRow: View {
  let recordingID: String
  let item: String
  var detail: String? = nil
  private var todos: TodoCompletion { .shared }

  var body: some View {
    let isDone = todos.isDone(recordingID: recordingID, item: item)
    Button {
      todos.toggle(recordingID: recordingID, item: item)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
        VStack(alignment: .leading, spacing: 2) {
          Text(item)
            .strikethrough(isDone)
            .foregroundStyle(isDone ? .secondary : .primary)
            .multilineTextAlignment(.leading)
          if let detail {
            Text(detail).font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isDone ? Text("Done") : Text("Not done"))
  }
}
