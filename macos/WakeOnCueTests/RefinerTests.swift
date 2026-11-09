import Foundation
import XCTest

/// The rules that decide what the background re-transcription sweep picks up, and the retry
/// backoff. These run against a temporary library, never the real one.
nonisolated final class RefinerTests: XCTestCase {
  private var directory: URL!
  private var store: Store!
  private var now: Date!

  override func setUpWithError() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "RefinerTests-\(UUID().uuidString)")
    self.directory = directory
    store = try MainActor.assumeIsolated { try Store(directory: directory) }
    now = Date(timeIntervalSince1970: 1_800_000_000)
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  @MainActor
  private func sentence(
    at start: Date, seconds: TimeInterval = 3, channel: AudioChannel = .microphone,
    speaker: Speaker = .me, text: String = "实时文字"
  ) -> Int64 {
    store.insertSentence(
      start: start, end: start.addingTimeInterval(seconds), channel: channel, speaker: speaker,
      source: "Mac 麦克风", text: text)
  }

  @MainActor
  private func needing(model: String = "Qwen3-ASR 0.6B", limit: Int = 200) -> [Sentence] {
    store.sentencesNeedingRefinement(model: model, now: now, limit: limit)
  }

  // MARK: The query

  @MainActor func testUnrefinedSentenceIsPickedUp() throws {
    let start = now.addingTimeInterval(-3_600)
    let id = sentence(at: start)
    let found = needing()
    XCTAssertEqual(found.map(\.id), [id])
    XCTAssertEqual(found.first?.refineAttempts, 0)
  }

  @MainActor func testPrivateAndDeletedSentencesAreLeftAlone() throws {
    let start = now.addingTimeInterval(-3_600)
    sentence(at: start)
    store.addMark(.privateRange, start: start.addingTimeInterval(-5), end: start.addingTimeInterval(5))
    XCTAssertTrue(needing().isEmpty, "private time must never go to a model")

    store.removeMarks(.privateRange, overlapping: DateInterval(start: start.addingTimeInterval(-5), end: start.addingTimeInterval(5)))
    store.addMark(.deleted, start: start.addingTimeInterval(-5), end: start.addingTimeInterval(5))
    XCTAssertTrue(needing().isEmpty)
  }

  @MainActor func testPartiallyPrivateSentenceIsLeftAlone() throws {
    let start = now.addingTimeInterval(-3_600)
    sentence(at: start, seconds: 10)
    store.addMark(.privateRange, start: start.addingTimeInterval(5), end: start.addingTimeInterval(15))
    XCTAssertTrue(needing().isEmpty, "any private overlap must keep the whole sentence from a model")
  }

  @MainActor func testFailedManualRetranscriptionClearsTheOldRefinementForTheSweep() throws {
    let id = sentence(at: now.addingTimeInterval(-3_600))
    store.refineSentence(id: id, text: "旧模型文字", by: "Qwen3-ASR 0.6B")
    XCTAssertTrue(needing().isEmpty)

    store.recordRefineFailure(id: id, attempt: 1, next: now.addingTimeInterval(-1))
    XCTAssertNil(store.sentences(ids: [id]).first?.refinedBy)
    XCTAssertEqual(needing().map(\.id), [id], "a failed manual retry must be picked up again")
  }

  @MainActor func testCheckedByTheSameModelIsNotPickedUpAgain() throws {
    let start = now.addingTimeInterval(-3_600)
    let one = sentence(at: start)
    let two = sentence(at: start.addingTimeInterval(10))
    store.markRefineChecked(id: one, model: "Qwen3-ASR 0.6B")
    store.markRefineChecked(id: two, model: "另一个模型")
    XCTAssertEqual(needing().map(\.id), [two], "a different model still wants to check it")
  }

  @MainActor func testSentencesOutOfTriesAreNotPickedUp() throws {
    let start = now.addingTimeInterval(-3_600)
    let id = sentence(at: start)
    store.recordRefineFailure(id: id, attempt: 4, next: nil)
    XCTAssertTrue(needing().isEmpty)
  }

  @MainActor func testBackoffNotDueIsNotPickedUp() throws {
    let start = now.addingTimeInterval(-3_600)
    let id = sentence(at: start)
    store.recordRefineFailure(id: id, attempt: 1, next: now.addingTimeInterval(30))
    XCTAssertTrue(needing().isEmpty)
    store.recordRefineFailure(id: id, attempt: 1, next: now.addingTimeInterval(-1))
    XCTAssertEqual(needing().map(\.id), [id])
  }

  @MainActor func testOldAndUnsettledSentencesAreNotPickedUp() throws {
    let old = sentence(at: now.addingTimeInterval(-8 * 86_400))
    sentence(at: now.addingTimeInterval(-4))
    let eligible = sentence(at: now.addingTimeInterval(-3_600))
    XCTAssertEqual(needing().map(\.id), [eligible], "old sentence \(old) must be left alone")
  }

  @MainActor func testSweepIsOldestFirstAndLimited() throws {
    let first = sentence(at: now.addingTimeInterval(-3 * 3_600))
    let second = sentence(at: now.addingTimeInterval(-2 * 3_600))
    sentence(at: now.addingTimeInterval(-3_600))
    XCTAssertEqual(needing(limit: 2).map(\.id), [first, second])
  }

  @MainActor func testAlreadyRefinedSentenceIsNotPickedUp() throws {
    let id = sentence(at: now.addingTimeInterval(-3_600))
    store.refineSentence(id: id, text: "模型文字", by: "Qwen3-ASR 0.6B")
    XCTAssertTrue(needing().isEmpty)
  }

  @MainActor func testUnrefinedCountsSkipPrivateTimeAndSplitLongSentences() throws {
    let day = Calendar.current.startOfDay(for: now)
    let start = day.addingTimeInterval(10 * 3_600)
    sentence(at: start, seconds: 1)
    sentence(at: start.addingTimeInterval(60), seconds: 2.6)
    sentence(at: start.addingTimeInterval(120), seconds: 5)
    let refined = sentence(at: start.addingTimeInterval(180), seconds: 5)
    store.refineSentence(id: refined, text: "模型文字", by: "Qwen3-ASR 0.6B")
    sentence(at: start.addingTimeInterval(240), seconds: 5)
    store.addMark(.privateRange, start: start.addingTimeInterval(235), end: start.addingTimeInterval(250))
    // The model looked at it and kept the live words: handled, not waiting.
    let kept = sentence(at: start.addingTimeInterval(300), seconds: 5)
    store.markRefineChecked(id: kept, model: "Qwen3-ASR 0.6B")

    let counts = store.unrefinedCounts(in: DateInterval(start: day, duration: 86_400))
    XCTAssertEqual(counts.total, 3)
    XCTAssertEqual(counts.overTwoSeconds, 2)
  }

  // MARK: Backoff

  func testRetryBackoff() {
    XCTAssertEqual(RefineSchedule.retryDelay(after: 0), 0)
    XCTAssertEqual(RefineSchedule.retryDelay(after: 1), 60)
    XCTAssertEqual(RefineSchedule.retryDelay(after: 2), 600)
    XCTAssertEqual(RefineSchedule.retryDelay(after: 3), 3_600)
    XCTAssertNil(RefineSchedule.retryDelay(after: 4))
    XCTAssertNil(RefineSchedule.retryDelay(after: 5))
  }

  @MainActor func testNextTryUsesTheBackoff() {
    let first = RefineSchedule.nextTry(after: 1, now: now)
    XCTAssertEqual(first?.timeIntervalSince(now), 60)
    let third = RefineSchedule.nextTry(after: 3, now: now)
    XCTAssertEqual(third?.timeIntervalSince(now), 3_600)
    XCTAssertNil(RefineSchedule.nextTry(after: 4, now: now))
  }

  @MainActor func testFailureCountIsBumpedFromTheLatestStoredAttempt() {
    let id = sentence(at: now.addingTimeInterval(-3_600))
    store.recordRefineFailure(id: id, attempt: 1, next: now.addingTimeInterval(60))
    XCTAssertEqual(store.bumpRefineFailure(id: id, now: now), 2)
    XCTAssertEqual(store.sentences(ids: [id]).first?.refineAttempts, 2)
    XCTAssertEqual(store.bumpRefineFailure(id: id, now: now), 3)
    XCTAssertEqual(store.sentences(ids: [id]).first?.refineAttempts, 3)
  }

  @MainActor func testReadOnlyStoreReadsAnOldSchemaBeforeTheAppMigratesIt() throws {
    let old = FileManager.default.temporaryDirectory.appending(path: "OldStore-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: old) }
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let database = try SQLiteDatabase(url: old.appending(path: "library.sqlite"))
    try database.execute("""
      CREATE TABLE sentence (
        id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, channel TEXT NOT NULL,
        speaker TEXT NOT NULL, source TEXT NOT NULL, text TEXT NOT NULL)
      """)
    try database.execute(
      "INSERT INTO sentence (start, end, channel, speaker, source, text) VALUES (?, ?, ?, ?, ?, ?)",
      [.date(now), .date(now.addingTimeInterval(3)), .text("microphone"), .text("me"), .text("Mac 麦克风"), .text("旧数据")])

    let readOnly = try Store(directory: old, readOnly: true)
    let saved = readOnly.sentences(in: DateInterval(start: .distantPast, end: .distantFuture))
    XCTAssertEqual(saved.count, 1)
    XCTAssertNil(saved.first?.refinedBy)
    XCTAssertEqual(saved.first?.refineAttempts, 0)
  }
}
