import Foundation
import WakeOnCueCore

/// Read-only access to recordings an older version backed up to S3.
enum S3StorageClient {
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
}

enum S3StorageError: LocalizedError {
  case downloadFailed(String)

  var errorDescription: String? {
    switch self {
    case .downloadFailed(let message):
      String(format: AppLanguage.localized("Could not download the recording: %@"), message)
    }
  }
}
