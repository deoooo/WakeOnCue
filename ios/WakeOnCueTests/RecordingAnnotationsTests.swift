import Foundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class RecordingAnnotationsTests: XCTestCase {
  @MainActor
  func testUnreadableAnnotationsAreNotOverwrittenByAnEdit() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "annotations-corrupt-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "recordings/rec-corrupt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "annotations.json")
    let original = Data("unreadable existing annotations".utf8)
    try original.write(to: file)
    let service = RecordingAnnotationsService(rootDirectory: root)
    _ = service.annotations(for: "rec-corrupt")
    XCTAssertThrowsError(try service.addBookmark(recordingID: "rec-corrupt", position: 10))
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  @MainActor
  func testAnnotationsPersistAndCanBeReopened() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "recording-annotations-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let recordingID = "rec-persistence"

    let writer = RecordingAnnotationsService(rootDirectory: root)
    let bookmark = try writer.addBookmark(
      recordingID: recordingID,
      position: 125.75,
      title: "Decision"
    )
    try writer.setSpeakerAlias(
      recordingID: recordingID,
      clusterID: "speaker-1",
      alias: "Avery"
    )

    let reader = RecordingAnnotationsService(rootDirectory: root)
    let reopened = try reader.reload(recordingID: recordingID)

    XCTAssertEqual(reopened.bookmarks.count, 1)
    XCTAssertEqual(reopened.bookmarks.first?.id, bookmark.id)
    XCTAssertEqual(reopened.bookmarks.first?.position, 125.75)
    XCTAssertEqual(reopened.bookmarks.first?.title, "Decision")
    XCTAssertEqual(reopened.speakerAliases, ["speaker-1": "Avery"])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          root
          .appending(path: "recordings/\(recordingID)/annotations.json")
          .path
      )
    )
  }

  func testAliasChangesEffectiveRenderingAndBothExports() throws {
    let transcript = [
      segment(
        id: "one",
        start: 2_000,
        end: 4_500,
        text: "We should ship on Tuesday.",
        clusterID: "speaker-1",
        speakerName: "Speaker 1"
      )
    ]
    let aliases = ["speaker-1": "Avery"]

    XCTAssertEqual(effectiveSpeakerName(transcript[0].speaker, aliases: aliases), "Avery")
    XCTAssertEqual(
      RecordingTranscriptExporter.plainText(
        transcript: transcript,
        speakerAliases: aliases
      ),
      "[00:02] Avery: We should ship on Tuesday."
    )
    XCTAssertTrue(
      RecordingTranscriptExporter.srt(
        transcript: transcript,
        speakerAliases: aliases
      ).contains("Avery: We should ship on Tuesday.")
    )
    XCTAssertEqual(transcript[0].speaker?.displayName, "Speaker 1")
  }

  func testExportOmitsSpeakerLabelWhenTranscriptHasNone() {
    let segment = RealtimeTranscriptEvent(
      recordingID: "rec", segmentID: "s1", revision: 1, startMilliseconds: 1_000,
      endMilliseconds: 2_000, text: "Hello", isFinal: true, speaker: nil)
    XCTAssertEqual(
      RecordingTranscriptExporter.plainText(transcript: [segment], speakerAliases: [:]),
      "[00:01] Hello")
    XCTAssertTrue(
      RecordingTranscriptExporter.srt(transcript: [segment], speakerAliases: [:])
        .hasSuffix("\nHello"))
  }

  func testRecordingAliasWinsOverRecognizedSavedVoice() {
    let recognized = RealtimeSpeaker(clusterID: "speaker-1", personID: "p1", displayName: "Speaker 1")
    let anonymous = RealtimeSpeaker(clusterID: "speaker-2", displayName: "Speaker 2")
    let names = ["p1": "Avery"]

    XCTAssertEqual(effectiveSpeakerName(recognized, aliases: [:], personNames: names), "Avery")
    XCTAssertEqual(
      effectiveSpeakerName(recognized, aliases: ["speaker-1": "Morgan"], personNames: names),
      "Morgan")
    XCTAssertEqual(effectiveSpeakerName(anonymous, aliases: [:], personNames: names), "Speaker 2")
  }

  func testSRTSupportsHourLongTimestampsAndMultipleSpeakers() {
    let transcript = [
      segment(
        id: "later",
        start: 3_723_045,
        end: 3_725_900,
        text: "After the hour mark.",
        clusterID: "speaker-2",
        speakerName: "Speaker 2"
      ),
      segment(
        id: "earlier",
        start: 900,
        end: 2_100,
        text: "Opening note.",
        clusterID: "speaker-1",
        speakerName: "Speaker 1"
      ),
    ]

    let result = RecordingTranscriptExporter.srt(
      transcript: transcript,
      speakerAliases: ["speaker-1": "Avery", "speaker-2": "Morgan"]
    )

    XCTAssertEqual(
      result,
      """
      1
      00:00:00,900 --> 00:00:02,100
      Avery: Opening note.

      2
      01:02:03,045 --> 01:02:05,900
      Morgan: After the hour mark.
      """
    )
  }

  private func segment(
    id: String,
    start: Int,
    end: Int,
    text: String,
    clusterID: String,
    speakerName: String
  ) -> RealtimeTranscriptEvent {
    RealtimeTranscriptEvent(
      recordingID: "rec-test",
      segmentID: id,
      revision: 1,
      startMilliseconds: start,
      endMilliseconds: end,
      text: text,
      isFinal: true,
      speaker: RealtimeSpeaker(clusterID: clusterID, displayName: speakerName)
    )
  }
}
