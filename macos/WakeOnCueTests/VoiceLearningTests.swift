import Foundation
import XCTest

nonisolated final class VoiceLearningTests: XCTestCase {
  /// A unit vector pointing mostly along `axis`, tilted toward `other` by `tilt`.
  private func voice(_ axis: Int, toward other: Int = 1, tilt: Float = 0, dimensions: Int = 8) -> [Float] {
    var vector = [Float](repeating: 0, count: dimensions)
    vector[axis] = 1
    vector[other] += tilt
    return VoiceReference.normalized(vector)
  }

  private func learned(samples: Int) -> LearnedVoice {
    var voiceprint = LearnedVoice.first(voice(0), seconds: 3)
    for _ in 1..<samples { voiceprint = voiceprint.adding(voice(0, toward: 2, tilt: 0.05), seconds: 3) }
    return voiceprint
  }

  func testLearnedVoiceRejectsOutliersAfterFiveSamples() {
    let voiceprint = learned(samples: 5)
    XCTAssertTrue(voiceprint.accepts(voice(0, toward: 2, tilt: 0.1)))
    XCTAssertFalse(voiceprint.accepts(voice(4)))
  }

  func testLearnedVoiceAcceptsAnythingBeforeFiveSamples() {
    let voiceprint = learned(samples: 3)
    XCTAssertTrue(voiceprint.accepts(voice(4)))
  }

  func testClearClusterNeedsAtLeastTwentyPercentCloseSentences() {
    let close = [Float](repeating: 0.8, count: 2)
    let far = [Float](repeating: 0.1, count: 8)
    XCTAssertTrue(VoiceReference.hasClearCluster(close + far))
    XCTAssertFalse(VoiceReference.hasClearCluster(Array(close.prefix(1)) + far))
    XCTAssertFalse(VoiceReference.hasClearCluster([]))
  }

  func testShortSentencesDoNotCreateASpeaker() {
    var clustering = SpeakerClustering()
    XCTAssertNil(clustering.assign(embedding: voice(0), day: day(0), seconds: 1.9))
    XCTAssertTrue(clustering.clusters.isEmpty)
    XCTAssertEqual(clustering.assign(embedding: voice(0), day: day(0), seconds: 2), "说话人 2")
  }

  func testSimilarVoicesJoinTheSameSpeaker() {
    var clustering = SpeakerClustering()
    let first = clustering.assign(embedding: voice(0), day: day(0), seconds: 3)
    let second = clustering.assign(embedding: voice(0, toward: 2, tilt: 0.3), day: day(0), seconds: 3)
    XCTAssertEqual(first, "说话人 2")
    XCTAssertEqual(second, first)
  }

  func testSmallClusterMergesIntoTheNearestBiggerSpeaker() {
    var clustering = SpeakerClustering()
    let small = try! XCTUnwrap(clustering.assign(embedding: voice(0, toward: 2, tilt: 2.2), day: day(0), seconds: 3))
    for _ in 0..<3 { _ = clustering.assign(embedding: voice(0), day: day(0), seconds: 3) }
    let big = try! XCTUnwrap(clustering.clusters.last?.label)
    let merges = clustering.consolidate(day: day(0))
    XCTAssertEqual(merges, [SpeakerClustering.Merge(from: small, to: big)])
    XCTAssertEqual(clustering.clusters.count, 1)
  }

  func testSmallClusterWithoutACloseSpeakerBecomesOther() {
    var clustering = SpeakerClustering()
    for _ in 0..<3 { _ = clustering.assign(embedding: voice(0), day: day(0), seconds: 3) }
    let small = try! XCTUnwrap(clustering.assign(embedding: voice(4), day: day(0), seconds: 3))
    let merges = clustering.consolidate(day: day(0))
    XCTAssertEqual(merges, [SpeakerClustering.Merge(from: small, to: nil)])
    XCTAssertEqual(clustering.clusters.count, 1)
  }

  func testRenamingAClusterKeepsLaterSentencesWithTheName() {
    var clustering = SpeakerClustering()
    let old = try! XCTUnwrap(clustering.assign(embedding: voice(0), day: day(0), seconds: 3))
    clustering.rename(old, to: "林雨", day: day(0))
    XCTAssertEqual(clustering.assign(embedding: voice(0, toward: 2, tilt: 0.3), day: day(0), seconds: 3), "林雨")
  }

  func testUserNamedSmallClusterIsNotMergedAway() {
    var clustering = SpeakerClustering()
    let old = try! XCTUnwrap(clustering.assign(embedding: voice(0), day: day(0), seconds: 3))
    clustering.rename(old, to: "林雨", day: day(0))
    _ = clustering.assign(embedding: voice(4), day: day(0), seconds: 3)
    for _ in 0..<3 { _ = clustering.assign(embedding: voice(5), day: day(0), seconds: 3) }
    let merges = clustering.consolidate(day: day(0))
    XCTAssertFalse(merges.contains { $0.from == "林雨" }, "a name the user gave must never be merged away")
    XCTAssertTrue(clustering.clusters.contains { $0.label == "林雨" })
  }

  func testMeetingNeedsSoundAndANearbyMeetingSentence() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let sentence = Sentence(
      id: 1, start: start, end: start.addingTimeInterval(3), channel: .microphone,
      speaker: .me, source: "Mac 麦克风", text: "我来说")
    let segment = AudioSegment(
      id: 1, channel: .meeting, start: start.addingTimeInterval(-5), end: start.addingTimeInterval(5),
      path: "meeting.aac", source: "飞书")
    let meetingSentence = Sentence(
      id: 2, start: start.addingTimeInterval(-10), end: start.addingTimeInterval(-7), channel: .meeting,
      speaker: .remote, source: "飞书", text: "对方在说话")
    XCTAssertTrue(VoiceMeetingSignal.isDuringMeeting(
      sentence: sentence, meetingSegments: [segment], nearbySentences: [meetingSentence]))
    XCTAssertFalse(VoiceMeetingSignal.isDuringMeeting(
      sentence: sentence, meetingSegments: [], nearbySentences: [meetingSentence]))
    XCTAssertFalse(VoiceMeetingSignal.isDuringMeeting(
      sentence: sentence, meetingSegments: [segment], nearbySentences: []))
    let tooLate = Sentence(
      id: 3, start: start.addingTimeInterval(70), end: start.addingTimeInterval(73), channel: .meeting,
      speaker: .remote, source: "飞书", text: "太晚了")
    XCTAssertFalse(VoiceMeetingSignal.isDuringMeeting(
      sentence: sentence, meetingSegments: [segment], nearbySentences: [tooLate]))
  }

  private func day(_ offset: Int) -> Date {
    Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(Double(offset) * 86_400)
  }
}
