import XCTest

final class RecordingStartupUITests: XCTestCase {
  @MainActor
  func testRealtimeTranscriptAppearsUsingPersistedGateway() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launchEnvironment["WAKEONCUE_TEST_AUDIO_FIXTURE_FILENAME"] =
      "ui-test-four-speakers.wav"
    app.launch()
    app.tap()

    let saveLocally = app.buttons["Save to this iPhone"]
    let existingFinish = app.buttons["finish-recording"]
    if existingFinish.waitForExistence(timeout: 2) {
      existingFinish.tap()
      if saveLocally.waitForExistence(timeout: 5) { saveLocally.tap() }
    }

    let start = app.buttons["start-recording"]
    XCTAssertTrue(start.waitForExistence(timeout: 15), "Start recording control is missing")
    start.tap()
    app.tap()

    XCTAssertTrue(app.staticTexts["Live transcript"].waitForExistence(timeout: 15))
    let segment = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'live-transcript-segment-'")
    ).firstMatch
    XCTAssertTrue(
      segment.waitForExistence(timeout: 75),
      "No realtime transcript text appeared from the silent audio fixture"
    )
    XCTAssertNotNil(
      segment.label.range(of: #"\p{Han}"#, options: .regularExpression),
      "The Chinese fixture did not produce Chinese transcript text: \(segment.label)"
    )

    let finish = app.buttons["finish-recording"]
    XCTAssertTrue(finish.waitForExistence(timeout: 5))
    finish.tap()
    if saveLocally.waitForExistence(timeout: 5) { saveLocally.tap() }
  }

  @MainActor
  func testRecordingRowOpensDetailsAndTranscript() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launch()

    let detailLink = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'recording-details-'")
    ).firstMatch
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
  func testCompletedRecordingCanBeRetranscribed() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launch()

    let detailLink = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'recording-details-'")
    ).firstMatch
    XCTAssertTrue(detailLink.waitForExistence(timeout: 20), "No completed recording is visible")
    detailLink.tap()

    let retranscribe = app.buttons["retranscribe-recording"]
    for _ in 0..<6 where !retranscribe.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(retranscribe.isHittable, "Retranscription control is missing")
    retranscribe.tap()

    let progress = app.descendants(matching: .any)["retranscription-progress"]
    XCTAssertTrue(progress.waitForExistence(timeout: 10), "Retranscription did not start")
    let completed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: progress)
    XCTAssertEqual(
      XCTWaiter.wait(for: [completed], timeout: 120), .completed,
      "Retranscription did not complete"
    )

    let persistedSegment = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'recording-transcript-segment-'")
    ).firstMatch
    XCTAssertTrue(
      persistedSegment.waitForExistence(timeout: 10),
      "Retranscription completed without a readable transcript"
    )
  }

  @MainActor
  func testPersistedRemoteRealtimeConfigurationIsVisible() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launch()

    let settings = app.buttons["Recording storage settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings control is missing")
    settings.tap()
    let connected = app.staticTexts["Realtime Gateway connected"]
    for _ in 0..<4 where !connected.exists {
      app.swipeUp()
    }
    XCTAssertTrue(
      connected.waitForExistence(timeout: 10),
      "Persisted realtime configuration is not visible after a normal launch"
    )
  }

  @MainActor
  func testPersistValidatedRemoteRealtimeConfiguration() throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let gatewayURL = environment["WAKEONCUE_TEST_REALTIME_GATEWAY_URL"],
      let gatewayToken = environment["WAKEONCUE_TEST_REALTIME_GATEWAY_TOKEN"],
      !gatewayURL.isEmpty, !gatewayToken.isEmpty
    else {
      throw XCTSkip("Remote realtime configuration was not supplied")
    }

    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launchEnvironment["WAKEONCUE_TEST_REALTIME_GATEWAY_URL"] = gatewayURL
    app.launchEnvironment["WAKEONCUE_TEST_REALTIME_GATEWAY_TOKEN"] = gatewayToken
    app.launchEnvironment["WAKEONCUE_TEST_PERSIST_REALTIME_CONFIGURATION"] = "1"
    app.launch()

    let settings = app.buttons["Recording storage settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings control is missing")
    settings.tap()
    XCTAssertTrue(
      app.staticTexts["Realtime Gateway connected"].waitForExistence(timeout: 10),
      "Validated realtime configuration was not persisted"
    )
  }

  @MainActor
  func testSimplifiedChineseLocalization() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "zh-Hans"
    app.launch()

    XCTAssertTrue(app.staticTexts["不错过每次会议"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["最近的录音"].exists)

    let settings = app.buttons["录音与转写设置"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10), "Chinese settings control is missing")
    settings.tap()

    XCTAssertTrue(app.staticTexts["语言"].waitForExistence(timeout: 5))
    let appLanguagePicker = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH '应用语言'")
    ).firstMatch
    XCTAssertTrue(appLanguagePicker.exists)
    XCTAssertTrue(app.staticTexts["录音存储"].exists)
    XCTAssertTrue(app.navigationBars["设置"].exists)

    let realtimeSection = app.staticTexts["实时转写服务"]
    for _ in 0..<4 where !realtimeSection.exists {
      app.swipeUp()
    }
    XCTAssertTrue(realtimeSection.exists, "Realtime settings are not fully localized")
    XCTAssertFalse(app.staticTexts["Realtime processing"].exists)
  }

  @MainActor
  func testActionButtonSetupGuide() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launch()

    let settings = app.buttons["Recording storage settings"]
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
    app.launchEnvironment["WAKEONCUE_API_BASE_URL"] =
      ProcessInfo.processInfo.environment["WAKEONCUE_TEST_API_BASE_URL"]
      ?? "http://192.6.7.25:8080/"
    app.launchEnvironment["WAKEONCUE_API_TOKEN"] = "local-development-token"

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
    app.tap()

    let start = app.buttons["Start meeting recording"]
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
    let finish = app.buttons["Finish"]
    XCTAssertTrue(finish.waitForExistence(timeout: 3), "Finish control is missing")
    finish.tap()
  }

  @MainActor
  func testPhysicalRealtimeTranscriptAndSpeakerCorrection() throws {
    let environment = ProcessInfo.processInfo.environment
    let gatewayURL =
      environment["WAKEONCUE_TEST_REALTIME_GATEWAY_URL"] ?? "http://192.6.7.25:8090"
    let gatewayToken =
      environment["WAKEONCUE_TEST_REALTIME_GATEWAY_TOKEN"]
      ?? "physical-realtime-test-20260826"

    let app = XCUIApplication()
    app.launchEnvironment["WAKEONCUE_UI_TEST_LANGUAGE"] = "en"
    app.launchEnvironment["WAKEONCUE_TEST_REALTIME_GATEWAY_URL"] = gatewayURL
    app.launchEnvironment["WAKEONCUE_TEST_REALTIME_GATEWAY_TOKEN"] = gatewayToken
    app.launchEnvironment["WAKEONCUE_TEST_AUDIO_FIXTURE_FILENAME"] =
      environment["WAKEONCUE_TEST_AUDIO_FIXTURE_FILENAME"] ?? "ui-test-four-speakers.wav"

    addUIInterruptionMonitor(withDescription: "Recording permissions") { alert in
      for label in ["Allow", "Allow While Using App"] where alert.buttons[label].exists {
        alert.buttons[label].tap()
        return true
      }
      return false
    }

    app.launch()
    app.tap()
    let alert = app.alerts.firstMatch
    if alert.waitForExistence(timeout: 2), alert.buttons["OK"].exists {
      alert.buttons["OK"].tap()
    }
    let saveLocally = app.buttons["Save to this iPhone"]
    if saveLocally.waitForExistence(timeout: 2) {
      saveLocally.tap()
    }
    let existingFinish = app.buttons["finish-recording"]
    if existingFinish.waitForExistence(timeout: 2) {
      existingFinish.tap()
      if saveLocally.waitForExistence(timeout: 5) {
        saveLocally.tap()
      }
    }
    let start = app.buttons["start-recording"]
    XCTAssertTrue(start.waitForExistence(timeout: 15), "Start recording control is missing")
    start.tap()
    app.tap()

    XCTAssertTrue(
      app.staticTexts["recording-status"].waitForExistence(timeout: 10),
      "The physical device did not start recording"
    )
    XCTAssertTrue(
      app.staticTexts["realtime-status"].waitForExistence(timeout: 15),
      "The physical device did not connect to the realtime Processor"
    )
    XCTAssertTrue(
      app.staticTexts["Live transcript"].waitForExistence(timeout: 5),
      "The live transcript panel is missing"
    )

    let correctedSpeaker = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Speaker ")
    ).firstMatch
    XCTAssertTrue(
      correctedSpeaker.waitForExistence(timeout: 70),
      "No speaker-corrected transcript appeared from the silent test-audio injection"
    )
    let fourthSpeaker = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Speaker 4")
    ).firstMatch
    XCTAssertTrue(
      fourthSpeaker.waitForExistence(timeout: 45),
      "The four-speaker fixture never produced a fourth stable speaker"
    )

    let finish = app.buttons["finish-recording"]
    XCTAssertTrue(finish.waitForExistence(timeout: 5), "Finish control is missing")
    finish.tap()
    if saveLocally.waitForExistence(timeout: 5) {
      saveLocally.tap()
    }
  }
}
