import Foundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class MeetingCalendarTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func event(
    _ id: String = "evt",
    startsIn minutes: Double = 30,
    lasting duration: Double = 60,
    calendar: String = "work",
    attendees: [MeetingAttendee] = [],
    videoLink: Bool = false
  ) -> MeetingEvent {
    let start = now.addingTimeInterval(minutes * 60)
    return MeetingEvent(
      id: id, title: "Design review", start: start, end: start.addingTimeInterval(duration * 60),
      calendarID: calendar, attendees: attendees, hasVideoLink: videoLink)
  }

  private let me = MeetingAttendee(name: "Me", email: "me@example.com", isCurrentUser: true)
  private let ana = MeetingAttendee(name: "Ana", email: "ana@example.com")

  func testAllDayCanceledAndDeclinedEventsNeverQualify() {
    let preferences = MeetingPreferences()
    XCTAssertTrue(MeetingRules.qualifies(event(), preferences: preferences))
    var allDay = event()
    allDay.isAllDay = true
    var canceled = event()
    canceled.isCanceled = true
    var declined = event()
    declined.isDeclined = true
    for event in [allDay, canceled, declined] {
      XCTAssertFalse(MeetingRules.qualifies(event, preferences: preferences))
    }
  }

  func testSelectedCalendarsLimitMeetings() {
    let preferences = MeetingPreferences(calendarIDs: ["work"])
    XCTAssertTrue(MeetingRules.qualifies(event(calendar: "work"), preferences: preferences))
    XCTAssertFalse(MeetingRules.qualifies(event(calendar: "family"), preferences: preferences))
  }

  func testRequiringOthersOrVideoIgnoresSoloEvents() {
    let preferences = MeetingPreferences(requiresOthersOrVideoLink: true)
    XCTAssertFalse(MeetingRules.qualifies(event(attendees: [me]), preferences: preferences))
    XCTAssertTrue(MeetingRules.qualifies(event(attendees: [me, ana]), preferences: preferences))
    XCTAssertTrue(MeetingRules.qualifies(event(videoLink: true), preferences: preferences))
  }

  func testVideoLinksAreFoundInAnyField() {
    XCTAssertTrue(MeetingRules.containsVideoLink([nil, "https://Zoom.us/j/123"]))
    XCTAssertTrue(MeetingRules.containsVideoLink(["Room 4", "Join: https://meet.google.com/abc"]))
    XCTAssertFalse(MeetingRules.containsVideoLink(["Room 4", nil, "Bring slides"]))
  }

  func testRecordingLinksToTheMeetingInProgressOrAboutToStart() {
    let ongoing = event("ongoing", startsIn: -20, lasting: 60)
    let next = event("next", startsIn: 5, lasting: 30)
    let later = event("later", startsIn: 120)
    let preferences = MeetingPreferences()
    XCTAssertEqual(
      MeetingRules.meeting(at: now, in: [ongoing, next, later], preferences: preferences)?.id,
      "next")
    XCTAssertEqual(
      MeetingRules.meeting(at: now, in: [ongoing, later], preferences: preferences)?.id, "ongoing")
    XCTAssertNil(MeetingRules.meeting(at: now, in: [later], preferences: preferences))
    XCTAssertNil(
      MeetingRules.meeting(
        at: now, in: [event("past", startsIn: -90, lasting: 60)], preferences: preferences))
  }

  func testRemindersFireBeforeStartInOrderWithinTheLimit() {
    let events = (0..<50).map { event("evt\($0)", startsIn: Double(50 - $0) * 60) }
    let reminders = MeetingReminderPlanner.reminders(
      for: events, preferences: MeetingPreferences(reminderLeadMinutes: 5), now: now)
    XCTAssertEqual(reminders.count, MeetingReminderPlanner.maximumReminders)
    XCTAssertEqual(reminders.first?.event.id, "evt49")
    XCTAssertEqual(reminders.first?.fireDate, now.addingTimeInterval(60 * 60 - 5 * 60))
    XCTAssertEqual(reminders.map(\.fireDate), reminders.map(\.fireDate).sorted())
    XCTAssertLessThanOrEqual(MeetingReminderPlanner.maximumReminders, 64)
  }

  func testRemindersSkipPastDuplicateAndDistantOccurrences() {
    let soon = event("soon", startsIn: 3)
    let duplicate = event("soon", startsIn: 3)
    let nextWeek = event("next-week", startsIn: 8 * 24 * 60)
    let reminders = MeetingReminderPlanner.reminders(
      for: [soon, duplicate, nextWeek, event("started", startsIn: -10)],
      preferences: MeetingPreferences(reminderLeadMinutes: 1), now: now)
    XCTAssertEqual(reminders.map(\.event.id), ["soon"])
    XCTAssertTrue(reminders[0].identifier.hasPrefix(MeetingReminder.identifierPrefix))

    let recurring = [event("weekly", startsIn: 60), event("weekly", startsIn: 60 * 24)]
    XCTAssertEqual(
      MeetingReminderPlanner.reminders(for: recurring, preferences: .init(), now: now).count, 2)
  }

  func testMeetingLinkRoundTripsThroughMetadataAndSetsTheTitle() throws {
    let source = event(attendees: [me, ana, MeetingAttendee(name: " ", email: "bo@example.com")])
    let metadata = MeetingLink(event: source).metadata
    XCTAssertEqual(metadata[RecordingRecord.titleMetadataKey], "Design review")
    let link = try XCTUnwrap(MeetingLink(metadata: metadata))
    XCTAssertEqual(link.eventID, "evt")
    XCTAssertEqual(link.start, source.start)
    XCTAssertEqual(link.end, source.end)
    XCTAssertEqual(link.attendeeNames, ["Ana", "bo@example.com"])
    XCTAssertNil(MeetingLink(metadata: ["title": "Standalone"]))
  }

  func testNotesIncludeSummarySectionsAndRecipientsExcludeTheUser() {
    let summary = RecordingSummary(
      title: "Review", overview: "We agreed on the plan.", keyPoints: ["Ship in May"],
      actionItems: ["Ana sends the deck"], generatedAt: now)
    let text = MeetingNotes.text(
      title: "Design review", date: now, summary: summary, language: .english,
      timeZone: TimeZone(identifier: "UTC")!)
    let lines = text.components(separatedBy: "\n")
    XCTAssertEqual(lines.first, "Design review")
    XCTAssertTrue(lines[1].contains("2027"))
    XCTAssertTrue(text.contains("Overview\nWe agreed on the plan."))
    XCTAssertTrue(text.contains("Key points\n- Ship in May"))
    XCTAssertTrue(text.contains("Follow-ups\n- Ana sends the deck"))

    let bare = MeetingNotes.text(title: "Sync", date: now, summary: nil, language: .english)
    XCTAssertFalse(bare.contains("Overview"))

    XCTAssertEqual(
      MeetingNotes.recipients([
        me, ana, MeetingAttendee(name: "Ana again", email: "ANA@example.com"),
        MeetingAttendee(name: "Room", email: nil),
      ]),
      ["ana@example.com"])
  }
}
