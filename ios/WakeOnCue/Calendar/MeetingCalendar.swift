import Foundation
import WakeOnCueCore

/// A calendar event reduced to what WakeOnCue needs, so the rules below stay free of EventKit.
struct MeetingEvent: Equatable, Sendable {
  var id: String
  var title: String
  var start: Date
  var end: Date
  var calendarID: String
  var isAllDay = false
  var isCanceled = false
  /// The user's own invitation status is declined.
  var isDeclined = false
  var attendees: [MeetingAttendee] = []
  var hasVideoLink = false

  /// Recurring events share one identifier, so an occurrence is the identifier plus its start.
  var occurrenceKey: String { "\(id)@\(Int(start.timeIntervalSince1970))" }

  var hasOtherAttendees: Bool { attendees.contains { !$0.isCurrentUser } }
}

struct MeetingAttendee: Equatable, Sendable {
  var name: String?
  var email: String?
  var isCurrentUser = false

  var displayName: String? {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty { return trimmed }
    return email
  }
}

/// The user's choices for which calendar events count as meetings.
struct MeetingPreferences: Equatable, Sendable {
  /// Empty means every calendar.
  var calendarIDs: Set<String> = []
  var requiresOthersOrVideoLink = false
  var reminderLeadMinutes = 1
}

enum MeetingRules {
  static let videoLinkHosts = [
    "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
    "webex.com", "facetime.apple.com", "whereby.com", "meet.jit.si", "chime.aws",
    "meeting.tencent.com", "voovmeeting.com", "vc.feishu.cn", "larksuite.com", "meeting.dingtalk.com",
  ]
  /// Starting a recording this long before an event still links it to that event.
  static let earlyStartAllowance: TimeInterval = 10 * 60

  static func containsVideoLink(_ texts: [String?]) -> Bool {
    texts.contains { text in
      guard let text = text?.lowercased() else { return false }
      return videoLinkHosts.contains { text.contains($0) }
    }
  }

  static func qualifies(_ event: MeetingEvent, preferences: MeetingPreferences) -> Bool {
    guard !event.isAllDay, !event.isCanceled, !event.isDeclined, event.end > event.start else {
      return false
    }
    if !preferences.calendarIDs.isEmpty, !preferences.calendarIDs.contains(event.calendarID) {
      return false
    }
    if preferences.requiresOthersOrVideoLink {
      return event.hasOtherAttendees || event.hasVideoLink
    }
    return true
  }

  /// The meeting a recording started at `date` belongs to: one in progress, or about to begin,
  /// preferring the one whose start is closest.
  static func meeting(
    at date: Date, in events: [MeetingEvent], preferences: MeetingPreferences
  ) -> MeetingEvent? {
    events
      .filter {
        qualifies($0, preferences: preferences)
          && $0.start.addingTimeInterval(-earlyStartAllowance) <= date && date < $0.end
      }
      .min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
  }
}

struct MeetingReminder: Equatable, Sendable {
  static let identifierPrefix = "calendar.meeting."

  var identifier: String
  var event: MeetingEvent
  var fireDate: Date
}

enum MeetingReminderPlanner {
  /// iOS keeps at most 64 pending local notifications per app; leave room for everything else.
  static let maximumReminders = 32
  static let lookahead: TimeInterval = 7 * 24 * 60 * 60

  static func reminders(
    for events: [MeetingEvent],
    preferences: MeetingPreferences,
    now: Date,
    limit: Int = maximumReminders
  ) -> [MeetingReminder] {
    let lead = TimeInterval(max(0, preferences.reminderLeadMinutes) * 60)
    var seen: Set<String> = []
    return
      events
      .filter { MeetingRules.qualifies($0, preferences: preferences) }
      .map {
        MeetingReminder(
          identifier: MeetingReminder.identifierPrefix + $0.occurrenceKey,
          event: $0,
          fireDate: $0.start.addingTimeInterval(-lead)
        )
      }
      .filter { $0.fireDate > now && $0.fireDate <= now.addingTimeInterval(lookahead) }
      .sorted { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }
      .filter { seen.insert($0.identifier).inserted }
      .prefix(max(0, limit))
      .map { $0 }
  }
}

/// The calendar event a recording belongs to, stored in the recording's metadata.
struct MeetingLink: Equatable, Sendable {
  static let eventIDKey = "calendar_event_id"
  static let eventTitleKey = "calendar_event_title"
  static let eventStartKey = "calendar_event_start"
  static let eventEndKey = "calendar_event_end"
  static let attendeesKey = "calendar_attendees"

  var eventID: String
  var title: String
  var start: Date
  var end: Date
  var attendeeNames: [String]

  init(event: MeetingEvent) {
    eventID = event.id
    title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
    start = event.start
    end = event.end
    attendeeNames = event.attendees.filter { !$0.isCurrentUser }.compactMap(\.displayName)
  }

  init?(metadata: [String: String]) {
    guard let eventID = metadata[Self.eventIDKey], !eventID.isEmpty,
      let start = metadata[Self.eventStartKey].flatMap(Self.parseDate),
      let end = metadata[Self.eventEndKey].flatMap(Self.parseDate)
    else { return nil }
    self.eventID = eventID
    title = metadata[Self.eventTitleKey] ?? ""
    self.start = start
    self.end = end
    attendeeNames =
      metadata[Self.attendeesKey]?.split(separator: "\n").map(String.init) ?? []
  }

  /// Metadata to merge into a new recording, including its title when the event has one.
  var metadata: [String: String] {
    var values = [
      Self.eventIDKey: eventID,
      Self.eventTitleKey: title,
      Self.eventStartKey: start.ISO8601Format(),
      Self.eventEndKey: end.ISO8601Format(),
      Self.attendeesKey: attendeeNames.joined(separator: "\n"),
    ]
    if !title.isEmpty { values[RecordingRecord.titleMetadataKey] = title }
    return values
  }

  private static func parseDate(_ value: String) -> Date? {
    try? Date(value, strategy: .iso8601)
  }
}

/// Plain-text meeting notes the user reviews before sending them to attendees.
enum MeetingNotes {
  static func text(
    title: String,
    date: Date,
    summary: RecordingSummary?,
    language: AppLanguage,
    timeZone: TimeZone = .current
  ) -> String {
    var style = Date.FormatStyle(date: .long, time: .shortened)
    style.locale = language.locale
    style.timeZone = timeZone
    var lines = [title, date.formatted(style)]
    if let summary {
      let overview = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
      if !overview.isEmpty {
        lines += ["", language.localized("Overview"), overview]
      }
      if !summary.keyPoints.isEmpty {
        lines += ["", language.localized("Key points")] + summary.keyPoints.map { "- \($0)" }
      }
      if !summary.actionItems.isEmpty {
        lines += ["", language.localized("Follow-ups")] + summary.actionItems.map { "- \($0)" }
      }
    }
    lines += ["", language.localized("Notes written on iPhone with WakeOnCue. Check them against the recording.")]
    return lines.joined(separator: "\n")
  }

  /// Email addresses of everyone else invited, without duplicates.
  static func recipients(_ attendees: [MeetingAttendee]) -> [String] {
    var seen: Set<String> = []
    return attendees.compactMap { attendee in
      guard !attendee.isCurrentUser,
        let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines),
        email.contains("@"), seen.insert(email.lowercased()).inserted
      else { return nil }
      return email
    }
  }
}
