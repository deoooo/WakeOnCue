import XCTest

/// iPhone half of the Watch end-to-end check: keeps a recording running until the Watch test
/// drops its flag file. Skipped unless `WAKEONCUE_WATCH_E2E` is set.
final class WatchCompanionUITests: XCTestCase {
  @MainActor
  func testHoldsRecordingWhileWatchMarksIt() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["WAKEONCUE_WATCH_E2E"] == "1", "Needs a paired Watch")
    let flag = try XCTUnwrap(environment["WAKEONCUE_WATCH_E2E_FLAG"])

    // Attach to an already running app: relaunching it makes the simulator's WatchConnectivity
    // hold messages for tens of seconds while the new session activates.
    let app = XCUIApplication()
    app.activate()
    let saveLocally = app.buttons["Save to this iPhone"]
    let finish = app.buttons["finish-recording"]
    if finish.waitForExistence(timeout: 2) {
      finish.tap()
      if saveLocally.waitForExistence(timeout: 5) { saveLocally.tap() }
    }
    app.openTab("Record", timeout: 5)
    let start = app.buttons["start-recording"]
    XCTAssertTrue(start.waitForExistence(timeout: 15))
    start.tap()
    XCTAssertTrue(finish.waitForExistence(timeout: 10))

    let deadline = Date().addingTimeInterval(150)
    while !FileManager.default.fileExists(atPath: flag), Date() < deadline { sleep(1) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: flag), "The Watch never marked the recording")

    finish.tap()
    if saveLocally.waitForExistence(timeout: 5) { saveLocally.tap() }
  }
}
