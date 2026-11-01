import XCTest

final class RecordingStartupUITests: XCTestCase {
  @MainActor
  func testRecordingRowOpensDetailsAndTranscript() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_EXPERIENCE_FIXTURES"] = "1"
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launch()

    let library = app.buttons["all-recordings"]
    XCTAssertTrue(library.waitForExistence(timeout: 25))
    library.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("Orchid")
    let detailLink = app.buttons["library-recording-experience-12"]
    XCTAssertTrue(detailLink.waitForExistence(timeout: 20), "No recording detail link is visible")
    detailLink.tap()

    XCTAssertTrue(app.navigationBars["Recording details"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Transcript"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.sliders["recording-playback-slider"].waitForExistence(timeout: 5),
      "The recording detail did not show a seekable playback timeline"
    )
    let persistedSegment = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'recording-transcript-segment-'")
    ).firstMatch
    XCTAssertTrue(
      persistedSegment.waitForExistence(timeout: 10),
      "The completed recording detail did not show its persisted transcript"
    )
  }

  @MainActor
  func testSimplifiedChineseLocalization() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "zh-Hans"
    app.launch()

    XCTAssertTrue(app.staticTexts["不错过每次会议"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["最近的录音"].exists)

    let settings = app.buttons["设置"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10), "Chinese settings control is missing")
    settings.tap()

    XCTAssertTrue(app.staticTexts["语言"].waitForExistence(timeout: 5))
    let appLanguagePicker = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH '应用语言'")
    ).firstMatch
    XCTAssertTrue(appLanguagePicker.exists)
    XCTAssertTrue(app.navigationBars["设置"].exists)

    let transcriptionSection = app.staticTexts["录音后转写"]
    for _ in 0..<4 where !transcriptionSection.exists {
      app.swipeUp()
    }
    XCTAssertTrue(transcriptionSection.exists, "Transcription settings are not fully localized")
  }

  @MainActor
  func testActionButtonSetupGuide() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launch()

    let settings = app.buttons["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings control is missing")
    settings.tap()

    XCTAssertTrue(
      app.staticTexts["Language"].waitForExistence(timeout: 5),
      "Language selector should be the first settings section"
    )

    let setup = app.buttons["Set Up Action Button, Start recording with one press"]
    for _ in 0..<6 where !setup.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(
      setup.isHittable, "Action Button setup entry is missing from the bottom of Settings")
    setup.tap()

    XCTAssertTrue(
      app.navigationBars["Action Button"].waitForExistence(timeout: 5),
      "Action Button setup guide did not open"
    )
    XCTAssertTrue(
      app.staticTexts["Select Start Recording under WakeOnCue"].exists,
      "The guide does not identify the shortcut to select"
    )
    let shortcutsSection = app.staticTexts["WakeOnCue shortcuts"]
    for _ in 0..<4 where !shortcutsSection.exists {
      app.swipeUp()
    }
    XCTAssertTrue(shortcutsSection.exists, "The WakeOnCue Shortcuts section is missing")
  }

  @MainActor
  func testStartAndFinishRecording() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launchEnvironment["WAKEONCUE_EXPERIENCE_FIXTURES"] = "1"
    app.launchEnvironment["WAKEONCUE_TEST_AUDIO_FIXTURE_FILENAME"] = "experience-input.m4a"

    addUIInterruptionMonitor(withDescription: "Recording permissions") { alert in
      let allowButton = alert.buttons["Allow"]
      if allowButton.exists {
        allowButton.tap()
        return true
      }
      let allowWhileUsingButton = alert.buttons["Allow While Using App"]
      if allowWhileUsingButton.exists {
        allowWhileUsingButton.tap()
        return true
      }
      return false
    }

    app.launch()

    let start = app.buttons["start-recording"]
    XCTAssertTrue(start.waitForExistence(timeout: 10), "Start recording control is missing")
    start.tap()
    app.tap()

    let recordingStatus = app.staticTexts["Recording status: Recording"]
    if !recordingStatus.waitForExistence(timeout: 5) {
      let alert = app.alerts.firstMatch
      if alert.exists {
        XCTFail(
          "Recording startup alert: \(alert.label) | \(alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))"
        )
      } else {
        XCTFail("Recording did not enter the Recording state. UI: \(app.debugDescription)")
      }
    }

    sleep(3)
    let finish = app.buttons["finish-recording"]
    XCTAssertTrue(finish.waitForExistence(timeout: 3), "Finish control is missing")
    finish.tap()
  }
}
