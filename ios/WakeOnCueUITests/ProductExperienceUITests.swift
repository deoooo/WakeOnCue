import XCTest

/// Uses isolated generated audio/text. Does not validate microphone, camera, ASR or S3.
final class ProductExperienceUITests: XCTestCase {
  /// Simulators have no on-device transcription, so a local service keeps Retranscribe enabled.
  /// Nothing connects to it, because these tests stop at the confirmation.
  private static let localTranscriptionService = [
    "-ai.speech.engine", "openai-compatible",
    "-ai.speech.base-url", "http://127.0.0.1:9/v1",
    "-ai.speech.model", "test",
  ]

  @MainActor
  private func launch(
    language: String = "en", largeText: Bool = false, arguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += arguments
    app.launchEnvironment["WAKEONCUE_EXPERIENCE_FIXTURES"] = "1"
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = language
    app.launchEnvironment["WAKEONCUE_TEST_AUDIO_FIXTURE_FILENAME"] = "experience-input.m4a"
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
  func testUnreadableTranscriptOffersRetryInsteadOfTranscribing() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_EXPERIENCE_FIXTURES"] = "1"
    app.launchEnvironment["WAKEONCUE_EXPERIENCE_UNREADABLE_TRANSCRIPT"] = "1"
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launchArguments += Self.localTranscriptionService
    app.launch()

    let row = app.buttons["recording-details-experience-01"]
    XCTAssertTrue(row.waitForExistence(timeout: 25))
    for _ in 0..<4 where !row.isHittable { app.swipeUp() }
    row.tap()

    let retry = app.buttons["Try again"]
    XCTAssertTrue(retry.waitForExistence(timeout: 10), "A read failure must offer a retry")
    XCTAssertFalse(
      app.buttons["Transcribe with your service"].exists, "A read failure must not offer to transcribe")
    retry.tap()
    XCTAssertTrue(retry.waitForExistence(timeout: 10), "Retry reports the same failure again")

    assertRetranscribeAsksFirst(app)
  }

  @MainActor
  func testRetranscribingLabeledTranscriptAsksFirst() throws {
    let app = launch(arguments: Self.localTranscriptionService)
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
    let segment = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'recording-transcript-segment-'")
    ).firstMatch
    XCTAssertTrue(segment.waitForExistence(timeout: 10))

    assertRetranscribeAsksFirst(app)
    XCTAssertTrue(segment.exists, "Cancelling keeps the transcript")
  }

  @MainActor
  private func assertRetranscribeAsksFirst(_ app: XCUIApplication) {
    let more = app.buttons["more-recording-actions"]
    XCTAssertTrue(more.waitForExistence(timeout: 5))
    more.tap()
    let retranscribe = app.buttons["retranscribe-recording"]
    XCTAssertTrue(retranscribe.waitForExistence(timeout: 5))
    XCTAssertTrue(retranscribe.isEnabled)
    retranscribe.tap()
    let replace = app.buttons["Replace transcript"]
    XCTAssertTrue(replace.waitForExistence(timeout: 5), "Replacing must ask for confirmation")
    XCTAssertFalse(app.descendants(matching: .any)["retranscription-progress"].exists)
    let cancel = app.buttons["Cancel"]
    if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.87)).tap() }
    let dismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: replace)
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    XCTAssertFalse(app.descendants(matching: .any)["retranscription-progress"].exists)
  }

  @MainActor
  func testDeletedRecordingCanBeRecoveredFromRecentlyDeleted() throws {
    let app = launch()
    let library = app.buttons["all-recordings"]
    XCTAssertTrue(library.waitForExistence(timeout: 25))
    library.tap()
    // The newest row stays clear of the search bar however many recordings the simulator holds.
    let newest = app.buttons
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-recording-")).firstMatch
    XCTAssertTrue(newest.waitForExistence(timeout: 15))
    let recordingID = String(newest.identifier.dropFirst("library-recording-".count))
    let row = app.buttons["library-recording-\(recordingID)"]
    row.swipeLeft()
    let delete = app.buttons["delete-recording-\(recordingID)"]
    XCTAssertTrue(delete.waitForExistence(timeout: 5))
    delete.tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 10))

    app.buttons["library-more"].tap()
    let recentlyDeleted = app.buttons["recently-deleted"]
    XCTAssertTrue(recentlyDeleted.waitForExistence(timeout: 5))
    recentlyDeleted.tap()
    let deleted = app.buttons["deleted-recording-\(recordingID)"]
    XCTAssertTrue(deleted.waitForExistence(timeout: 10))
    deleted.tap()
    let recover = app.buttons["recover-recording"].firstMatch
    XCTAssertTrue(recover.waitForExistence(timeout: 5))
    recover.tap()
    XCTAssertTrue(deleted.waitForNonExistence(timeout: 10))

    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(row.waitForExistence(timeout: 10))
  }

  @MainActor
  func testDetailExplainsWhyNoSummaryIsAvailableAndOpensSettings() throws {
    let app = launch()
    let library = app.buttons["all-recordings"]
    XCTAssertTrue(library.waitForExistence(timeout: 25))
    library.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("Meeting 2,")
    let row = app.buttons["library-recording-experience-02"]
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    row.tap()
    let setUp = app.buttons["set-up-summaries"]
    XCTAssertTrue(setUp.waitForExistence(timeout: 10))
    setUp.tap()
    XCTAssertTrue(app.buttons["settings.save"].waitForExistence(timeout: 10))
  }
}
