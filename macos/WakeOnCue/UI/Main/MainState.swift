import Foundation
import Observation

/// What the main window is showing. Shared with the menu bar and keyboard commands.
@Observable
final class MainState {
  enum Page: Equatable {
    case day
    case search
    case deleted
  }

  var page: Page = .day
  var day = Calendar.current.startOfDay(for: .now)
  var expandedHours: Set<Date> = []
  var fullHours: Set<Date> = []
  /// The sentence a citation or the player points at.
  var highlighted: Int64?
  var meetingID: Int64?
  var draftingMinutes = false
  /// The sentence whose speaker the user is naming ("这是谁…").
  var namingSentence: Sentence?
  var showTracks = false
  var showLegend = false
  var searchText = ""
  var submittedSearch = ""
  /// Bumped to ask the day page to scroll to `scrollTarget`.
  var scrollRequest = 0
  var scrollTarget: String?
  var focusSearch = 0
  var settingsSection: SettingsView.Section = .recording

  var isToday: Bool { Calendar.current.isDateInToday(day) }

  func show(day: Date) {
    self.day = Calendar.current.startOfDay(for: day)
    page = .day
    meetingID = nil
    draftingMinutes = false
    highlighted = nil
  }

  func moveDay(by days: Int) {
    let target = Calendar.current.date(byAdding: .day, value: days, to: day)!
    guard target <= .now else { return }
    show(day: target)
  }

  func scroll(to anchor: String) {
    scrollTarget = anchor
    scrollRequest += 1
  }

  static func hourAnchor(_ hour: Date) -> String { "hour-\(Int(hour.timeIntervalSince1970))" }
  static func sentenceAnchor(_ id: Int64) -> String { "s-\(id)" }
}
