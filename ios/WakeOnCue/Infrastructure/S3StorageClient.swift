import Foundation
import WakeOnCueCore

enum S3StorageClient {
  static func validate(configuration: S3Configuration) async throws {
    let keyRoot = configuration.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let objectKey = [keyRoot, ".wakeoncue-validation", UUID().uuidString]
      .filter { !$0.isEmpty }
      .joined(separator: "/")
    let payload = Data("WakeOnCue S3 validation".utf8)
    var put = try S3RequestSigner.signedRequest(
      method: "PUT",
      objectKey: objectKey,
      contentType: "application/octet-stream",
      payloadHash: S3RequestSigner.payloadHash(payload),
      configuration: configuration
    )
    put.httpBody = payload
    try await requireSuccess(put, expected: 200..<300)

    do {
      let head = try S3RequestSigner.signedRequest(
        method: "HEAD",
        objectKey: objectKey,
        contentType: "application/octet-stream",
        payloadHash: S3RequestSigner.emptyPayloadHash,
        configuration: configuration
      )
      try await requireSuccess(head, expected: 200..<300)
    } catch {
      try? await delete(objectKey: objectKey, configuration: configuration)
      throw error
    }
    try await delete(objectKey: objectKey, configuration: configuration)
  }

  static func downloadRecording(
    recordingID: String,
    configuration: S3Configuration,
    destinationURL: URL,
    session: URLSession = .shared
  ) async throws -> URL {
    let task = UploadTaskRecord(
      id: "download_\(recordingID)",
      recordingID: recordingID,
      kind: .finish,
      deduplicationKey: "\(recordingID):download",
      localFilePath: destinationURL.path,
      createdAt: .now,
      updatedAt: .now
    )
    let request = try S3RequestSigner.signedRequest(
      method: "GET",
      objectKey: configuration.objectKey(for: task, chunk: nil),
      contentType: "audio/mp4",
      payloadHash: S3RequestSigner.emptyPayloadHash,
      configuration: configuration
    )
    return try await download(request: request, destinationURL: destinationURL, session: session)
  }

  static func downloadTranscript(
    recordingID: String,
    configuration: S3Configuration,
    destinationURL: URL,
    session: URLSession = .shared
  ) async throws -> URL {
    let task = UploadTaskRecord(
      id: "download_transcript_\(recordingID)",
      recordingID: recordingID,
      kind: .transcript,
      deduplicationKey: "\(recordingID):transcript:download",
      localFilePath: destinationURL.path,
      createdAt: .now,
      updatedAt: .now
    )
    let request = try S3RequestSigner.signedRequest(
      method: "GET",
      objectKey: configuration.objectKey(for: task, chunk: nil),
      contentType: "application/json",
      payloadHash: S3RequestSigner.emptyPayloadHash,
      configuration: configuration
    )
    return try await download(request: request, destinationURL: destinationURL, session: session)
  }

  private static func download(
    request: URLRequest,
    destinationURL: URL,
    session: URLSession
  ) async throws -> URL {
    let (temporaryURL, response) = try await session.download(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard 200..<300 ~= http.statusCode else {
      throw S3StorageError.downloadFailed("S3 returned HTTP \(http.statusCode).")
    }

    let fileManager = FileManager.default
    let stagingURL = destinationURL.appendingPathExtension("downloading")
    try? fileManager.removeItem(at: stagingURL)
    do {
      try fileManager.moveItem(at: temporaryURL, to: stagingURL)
      try RecordingFileLayout.protect(stagingURL)
      try? fileManager.removeItem(at: destinationURL)
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
      return destinationURL
    } catch {
      try? fileManager.removeItem(at: stagingURL)
      throw error
    }
  }

  private static func delete(objectKey: String, configuration: S3Configuration) async throws {
    let request = try S3RequestSigner.signedRequest(
      method: "DELETE",
      objectKey: objectKey,
      contentType: "application/octet-stream",
      payloadHash: S3RequestSigner.emptyPayloadHash,
      configuration: configuration
    )
    try await requireSuccess(request, expected: 200..<300)
  }

  private static func requireSuccess(
    _ request: URLRequest,
    expected: Range<Int>
  ) async throws {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard expected.contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      throw S3StorageError.requestFailed(
        body?.isEmpty == false ? body! : "S3 returned HTTP \(http.statusCode)."
      )
    }
  }
}

enum S3StorageError: LocalizedError {
  case requestFailed(String)
  case downloadFailed(String)

  var errorDescription: String? {
    switch self {
    case .requestFailed(let message):
      String(format: AppLanguage.localized("S3 validation failed: %@"), message)
    case .downloadFailed(let message):
      String(format: AppLanguage.localized("Could not download the recording: %@"), message)
    }
  }
}
