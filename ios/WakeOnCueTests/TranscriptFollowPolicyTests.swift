import XCTest

@testable import WakeOnCue

final class TranscriptFollowPolicyTests: XCTestCase {
  func testPlaybackPositionChangesScrollWhileFollowing() {
    var policy = TranscriptFollowPolicy()

    XCTAssertTrue(policy.isFollowingPlayback)
    XCTAssertEqual(policy.handle(.playbackPositionChanged), .scrollToPlayback)
  }

  func testManualReadingSuspendsPlaybackScrollingUntilExplicitResume() {
    var policy = TranscriptFollowPolicy()

    XCTAssertEqual(policy.handle(.manualScrollBegan), .none)
    XCTAssertFalse(policy.isFollowingPlayback)
    XCTAssertEqual(policy.handle(.playbackPositionChanged), .none)

    XCTAssertEqual(policy.handle(.returnToPlayback), .scrollToPlayback)
    XCTAssertTrue(policy.isFollowingPlayback)
    XCTAssertEqual(policy.handle(.playbackPositionChanged), .scrollToPlayback)
  }

  func testReturnRequestsImmediateScrollWithoutPlaybackPositionChange() {
    var policy = TranscriptFollowPolicy()
    _ = policy.handle(.manualScrollBegan)

    XCTAssertEqual(policy.handle(.returnToPlayback), .scrollToPlayback)
  }
}
