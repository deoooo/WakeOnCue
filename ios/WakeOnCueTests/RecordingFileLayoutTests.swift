import AVFoundation
import Foundation
import WakeOnCueCore
import XCTest

@testable import WakeOnCue

final class RecordingFileLayoutTests: XCTestCase {
  func testSelectedLanguageLocalizesDatesAndGeneratedSpeakerNames() {
    let date = Date(timeIntervalSince1970: 1_787_650_800)
    let speaker = RealtimeSpeaker(clusterID: "speaker-1", displayName: "Speaker 1")

    let chineseDate = formattedStartDate(date, language: .simplifiedChinese)
    let englishDate = formattedStartDate(date, language: .english)

    XCTAssertNotEqual(chineseDate, englishDate)
    XCTAssertEqual(localizedSpeakerName(speaker, language: .simplifiedChinese), "说话人 1")
    XCTAssertEqual(localizedSpeakerName(speaker, language: .english), "Speaker 1")
    XCTAssertEqual(localizedSpeakerName(nil, language: .simplifiedChinese), "说话人待确认")
    let me = RealtimeSpeaker(
      clusterID: "speaker_2", personID: RealtimeSpeaker.selfPersonID, displayName: "Speaker 2")
    let avery = RealtimeSpeaker(clusterID: "speaker_3", personID: "p1", displayName: "Speaker 3")
    XCTAssertEqual(localizedSpeakerName(me, language: .simplifiedChinese), "我")
    XCTAssertEqual(
      localizedSpeakerName(avery, language: .english, personNames: ["p1": "Avery"]), "Avery")
    XCTAssertEqual(localizedSpeakerName(avery, language: .simplifiedChinese), "说话人 3")
    XCTAssertEqual(AppLanguage.simplifiedChinese.localized("Spoken language"), "讲话语言")
    XCTAssertEqual(AppLanguage.simplifiedChinese.localized("Automatic detection"), "自动识别")
  }

  func testLanguageDefaultsToSystemAndPersistsExplicitSelection() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedRecordingState.appGroup))
    let previousValue = defaults.object(forKey: AppLanguage.preferenceKey)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: AppLanguage.preferenceKey)
      } else {
        defaults.removeObject(forKey: AppLanguage.preferenceKey)
      }
    }

    defaults.removeObject(forKey: AppLanguage.preferenceKey)
    XCTAssertEqual(AppLanguage.current, .system)

    AppLanguage.simplifiedChinese.persist()
    XCTAssertEqual(AppLanguage.current, .simplifiedChinese)
    XCTAssertEqual(AppLanguage.current.locale.identifier, "zh-Hans")
  }

  @MainActor
  func testSpokenLanguageDefaultsToAutomaticAndPersistsIndependently() {
    let defaults = UserDefaults.standard
    let previousValue = defaults.object(forKey: AppSettings.spokenLanguageKey)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: AppSettings.spokenLanguageKey)
      } else {
        defaults.removeObject(forKey: AppSettings.spokenLanguageKey)
      }
    }

    defaults.removeObject(forKey: AppSettings.spokenLanguageKey)
    let automaticSettings = AppSettings()
    XCTAssertEqual(automaticSettings.spokenLanguage, .automatic)
    XCTAssertNil(automaticSettings.spokenLanguage.recognitionCode)

    automaticSettings.spokenLanguage = .simplifiedChinese
    XCTAssertEqual(
      defaults.string(forKey: AppSettings.spokenLanguageKey),
      SpokenLanguage.simplifiedChinese.rawValue
    )
    XCTAssertEqual(AppSettings().spokenLanguage.recognitionCode, "zh")
  }

  @MainActor
  func testRetiringRealtimeServiceDeletesVoiceprintsAndTokenButKeepsNames() throws {
    let suiteName = "retire-realtime-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let service = "com.deoooo.WakeOnCue.realtime"
    defer { try? KeychainStore.delete(service: service, account: "remembered-voice-names") }
    defaults.set(true, forKey: "realtime-processing.enabled")
    try KeychainStore.save("token", service: service, account: "gateway-token")
    try KeychainStore.save("{}", service: service, account: "self-voiceprint")
    try KeychainStore.save(
      #"[{"id":"p1","name":"Avery","voiceprint":{"model":"m","embedding":[0.1]},"createdAt":0,"lastHeardAt":0}]"#,
      service: service,
      account: "saved-voices"
    )

    AppSettings.retireRealtimeService(defaults: defaults)

    for account in ["gateway-token", "self-voiceprint", "saved-voices"] {
      XCTAssertNil(try KeychainStore.read(service: service, account: account))
    }
    XCTAssertFalse(defaults.bool(forKey: "realtime-processing.enabled"))
    let names = try XCTUnwrap(
      try KeychainStore.read(service: service, account: "remembered-voice-names"))
    XCTAssertFalse(names.contains("embedding"))
    XCTAssertEqual(
      try JSONDecoder().decode([String: String].self, from: Data(names.utf8)), ["p1": "Avery"])

    try KeychainStore.save("again", service: service, account: "gateway-token")
    defer { try? KeychainStore.delete(service: service, account: "gateway-token") }
    AppSettings.retireRealtimeService(defaults: defaults)
    XCTAssertEqual(
      try KeychainStore.read(service: service, account: "gateway-token"), "again",
      "Retirement runs once")
  }

  func testCreatesDurableQueuePayload() throws {
    let layout = try RecordingFileLayout()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let recording = RecordingRecord(
      id: "rec_layout_test_\(UUID().uuidString)",
      createdAt: now,
      startedAt: now,
      status: .recording,
      localAudioPath: try layout.sourceAudioURL(recordingID: "rec_layout_test").path,
      deviceModel: "test",
      appVersion: "1"
    )
    let payload = try layout.createPayload(recording: recording)
    XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    let decoded = try JSONDecoder().decode(
      CreateRecordingPayload.self,
      from: Data(contentsOf: payload)
    )
    XCTAssertEqual(decoded.id, recording.id)
  }

  func testSharedCommandIsConsumedOnlyOnce() {
    _ = SharedRecordingState.consumePendingCommand()
    SharedRecordingState.enqueue(.pause)
    XCTAssertEqual(SharedRecordingState.consumePendingCommand(), .pause)
    XCTAssertNil(SharedRecordingState.consumePendingCommand())
  }

  func testExistingLiveActivityStateDefaultsToLocalMode() throws {
    struct LegacyState: Encodable {
      let phase = "RECORDING"
      let timerStart = Date(timeIntervalSince1970: 1_700_000_000)
      let pausedElapsedSeconds = 12
      let uploadedDurationSeconds = 10
      let pendingDurationSeconds = 2
    }

    let data = try JSONEncoder().encode(LegacyState())
    let decoded = try JSONDecoder().decode(
      RecordingActivityAttributes.ContentState.self, from: data)
    XCTAssertFalse(decoded.usesS3)
  }

  func testDownloadsMissingFinalM4AFromS3AsARealLocalFile() async throws {
    let layout = try RecordingFileLayout()
    let recordingID = "rec_download_\(UUID().uuidString)"
    let directory = try layout.directory(for: recordingID)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [S3DownloadURLProtocol.self]
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    let destination = try layout.downloadedAudioURL(recordingID: recordingID)
    let configuration = S3Configuration(
      endpointURL: URL(string: "https://storage.example.com"),
      region: "us-east-1",
      bucket: "recordings",
      prefix: "wakeoncue",
      accessKeyID: "test-access",
      secretAccessKey: "test-secret",
      forcePathStyle: true
    )

    let downloaded = try await S3StorageClient.downloadRecording(
      recordingID: recordingID,
      configuration: configuration,
      destinationURL: destination,
      session: session
    )

    XCTAssertEqual(downloaded, destination)
    XCTAssertEqual(try Data(contentsOf: downloaded), S3DownloadURLProtocol.payload)
  }

  func testMissingS3ObjectIsReportedAsNotFound() async throws {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [S3NotFoundURLProtocol.self]
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    let layout = try RecordingFileLayout()
    let recordingID = "not_found_\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(at: layout.directory(for: recordingID)) }
    do {
      _ = try await S3StorageClient.downloadTranscript(
        recordingID: recordingID,
        configuration: S3Configuration(
          endpointURL: URL(string: "https://storage.example.com"),
          region: "us-east-1",
          bucket: "recordings",
          accessKeyID: "test-access",
          secretAccessKey: "test-secret",
          forcePathStyle: true
        ),
        destinationURL: try layout.transcriptURL(recordingID: recordingID),
        session: session
      )
      XCTFail("Expected notFound")
    } catch S3StorageError.notFound {
    }
  }

  func testDownloadsMissingTranscriptFromS3IntoRecordingCache() async throws {
    let layout = try RecordingFileLayout()
    let recordingID = "rec_transcript_download_\(UUID().uuidString)"
    let directory = try layout.directory(for: recordingID)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [S3DownloadURLProtocol.self]
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    let destination = try layout.transcriptURL(recordingID: recordingID)
    let configuration = S3Configuration(
      endpointURL: URL(string: "https://storage.example.com"),
      region: "us-east-1",
      bucket: "recordings",
      prefix: "wakeoncue",
      accessKeyID: "test-access",
      secretAccessKey: "test-secret",
      forcePathStyle: true
    )

    let downloaded = try await S3StorageClient.downloadTranscript(
      recordingID: recordingID,
      configuration: configuration,
      destinationURL: destination,
      session: session
    )

    XCTAssertEqual(downloaded, destination)
    XCTAssertEqual(try Data(contentsOf: downloaded), S3DownloadURLProtocol.payload)
  }
}

private final class S3NotFoundURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }
}

private final class S3DownloadURLProtocol: URLProtocol {
  static let payload = Data("downloaded-m4a".utf8)

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "audio/mp4"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.payload)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
