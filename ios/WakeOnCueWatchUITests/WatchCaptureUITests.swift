import XCTest

/// End-to-end checks of Watch recording. They are skipped unless `WAKEONCUE_WATCH_E2E` is set
/// (pass `TEST_RUNNER_WAKEONCUE_WATCH_E2E=1` to xcodebuild); they need microphone access.
final class WatchCaptureUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  override func setUpWithError() throws {
    continueAfterFailure = false
    try XCTSkipUnless(environment["WAKEONCUE_WATCH_E2E"] == "1", "Needs microphone access")
  }

  /// Record for a little over one segment, stop, and find the recording in the list.
  @MainActor
  func testWatchRecordingShowsInRecordings() throws {
    let app = XCUIApplication()
    app.launch()
    let status = app.descendants(matching: .any)["watch-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    app.buttons["watch-toggle-recording"].tap()
    XCTAssertTrue(
      waitForValue(of: status, "watch-recording", timeout: 30),
      "Watch did not start recording; status=\(String(describing: status.value))")

    sleep(65)
    app.buttons["watch-toggle-recording"].tap()
    XCTAssertTrue(waitForValue(of: status, "idle", timeout: 10), "Recording did not stop")

    let recordings = app.buttons["watch-recordings"]
    recordings.scrollToVisible(in: app)
    recordings.tap()
    XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
  }

  private func waitForValue(of element: XCUIElement, _ value: String, timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "value == %@", value)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}

extension XCUIElement {
  fileprivate func scrollToVisible(in app: XCUIApplication) {
    var attempts = 0
    while !isHittable && attempts < 6 {
      app.swipeUp()
      attempts += 1
    }
  }
}
