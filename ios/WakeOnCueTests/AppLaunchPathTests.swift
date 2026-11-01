import XCTest

@testable import WakeOnCue

/// Location and calendar daemons can take minutes to answer after a device boots, so
/// constructing these at launch must not make synchronous calls into their frameworks.
@MainActor
final class AppLaunchPathTests: XCTestCase {
  func testPlaceAutomationDoesNotTouchCoreLocationAtLaunch() {
    let places = PlaceAutomation()
    places.start()

    XCTAssertFalse(places.hasLocationManager)
    XCTAssertNil(places.authorization)
  }

  func testCalendarAutomationDoesNotTouchEventKitAtLaunch() {
    let meetings = CalendarAutomation()
    meetings.start()

    XCTAssertFalse(meetings.hasEventStore)
    XCTAssertEqual(meetings.authorization, .notDetermined)
  }
}
