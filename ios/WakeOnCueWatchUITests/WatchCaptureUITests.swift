import XCTest

/// End-to-end checks that need a paired iPhone simulator running WakeOnCue. They are skipped
/// unless `WAKEONCUE_WATCH_E2E` is set (pass `TEST_RUNNER_WAKEONCUE_WATCH_E2E=1` to xcodebuild).
final class WatchCaptureUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  override func setUpWithError() throws {
    continueAfterFailure = false
    try XCTSkipUnless(environment["WAKEONCUE_WATCH_E2E"] == "1", "Needs a paired iPhone")
  }

  /// Drives the iPhone from the Watch: start (when idle), "Save that", tag, then finish.
  @MainActor
  func testSaveThatMarksRunningPhoneRecording() throws {
    let app = XCUIApplication()
    app.launch()
    let status = app.descendants(matching: .any)["watch-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    let reachable = NSPredicate(format: "value == 'idle' OR value == 'recording'")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: reachable, object: status)], timeout: 60),
      .completed,
      "iPhone was not reachable"
    )
    if (status.value as? String) == "idle" {
      app.buttons["watch-toggle-recording"].tap()
    }
    XCTAssertTrue(
      waitForValue(of: status, "recording", timeout: 30), "iPhone recording was not visible")
    sleep(5)

    app.buttons["watch-capture-recent"].tap()
    XCTAssertTrue(app.staticTexts["watch-saved-on-phone"].waitForExistence(timeout: 20))
    app.buttons["watch-tag-todo"].tap()
    sleep(2)
    app.buttons["watch-capture-done"].tap()
    XCTAssertTrue(app.buttons["watch-capture-recent"].waitForExistence(timeout: 5))
    if let flag = environment["WAKEONCUE_WATCH_E2E_FLAG"] {
      FileManager.default.createFile(atPath: flag, contents: Data("done".utf8))
    }
    if environment["WAKEONCUE_WATCH_E2E_FINISH"] == "1" {
      let finish = app.buttons["watch-finish-recording"]
      finish.scrollToVisible(in: app)
      finish.tap()
      XCTAssertTrue(waitForValue(of: status, "idle", timeout: 30), "iPhone did not finish")
    }
  }

  /// With the iPhone app in the background, "Record" falls back to recording on the Watch.
  @MainActor
  func testWatchRecordsWhenPhoneCannotStart() throws {
    let app = XCUIApplication()
    app.launch()
    let status = app.descendants(matching: .any)["watch-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    sleep(3)
    app.buttons["watch-toggle-recording"].tap()
    XCTAssertTrue(
      waitForValue(of: status, "watch-recording", timeout: 30),
      "Watch did not start recording; status=\(String(describing: status.value))")

    sleep(65)
    app.buttons["watch-capture-recent"].tap()
    XCTAssertTrue(app.staticTexts["watch-saved-on-watch-recording"].waitForExistence(timeout: 10))
    app.buttons["watch-tag-idea"].tap()
    app.buttons["watch-capture-done"].tap()
    XCTAssertTrue(app.buttons["watch-capture-recent"].waitForExistence(timeout: 5))
    sleep(5)
    app.buttons["watch-toggle-recording"].tap()
    let stopped = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != 'watch-recording'"), object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 10), .completed, "Recording did not stop")
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
