import XCTest

/// Uses isolated generated audio/text. Does not validate microphone, camera, ASR or S3.
final class ProductExperienceUITests: XCTestCase {
  @MainActor
  private func launch(language: String = "en", largeText: Bool = false, offlineBackup: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_EXPERIENCE_FIXTURES"] = "1"
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = language
    app.launchEnvironment["WAKEONCUE_TEST_AUDIO_FIXTURE_FILENAME"] = "experience-input.m4a"
    if offlineBackup { app.launchEnvironment["WAKEONCUE_EXPERIENCE_OFFLINE_BACKUP"] = "1" }
    if largeText {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    }
    app.launch()
    return app
  }

  @MainActor
  func testCompleteLibrarySearchFindsOlderTranscript() throws {
    let app = launch()
    let library = app.buttons["all-recordings"]
    XCTAssertTrue(library.waitForExistence(timeout: 25))
    library.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("Orchid")
    let result = app.buttons["library-recording-experience-12"]
    XCTAssertTrue(result.waitForExistence(timeout: 15), "Full-library search must include old local transcripts")
    result.tap()
    XCTAssertTrue(app.sliders["recording-playback-slider"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testIdleDoesNotClaimAnActiveRecordingWasSaved() throws {
    let app = launch()
    XCTAssertTrue(app.buttons["start-recording"].waitForExistence(timeout: 25))
    XCTAssertTrue(app.staticTexts["Recordings save on this iPhone"].exists)
    XCTAssertFalse(app.otherElements["capture-feedback"].exists)
  }

  @MainActor
  func testRenamePersistsAndSearchFindsNewTitleAfterRelaunch() throws {
    let app = launch()
    let library = app.buttons["all-recordings"]
    XCTAssertTrue(library.waitForExistence(timeout: 25))
    library.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("Orchid")
    let result = app.buttons["library-recording-experience-12"]
    XCTAssertTrue(result.waitForExistence(timeout: 15))
    result.tap()
    let edit = app.buttons["edit-recording-title"]
    XCTAssertTrue(edit.waitForExistence(timeout: 10))
    edit.tap()
    let title = app.textFields["recording-title-field"]
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    title.tap()
    if let value = title.value as? String, value != "Recording title", !value.isEmpty {
      title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }
    title.typeText("Persistent Orchid notes")
    app.buttons["save-recording-title"].tap()
    XCTAssertTrue(app.staticTexts["Persistent Orchid notes"].waitForExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(library.waitForExistence(timeout: 25))
    library.tap()
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("Persistent Orchid notes")
    XCTAssertTrue(result.waitForExistence(timeout: 15))
  }

  @MainActor
  func testReadingTranscriptDoesNotSeekPausedAudio() throws {
    let app = launch()
    let library = app.buttons["all-recordings"]
    XCTAssertTrue(library.waitForExistence(timeout: 25))
    library.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("Orchid")
    let result = app.buttons["library-recording-experience-12"]
    XCTAssertTrue(result.waitForExistence(timeout: 15))
    result.tap()
    let play = app.buttons["Play recording"]
    XCTAssertTrue(play.waitForExistence(timeout: 10))
    play.tap()
    let pause = app.buttons["Pause recording"]
    XCTAssertTrue(pause.waitForExistence(timeout: 10))
    pause.tap()
    XCTAssertTrue(play.waitForExistence(timeout: 10))
    let slider = app.sliders["recording-playback-slider"]
    let initialPosition = slider.value as? String
    let transcript = app.scrollViews["transcript-scroll-view"]
    transcript.swipeUp()
    XCTAssertEqual(slider.value as? String, initialPosition, "Reading must not change paused playback")
    let follow = app.buttons["transcript-follow-playback"]
    XCTAssertTrue(follow.waitForExistence(timeout: 5))
    XCTAssertTrue(follow.isHittable)
    follow.tap()
    XCTAssertEqual(slider.value as? String, initialPosition, "Return to playback only changes scroll position")
  }

  @MainActor
  func testRecordingCanFinishAndStartAnotherLocally() throws {
    let app = launch()
    addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
      if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
      if alert.buttons["OK"].exists { alert.buttons["OK"].tap(); return true }
      return false
    }
    let start = app.buttons["start-recording"]
    XCTAssertTrue(start.waitForExistence(timeout: 25))
    start.tap()
    app.tap()
    let finish = app.buttons["finish-recording"]
    XCTAssertTrue(finish.waitForExistence(timeout: 15))
    XCTAssertTrue(app.descendants(matching: .any)["capture-input-level"].waitForExistence(timeout: 10))
    finish.tap()
    XCTAssertTrue(start.waitForExistence(timeout: 20))
    XCTAssertTrue(app.descendants(matching: .any)["recording-completion-card"].exists)
    start.tap()
    XCTAssertTrue(finish.waitForExistence(timeout: 15))
    finish.tap()
    XCTAssertTrue(start.waitForExistence(timeout: 20))
  }

  @MainActor
  func testChineseLargeTextKeepsPrimaryActionAccessible() throws {
    let app = launch(language: "zh-Hans", largeText: true)
    let start = app.buttons["start-recording"]
    XCTAssertTrue(start.waitForExistence(timeout: 25))
    for _ in 0..<5 where !start.isHittable { app.swipeUp() }
    XCTAssertTrue(start.isHittable)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Chinese accessibility text home"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  func testUnavailableCloudDoesNotBlockNextRecordingOrRelaunch() throws {
    let app = launch(offlineBackup: true)
    addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
      if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
      if alert.buttons["OK"].exists { alert.buttons["OK"].tap(); return true }
      return false
    }
    let start = app.buttons["start-recording"]
    XCTAssertTrue(start.waitForExistence(timeout: 25))
    start.tap()
    app.tap()
    let finish = app.buttons["finish-recording"]
    XCTAssertTrue(finish.waitForExistence(timeout: 15))
    finish.tap()
    XCTAssertTrue(start.waitForExistence(timeout: 20), "Unavailable cloud must not hold the recording control")
    start.tap()
    XCTAssertTrue(finish.waitForExistence(timeout: 15))
    finish.tap()
    XCTAssertTrue(start.waitForExistence(timeout: 20))
    app.terminate()
    app.launch()
    XCTAssertTrue(start.waitForExistence(timeout: 25), "Relaunch must not promote background backups to active capture")
  }
}
