import XCTest

@testable import WakeOnCue

final class RecordingStatusPresentationTests: XCTestCase {
  func testIdleDoesNotClaimThatAFileWasSaved() {
    let status = RecordingStatusPresentation.classify(
      recordingStatus: "READY",
      uploadStatus: "PENDING"
    )

    XCTAssertEqual(status.capture, .ready)
    XCTAssertEqual(status.localFile, .notStarted)
    XCTAssertEqual(status.cloudBackup, .notRequested)
  }

  func testRecordingSavesLocallyWhileCloudBackupRemainsIndependent() {
    let status = RecordingStatusPresentation.classify(
      recordingStatus: "RECORDING",
      uploadStatus: "UPLOADING",
      metadata: ["s3.bucket": "meetings"]
    )

    XCTAssertEqual(status.capture, .recording)
    XCTAssertEqual(status.localFile, .saving)
    XCTAssertEqual(status.cloudBackup, .pending)
  }

  func testFinalizedUploadingRecordingHasLocalFileAndPendingBackup() {
    let status = RecordingStatusPresentation.classify(
      recordingStatus: "UPLOADING",
      uploadStatus: "UPLOADING",
      metadata: ["s3.bucket": "meetings"]
    )

    XCTAssertEqual(status.capture, .finalized)
    XCTAssertEqual(status.localFile, .saved)
    XCTAssertEqual(status.cloudBackup, .pending)
  }

  func testUploadCompletionWithoutRecordedCloudIntentDoesNotClaimSync() {
    let status = RecordingStatusPresentation.classify(
      recordingStatus: "COMPLETED",
      uploadStatus: "COMPLETED"
    )

    XCTAssertEqual(status.localFile, .saved)
    XCTAssertEqual(status.cloudBackup, .notRequested)
  }

  func testUploadCompletionDuringCaptureDoesNotClaimWholeRecordingSynced() {
    let status = RecordingStatusPresentation.classify(
      recordingStatus: "RECORDING",
      uploadStatus: "COMPLETED",
      metadata: ["s3.bucket": "meetings"]
    )

    XCTAssertEqual(status.localFile, .saving)
    XCTAssertEqual(status.cloudBackup, .pending)
  }

  func testCompletedCloudRecordingCanReportThatItsLocalFileWasEvicted() {
    let status = RecordingStatusPresentation.classify(
      recordingStatus: "COMPLETED",
      uploadStatus: "COMPLETED",
      metadata: ["s3.bucket": "meetings"],
      localFileExists: false
    )

    XCTAssertEqual(status.localFile, .unavailable)
    XCTAssertEqual(status.cloudBackup, .synced)
  }

  func testAbandonedCloudSyncWinsOverPersistedS3MetadataAndCompletion() {
    let status = RecordingStatusPresentation.classify(
      recordingStatus: "COMPLETED",
      uploadStatus: "COMPLETED",
      metadata: [
        "s3.bucket": "meetings",
        "cloud_sync_abandoned": "true",
      ]
    )

    XCTAssertEqual(status.localFile, .saved)
    XCTAssertEqual(status.cloudBackup, .abandoned)
  }

  func testFailureDoesNotClaimAudioIsSafeWithoutFileEvidence() {
    let unknown = RecordingStatusPresentation.classify(
      recordingStatus: "FAILED",
      uploadStatus: "FAILED",
      metadata: ["s3.bucket": "meetings"]
    )
    let knownLocal = RecordingStatusPresentation.classify(
      recordingStatus: "FAILED",
      uploadStatus: "FAILED",
      metadata: ["s3.bucket": "meetings"],
      localFileExists: true
    )

    XCTAssertEqual(unknown.localFile, .unknown)
    XCTAssertEqual(unknown.cloudBackup, .failed)
    XCTAssertEqual(knownLocal.localFile, .saved)
  }

  func testOfflineTranscriptionDoesNotChangeRecordingOrStorageState() {
    let status = RecordingStatusPresentation.classify(
      recordingStatus: "RECORDING",
      uploadStatus: "PENDING",
      transcription: .offline
    )

    XCTAssertEqual(status.capture, .recording)
    XCTAssertEqual(status.localFile, .saving)
    XCTAssertEqual(status.transcription, .offline)
  }
}
