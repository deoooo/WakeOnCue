import EventKit
import MessageUI
import SwiftUI
import WakeOnCueCore

/// Calendar settings: link recordings to meetings and remind the user before they start.
struct CalendarSettingsSection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var meetings = model.meetings
    Section {
      Toggle(isOn: linkBinding) {
        Label("Link recordings to meetings", systemImage: "calendar")
      }
      .accessibilityIdentifier("settings.calendar.link")
      if meetings.linkEnabled {
        if meetings.hasAccess {
          Toggle(isOn: remindersBinding) {
            Label("Remind before meetings", systemImage: "bell.badge")
          }
          .accessibilityIdentifier("settings.calendar.reminders")
          if meetings.remindersEnabled {
            Picker("Remind", selection: $meetings.preferences.reminderLeadMinutes) {
              ForEach(CalendarAutomation.leadMinuteOptions, id: \.self) { minutes in
                Text(leadTitle(minutes)).tag(minutes)
              }
            }
          }
          NavigationLink {
            MeetingCalendarsView()
          } label: {
            LabeledContent {
              Text(calendarsSummary)
            } label: {
              Label("Calendars", systemImage: "calendar.badge.checkmark")
            }
          }
          .accessibilityIdentifier("settings.calendar.calendars")
          Toggle(isOn: $meetings.preferences.requiresOthersOrVideoLink) {
            Label("Only meetings with others or a video link", systemImage: "person.2")
          }
          .accessibilityIdentifier("settings.calendar.requires-others")
        } else if meetings.authorization != .notDetermined {
          Label(
            "Allow full calendar access in iPhone Settings to link meetings.",
            systemImage: "calendar.badge.exclamationmark"
          )
          .foregroundStyle(.orange)
          Button("Open iPhone Settings") { model.openSystemSettings() }
        }
      }
    } header: {
      Text("Calendar")
    } footer: {
      Text(
        "Off by default. Recordings made during a meeting take its title and attendees. Reminders arrive when a meeting starts; tap Start Recording to begin. Calendar data stays on this iPhone."
      )
    }
  }

  private var linkBinding: Binding<Bool> {
    Binding(
      get: { model.meetings.linkEnabled },
      set: { enabled in
        model.meetings.linkEnabled = enabled
        if enabled { Task { await model.meetings.requestAccess() } }
      }
    )
  }

  private var remindersBinding: Binding<Bool> {
    Binding(
      get: { model.meetings.remindersEnabled },
      set: { enabled in
        model.meetings.remindersEnabled = enabled
        if enabled { Task { await model.meetings.requestAccess() } }
      }
    )
  }

  private var calendarsSummary: String {
    let meetings = model.meetings
    if meetings.preferences.calendarIDs.isEmpty { return AppLanguage.localized("All") }
    return "\(meetings.calendars.filter(meetings.includes).count)"
  }

  private func leadTitle(_ minutes: Int) -> String {
    minutes == 0
      ? AppLanguage.localized("When it starts")
      : String(format: AppLanguage.localized("%d min before"), minutes)
  }
}

/// Chooses which calendars hold meetings worth recording.
struct MeetingCalendarsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let meetings = model.meetings
    let included = meetings.calendars.filter(meetings.includes)
    List {
      ForEach(groupedSources(meetings.calendars), id: \.0) { source, calendars in
        Section(source) {
          ForEach(calendars, id: \.calendarIdentifier) { calendar in
            Toggle(
              isOn: Binding(
                get: { meetings.includes(calendar) },
                set: { meetings.setCalendar(calendar.calendarIdentifier, included: $0) }
              )
            ) {
              Label {
                Text(calendar.title)
              } icon: {
                Image(systemName: "circle.fill")
                  .foregroundStyle(Color(cgColor: calendar.cgColor))
              }
            }
            // At least one calendar stays selected; an empty choice would mean every calendar.
            .disabled(included.count == 1 && meetings.includes(calendar))
          }
        }
      }
    }
    .navigationTitle("Calendars")
  }

  private func groupedSources(_ calendars: [EKCalendar]) -> [(String, [EKCalendar])] {
    Dictionary(grouping: calendars) { $0.source?.title ?? "" }
      .sorted { $0.key < $1.key }
  }
}

/// The meeting a recording was linked to, shown on its detail page.
struct LinkedMeetingSection: View {
  let link: MeetingLink

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Meeting", systemImage: "calendar")
        .font(.headline)
      if !link.title.isEmpty {
        Text(link.title).font(.subheadline.weight(.semibold))
      }
      Text(
        verbatim: "\(link.start.formatted(date: .abbreviated, time: .shortened)) – \(link.end.formatted(date: .omitted, time: .shortened))"
      )
      if !link.attendeeNames.isEmpty {
        Text(link.attendeeNames.joined(separator: ", "))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .font(.subheadline)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("recording-linked-meeting")
  }
}

/// What the user reviews before sending meeting notes.
struct MeetingNotesDraft: Identifiable {
  let id = UUID()
  var subject: String
  var body: String
  var recipients: [String]
}

/// Mail when this iPhone can send it, otherwise the share sheet. Nothing is sent until the
/// user sends it there.
struct MeetingNotesComposer: UIViewControllerRepresentable {
  let draft: MeetingNotesDraft
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIViewController {
    guard MFMailComposeViewController.canSendMail() else {
      return UIActivityViewController(activityItems: [draft.body], applicationActivities: nil)
    }
    let mail = MFMailComposeViewController()
    mail.mailComposeDelegate = context.coordinator
    mail.setToRecipients(draft.recipients)
    mail.setSubject(draft.subject)
    mail.setMessageBody(draft.body, isHTML: false)
    return mail
  }

  func updateUIViewController(_ controller: UIViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
    let dismiss: DismissAction

    init(dismiss: DismissAction) { self.dismiss = dismiss }

    func mailComposeController(
      _ controller: MFMailComposeViewController,
      didFinishWith result: MFMailComposeResult,
      error: Error?
    ) {
      dismiss()
    }
  }
}
