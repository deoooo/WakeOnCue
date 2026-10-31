import Foundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class RecordingQuestionAnsweringTests: XCTestCase {
  func testTermsUseWordsAndCJKCharacterPairs() {
    XCTAssertEqual(RecordingQuestionRetriever.terms("What is the marketing budget?"), ["marketing", "budget"])
    XCTAssertEqual(RecordingQuestionRetriever.terms("下周发布"), ["下周", "周发", "发布"])
    XCTAssertEqual(RecordingQuestionRetriever.terms("Q4 预算是多少"), ["q4", "预算", "算是", "是多", "多少"])
  }

  func testRetrievesBestSegmentsWithLatestRevisionAndTitle() {
    let budget = recording("budget", title: "Budget review")
    let lunch = recording("lunch", title: nil)
    let sources = [
      RecordingQuestionSource(
        recording: budget,
        transcript: [
          segment("budget", "s1", 0, "Good morning everyone"),
          segment("budget", "s2", 65_000, "Marketing budget is 20k", revision: 1),
          segment("budget", "s2", 65_000, "Marketing budget is 30k", revision: 2),
          segment("budget", "s3", 3_725_000, "我们决定下周发布新版本"),
        ],
        summary: nil
      ),
      RecordingQuestionSource(
        recording: lunch,
        transcript: [segment("lunch", "l1", 1_000, "Budget for lunch is small")],
        summary: RecordingSummary(
          title: "Team lunch", overview: "", keyPoints: [], actionItems: [], generatedAt: .now)
      ),
    ]

    let citations = RecordingQuestionRetriever.retrieve(
      question: "What is the marketing budget?", sources: sources)
    XCTAssertEqual(citations.map(\.id), ["budget/s2", "lunch/l1"])
    XCTAssertEqual(citations[0].segment.text, "Marketing budget is 30k")
    XCTAssertEqual(citations[0].recordingTitle, "Budget review")
    XCTAssertEqual(citations[0].timestamp, "01:05")
    XCTAssertEqual(citations[0].startTime, 65)
    XCTAssertEqual(citations[1].recordingTitle, "Team lunch")

    let chinese = RecordingQuestionRetriever.retrieve(question: "什么时候发布？", sources: sources)
    XCTAssertEqual(chinese.first?.id, "budget/s3")
    XCTAssertEqual(chinese.first?.timestamp, "1:02:05")

    XCTAssertTrue(RecordingQuestionRetriever.retrieve(question: "kangaroo", sources: sources).isEmpty)
  }

  func testNothingFoundNeverProducesAnAnswer() async {
    let answer = await RecordingQuestionAnswering.answer(
      question: "kangaroo", citations: [], language: .english)
    XCTAssertNil(answer.text)
    XCTAssertEqual(answer.notice, .nothingFound)
    XCTAssertTrue(answer.sources.isEmpty)
  }

  func testExcerptsIncludeSpeakerAndFitBudget() {
    let source = recording("long", title: "Planning")
    var citations = (0..<20).map { index in
      RecordingCitation(
        recording: source,
        segment: segment("long", "s\(index)", index * 1_000, String(repeating: "word ", count: 100)),
        recordingTitle: "Planning",
        score: 1
      )
    }
    citations[0].speakerName = "Alice"
    let excerpts = RecordingQuestionAnswering.excerpts(for: citations, maxCharacters: 1_200)
    XCTAssertTrue(excerpts[0].hasPrefix("[1] Recording \"Planning\" at 00:00 — Alice: "))
    XCTAssertLessThanOrEqual(excerpts.joined().count, 1_200)
    XCTAssertGreaterThan(excerpts.count, 1)
  }

  func testQuestionSourcesReadOnlyLocalTranscriptsAndSummaries() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ask-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = try RecordingFileLayout(root: root)
    let store = try RecordingStore(databaseURL: layout.databaseURL)
    for id in ["with-text", "without-text"] {
      let record = RecordingRecord(
        id: id, createdAt: .now, startedAt: .now, status: .recording,
        localAudioPath: try layout.sourceAudioURL(recordingID: id).path,
        deviceModel: "test", appVersion: "test")
      try await store.createRecording(record, createPayloadPath: "", enqueueUpload: false)
    }
    try JSONEncoder().encode([segment("with-text", "a", 0, "Orchid launch")])
      .write(to: layout.transcriptURL(recordingID: "with-text"))
    try JSONEncoder().encode(
      RecordingSummary(
        title: "Orchid", overview: "Launch", keyPoints: [], actionItems: [], generatedAt: .now)
    ).write(to: layout.summaryURL(recordingID: "with-text"))

    let sources = try await RecordingLibraryService(layout: layout).questionSources()
    XCTAssertEqual(sources.map(\.recording.id), ["with-text"])
    XCTAssertEqual(sources.first?.summary?.title, "Orchid")
  }

  private func recording(_ id: String, title: String?) -> RecordingRecord {
    RecordingRecord(
      id: id, createdAt: .now, startedAt: .now, status: .completed,
      localAudioPath: "/tmp/\(id).caf", deviceModel: "test", appVersion: "test",
      metadata: title.map { [RecordingRecord.titleMetadataKey: $0] } ?? [:])
  }

  private func segment(
    _ recordingID: String, _ id: String, _ start: Int, _ text: String, revision: Int = 1
  ) -> RealtimeTranscriptEvent {
    RealtimeTranscriptEvent(
      recordingID: recordingID, segmentID: id, revision: revision,
      startMilliseconds: start, endMilliseconds: start + 2_000,
      text: text, isFinal: true, speaker: nil)
  }
}
