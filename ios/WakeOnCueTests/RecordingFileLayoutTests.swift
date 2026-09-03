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
    XCTAssertEqual(AppLanguage.simplifiedChinese.localized("Spoken language"), "讲话语言")
    XCTAssertEqual(AppLanguage.simplifiedChinese.localized("Automatic detection"), "自动识别")
  }

  func testCompletedAudioIsStreamedAsHalfSecondRealtimeFrames() async throws {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "retranscription-\(UUID().uuidString).caf"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
      )
    )
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      for channelIndex in 0..<Int(format.channelCount) {
        let channel = try XCTUnwrap(buffer.floatChannelData?[channelIndex])
        for frame in 0..<Int(buffer.frameLength) {
          channel[frame] = sin(Float(frame) * 0.01) * 0.1
        }
      }
      try file.write(from: buffer)
    }

    var frames: [RealtimeAudioFileFrame] = []
    for try await frame in try await RealtimeAudioFileReader.frames(from: url) {
      frames.append(frame)
    }

    XCTAssertEqual(frames.count, 2)
    XCTAssertEqual(frames.map(\.audio.startMilliseconds), [0, 500])
    XCTAssertEqual(
      frames.reduce(0) { $0 + $1.audio.pcm16LittleEndian.count },
      48_000,
      accuracy: 128
    )
    XCTAssertEqual(frames.last?.progress, 1)
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
  func testLocalAudioRetentionSupportsCustomDaysAndClampsInvalidValues() {
    XCTAssertEqual(AppSettings.defaultLocalAudioRetentionDays, 7)
    XCTAssertEqual(AppSettings.normalizedLocalAudioRetentionDays(0), 1)
    XCTAssertEqual(AppSettings.normalizedLocalAudioRetentionDays(14), 14)
    XCTAssertEqual(AppSettings.normalizedLocalAudioRetentionDays(500), 365)
    XCTAssertEqual(
      AppSettings.localAudioRetentionInterval(days: 14),
      TimeInterval(14 * 24 * 60 * 60)
    )
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

  func testUploadedRecordingCleanupKeepsFinalM4AUntilRetentionExpires() throws {
    let layout = try RecordingFileLayout()
    let recordingID = "rec_cleanup_\(UUID().uuidString)"
    let directory = try layout.directory(for: recordingID)
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = try layout.sourceAudioURL(recordingID: recordingID)
    let chunk = try layout.chunkURL(recordingID: recordingID, index: 1)
    let finalAudio = try layout.downloadedAudioURL(recordingID: recordingID)
    try Data("source".utf8).write(to: source)
    try Data("chunk".utf8).write(to: chunk)
    try Data("final".utf8).write(to: finalAudio)

    let now = Date()
    let recording = RecordingRecord(
      id: recordingID,
      createdAt: now,
      startedAt: now,
      status: .completed,
      localAudioPath: source.path,
      uploadStatus: .completed,
      deviceModel: "test",
      appVersion: "1"
    )
    let chunks = [
      ChunkRecord(
        id: "\(recordingID)_1",
        recordingID: recordingID,
        index: 1,
        localPath: chunk.path,
        checksum: "checksum",
        size: 5,
        startedAt: now,
        duration: 1
      )
    ]
    let maintenance = RecordingStorageMaintenance(fileLayout: layout)

    try maintenance.removeUploadedSourceFiles(recording: recording, chunks: chunks)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: finalAudio.path))

    try maintenance.removeExpiredFinalAudio(recordingID: recordingID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: finalAudio.path))
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

  func testRealtimeWebSocketUsesTheSelectedGatewayWhileKeepingTheSessionPath() throws {
    let sessionURL = try XCTUnwrap(
      URL(string: "wss://public.example/v1/realtime/sessions/rts_123/stream?resume=1")
    )
    let localGateway = try XCTUnwrap(URL(string: "http://wakeoncue-mac.local:8090"))

    let rewritten = try RealtimeProcessingClient.websocketURL(
      sessionURL: sessionURL,
      through: localGateway
    )

    XCTAssertEqual(
      rewritten.absoluteString,
      "ws://wakeoncue-mac.local:8090/v1/realtime/sessions/rts_123/stream?resume=1"
    )
  }

  func testRealtimeGatewaySelectionPrefersAReachableLocalGateway() async throws {
    let local = try XCTUnwrap(URL(string: "http://available.local:8090"))
    let publicGateway = try XCTUnwrap(URL(string: "https://public.example"))
    let selected = try await RealtimeGatewaySelector.select(
      configuration: RealtimeProcessingConfiguration(
        gatewayURL: publicGateway,
        bearerToken: "test-token"
      ),
      discovery: FixedRealtimeGatewayDiscovery(gateways: [local]),
      urlSession: realtimeProbeSession()
    )

    XCTAssertEqual(selected, local)
  }

  func testRealtimeGatewaySelectionFallsBackToPublicGateway() async throws {
    let unavailableLocal = try XCTUnwrap(URL(string: "http://unavailable.local:8090"))
    let publicGateway = try XCTUnwrap(URL(string: "https://public.example"))
    let selected = try await RealtimeGatewaySelector.select(
      configuration: RealtimeProcessingConfiguration(
        gatewayURL: publicGateway,
        bearerToken: "test-token"
      ),
      discovery: FixedRealtimeGatewayDiscovery(gateways: [unavailableLocal]),
      urlSession: realtimeProbeSession()
    )

    XCTAssertEqual(selected, publicGateway)
  }

  private func realtimeProbeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RealtimeGatewayProbeURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private struct FixedRealtimeGatewayDiscovery: RealtimeGatewayDiscovering {
  let gateways: [URL]

  func discoverGateways(timeout: Duration) async -> [URL] { gateways }
}

private final class RealtimeGatewayProbeURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let statusCode = url.host == "unavailable.local" ? 503 : 200
    let payload = Data("{\"protocol_version\":1}".utf8)
    let response = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: payload)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
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
