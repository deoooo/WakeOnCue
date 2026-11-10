import XCTest

extension XCUIApplication {
  /// Taps a tab by its title, e.g. "Search" or "录音". While recording, the Record tab is
  /// titled "Recording".
  @MainActor
  func openTab(_ title: String, timeout: TimeInterval = 25) {
    if title == "Record", tabBars.buttons["Recording"].exists {
      tabBars.buttons["Recording"].tap()
      return
    }
    let tab = tabBars.buttons[title]
    if tab.waitForExistence(timeout: timeout) {
      tab.tap()
      return
    }
    let button = buttons[title].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5), "The \(title) tab is missing")
    button.tap()
  }

  /// A recording opens on its summary; this switches to the transcript.
  @MainActor
  func openTranscriptPage() {
    let transcript = buttons["Transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 10), "The Transcript page is missing")
    transcript.tap()
  }
}
