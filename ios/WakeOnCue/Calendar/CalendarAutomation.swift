@preconcurrency import EventKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// Reads the user's calendar to remind them before meetings and to link recordings to the
/// meeting they capture. iOS does not let apps open the microphone from the background, so a
/// reminder's Start Recording action opens WakeOnCue, which then starts recording.
@MainActor
@Observable
final class CalendarAutomation {
  nonisolated static let reminderCategory = "calendar.meeting-reminder"
  nonisolated static let startAction = "calendar.meeting-reminder.start"
  static let leadMinuteOptions = [0, 1, 5, 10]
  private static let eventIDInfoKey = "eventID"
  private static let eventStartInfoKey = "eventStart"
  private static let linkEnabledKey = "calendar.link-enabled"
  private static let remindersEnabledKey = "calendar.reminders-enabled"
  private static let leadMinutesKey = "calendar.reminder-lead-minutes"
  private static let calendarIDsKey = "calendar.calendar-ids"
  private static let requiresOthersKey = "calendar.requires-others-or-video"
  /// A reminder tapped this long ago no longer decides which meeting the next recording is.
  private static let requestedMeetingExpiry: TimeInterval = 60 * 60

  /// Stays `.notDetermined` until `refresh()` has asked the system, which only happens
  /// while the feature is on.
  private(set) var authorization = EKAuthorizationStatus.notDetermined
  private(set) var calendars: [EKCalendar] = []

  var linkEnabled: Bool {
    didSet {
      UserDefaults.standard.set(linkEnabled, forKey: Self.linkEnabledKey)
      Task { await refresh() }
    }
  }
  var remindersEnabled: Bool {
    didSet {
      UserDefaults.standard.set(remindersEnabled, forKey: Self.remindersEnabledKey)
      Task { await refresh() }
    }
  }
  var preferences: MeetingPreferences {
    didSet {
      let defaults = UserDefaults.standard
      defaults.set(preferences.reminderLeadMinutes, forKey: Self.leadMinutesKey)
      defaults.set(Array(preferences.calendarIDs).sorted(), forKey: Self.calendarIDsKey)
      defaults.set(preferences.requiresOthersOrVideoLink, forKey: Self.requiresOthersKey)
      Task { await refresh() }
    }
  }

  @ObservationIgnored var onStartRequested: (() async -> Void)?
  /// Created off the main thread on first use; EventKit must never block app launch.
  @ObservationIgnored private var store: EKEventStore?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var requestedMeeting: (eventID: String, start: Date, at: Date)?

  var hasAccess: Bool { authorization == .fullAccess }
  var hasEventStore: Bool { store != nil }

  init() {
    let defaults = UserDefaults.standard
    linkEnabled = defaults.bool(forKey: Self.linkEnabledKey)
    remindersEnabled = defaults.bool(forKey: Self.remindersEnabledKey)
    preferences = MeetingPreferences(
      calendarIDs: Set(defaults.stringArray(forKey: Self.calendarIDsKey) ?? []),
      requiresOthersOrVideoLink: defaults.bool(forKey: Self.requiresOthersKey),
      reminderLeadMinutes: defaults.object(forKey: Self.leadMinutesKey) as? Int ?? 1
    )
    NotificationRouter.shared.register(
      UNNotificationCategory(
        identifier: Self.reminderCategory,
        actions: [
          UNNotificationAction(
            identifier: Self.startAction,
            title: AppLanguage.localized("Start Recording"),
            options: [.foreground]
          )
        ],
        intentIdentifiers: []
      )
    ) { [weak self] response in
      await self?.handle(response)
    }
  }

  /// Keeps reminders current while the app runs. Safe to call more than once.
  func start() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    for name in [Notification.Name.EKEventStoreChanged, UIApplication.didBecomeActiveNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in await self?.refresh() }
        })
    }
    Task { await refresh() }
  }

  /// Asks for full calendar access, then for notification permission when reminders are on.
  func requestAccess() async {
    if !hasAccess {
      _ = try? await EKEventStore().requestFullAccessToEvents()
      // A store created before access was granted does not see events.
      store = nil
    }
    if remindersEnabled {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound,
      ])
    }
    await refresh()
  }

  func refresh() async {
    guard linkEnabled else {
      calendars = []
      await scheduleReminders()
      return
    }
    authorization = await Task.detached { EKEventStore.authorizationStatus(for: .event) }.value
    if hasAccess {
      let store = await loadedStore()
      calendars = await Task.detached {
        store.calendars(for: .event).sorted { $0.title < $1.title }
      }.value
    } else {
      calendars = []
    }
    await scheduleReminders()
  }

  private func loadedStore() async -> EKEventStore {
    if let store { return store }
    let created = await Task.detached { EKEventStore() }.value
    if let store { return store }
    store = created
    return created
  }

  /// Metadata linking a recording that starts now to its meeting, or nothing.
  func recordingMetadata(startingAt date: Date) -> [String: String] {
    defer { requestedMeeting = nil }
    guard linkEnabled, hasAccess else { return [:] }
    let events = meetingEvents(
      from: date.addingTimeInterval(-24 * 60 * 60), to: date.addingTimeInterval(24 * 60 * 60))
    if let requested = requestedMeeting,
      date.timeIntervalSince(requested.at) < Self.requestedMeetingExpiry,
      let event = events.first(where: { $0.id == requested.eventID && $0.start == requested.start })
    {
      return MeetingLink(event: event).metadata
    }
    return MeetingRules.meeting(at: date, in: events, preferences: preferences)
      .map { MeetingLink(event: $0).metadata } ?? [:]
  }

  /// Everyone else invited to the linked meeting, read from the calendar when it still exists.
  func recipients(for link: MeetingLink) -> [String] {
    guard hasAccess else { return [] }
    let events = meetingEvents(
      from: link.start.addingTimeInterval(-60), to: link.end.addingTimeInterval(60))
    guard let event = events.first(where: { $0.id == link.eventID && $0.start == link.start })
    else { return [] }
    return MeetingNotes.recipients(event.attendees)
  }

  private func handle(_ response: NotificationRouter.Response) async {
    guard let eventID = response.userInfo[Self.eventIDInfoKey],
      let start = response.userInfo[Self.eventStartInfoKey].flatMap(TimeInterval.init)
    else { return }
    requestedMeeting = (eventID, Date(timeIntervalSince1970: start), Date())
    // Tapping the banner only opens WakeOnCue; recording starts from the explicit action.
    guard response.actionIdentifier == Self.startAction else { return }
    await onStartRequested?()
  }

  private func scheduleReminders() async {
    let center = UNUserNotificationCenter.current()
    let pending = await center.pendingNotificationRequests()
    center.removePendingNotificationRequests(
      withIdentifiers: pending.map(\.identifier).filter {
        $0.hasPrefix(MeetingReminder.identifierPrefix)
      })
    guard linkEnabled, remindersEnabled, hasAccess else { return }
    let now = Date()
    let store = await loadedStore()
    let events = await Task.detached {
      Self.meetingEvents(
        in: store, from: now, to: now.addingTimeInterval(MeetingReminderPlanner.lookahead + 60 * 60))
    }.value
    let reminders = MeetingReminderPlanner.reminders(
      for: events, preferences: preferences, now: now)
    for reminder in reminders {
      try? await center.add(request(for: reminder))
    }
  }

  private func request(for reminder: MeetingReminder) -> UNNotificationRequest {
    let event = reminder.event
    let content = UNMutableNotificationContent()
    content.title =
      event.title.isEmpty ? AppLanguage.localized("Meeting") : event.title
    let time = event.start.formatted(date: .omitted, time: .shortened)
    content.body =
      reminder.fireDate >= event.start
      ? AppLanguage.localized("Starting now. Tap Start Recording to capture it.")
      : String(format: AppLanguage.localized("Starts at %@. Tap Start Recording to capture it."), time)
    content.sound = .default
    content.categoryIdentifier = Self.reminderCategory
    content.interruptionLevel = .timeSensitive
    content.userInfo = [
      Self.eventIDInfoKey: event.id,
      Self.eventStartInfoKey: String(event.start.timeIntervalSince1970),
    ]
    let components = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
    return UNNotificationRequest(
      identifier: reminder.identifier,
      content: content,
      trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    )
  }

  private func meetingEvents(from start: Date, to end: Date) -> [MeetingEvent] {
    guard hasAccess else { return [] }
    let store = store ?? EKEventStore()
    self.store = store
    return Self.meetingEvents(in: store, from: start, to: end)
  }

  private nonisolated static func meetingEvents(
    in store: EKEventStore, from start: Date, to end: Date
  ) -> [MeetingEvent] {
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    return store.events(matching: predicate).map(meetingEvent)
  }

  private nonisolated static func meetingEvent(_ event: EKEvent) -> MeetingEvent {
    var participants = event.attendees ?? []
    if let organizer = event.organizer { participants.append(organizer) }
    var attendees: [MeetingAttendee] = []
    for participant in participants {
      let email =
        participant.url.scheme?.lowercased() == "mailto"
        ? participant.url.absoluteString.dropFirst("mailto:".count).removingPercentEncoding : nil
      let attendee = MeetingAttendee(
        name: participant.name, email: email, isCurrentUser: participant.isCurrentUser)
      if let email, attendees.contains(where: { $0.email?.lowercased() == email.lowercased() }) {
        continue
      }
      attendees.append(attendee)
    }
    return MeetingEvent(
      id: event.eventIdentifier ?? event.calendarItemIdentifier,
      title: event.title ?? "",
      start: event.startDate,
      end: event.endDate,
      calendarID: event.calendar?.calendarIdentifier ?? "",
      isAllDay: event.isAllDay,
      isCanceled: event.status == .canceled,
      isDeclined: (event.attendees ?? []).contains {
        $0.isCurrentUser && $0.participantStatus == .declined
      },
      attendees: attendees,
      hasVideoLink: MeetingRules.containsVideoLink([
        event.url?.absoluteString, event.location, event.notes,
      ])
    )
  }

  /// Includes or excludes one calendar. Calendars that no longer exist are dropped.
  func setCalendar(_ id: String, included: Bool) {
    var ids =
      preferences.calendarIDs.isEmpty
      ? Set(calendars.map(\.calendarIdentifier)) : preferences.calendarIDs
    ids.formIntersection(calendars.map(\.calendarIdentifier))
    if included { ids.insert(id) } else { ids.remove(id) }
    // Every calendar selected is stored as "all", so new calendars count too.
    preferences.calendarIDs = ids.count == calendars.count ? [] : ids
  }

  func includes(_ calendar: EKCalendar) -> Bool {
    preferences.calendarIDs.isEmpty || preferences.calendarIDs.contains(calendar.calendarIdentifier)
  }
}
