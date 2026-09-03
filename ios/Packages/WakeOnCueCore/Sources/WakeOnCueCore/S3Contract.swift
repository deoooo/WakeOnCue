import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct S3Configuration: Equatable, Sendable {
  public static let metadataEndpointKey = "s3.endpoint"
  public static let metadataRegionKey = "s3.region"
  public static let metadataBucketKey = "s3.bucket"
  public static let metadataPrefixKey = "s3.prefix"
  public static let metadataPathStyleKey = "s3.forcePathStyle"

  public let endpointURL: URL?
  public let region: String
  public let bucket: String
  public let prefix: String
  public let accessKeyID: String
  public let secretAccessKey: String
  public let sessionToken: String?
  public let forcePathStyle: Bool

  public init(
    endpointURL: URL? = nil,
    region: String,
    bucket: String,
    prefix: String = "wakeoncue",
    accessKeyID: String,
    secretAccessKey: String,
    sessionToken: String? = nil,
    forcePathStyle: Bool = false
  ) {
    self.endpointURL = endpointURL
    self.region = region
    self.bucket = bucket
    self.prefix = prefix
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.sessionToken = sessionToken
    self.forcePathStyle = forcePathStyle
  }

  public func objectKey(for task: UploadTaskRecord, chunk: ChunkRecord?) -> String {
    let root = [prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "recordings", task.recordingID]
      .filter { !$0.isEmpty }
      .joined(separator: "/")
    switch task.kind {
    case .createRecording:
      return "\(root)/metadata.json"
    case .uploadChunk:
      return "\(root)/chunks/\(String(format: "%06d", chunk?.index ?? 0)).m4a"
    case .finish:
      return "\(root)/source.m4a"
    case .transcript:
      return "\(root)/transcript.json"
    case .pause, .resume:
      return "\(root)/events/\(task.kind.rawValue)-\(task.id).json"
    }
  }

  public var recordingMetadata: [String: String] {
    [
      Self.metadataEndpointKey: endpointURL?.absoluteString ?? "",
      Self.metadataRegionKey: region,
      Self.metadataBucketKey: bucket,
      Self.metadataPrefixKey: prefix,
      Self.metadataPathStyleKey: forcePathStyle ? "true" : "false",
    ]
  }

  /// Legacy recordings have no location metadata and are assumed to use the active destination.
  public func matchesRecordedLocation(_ metadata: [String: String]) -> Bool {
    guard let recordedBucket = metadata[Self.metadataBucketKey] else { return true }
    return recordedBucket == bucket
      && metadata[Self.metadataRegionKey] == region
      && metadata[Self.metadataPrefixKey] == prefix
      && metadata[Self.metadataEndpointKey, default: ""] == (endpointURL?.absoluteString ?? "")
      && metadata[Self.metadataPathStyleKey, default: "false"]
        == (forcePathStyle ? "true" : "false")
  }
}

public enum S3RequestError: Error, LocalizedError, Sendable {
  case invalidEndpoint
  case invalidConfiguration(String)
  case unreadableFile(String)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint: "The S3 endpoint URL is invalid."
    case .invalidConfiguration(let message): message
    case .unreadableFile(let path): "Could not read upload file: \(path)"
    }
  }
}

public enum S3RequestSigner {
  public static func signedRequest(
    method: String,
    objectKey: String,
    contentType: String,
    payloadHash: String,
    configuration: S3Configuration,
    date: Date = Date()
  ) throws -> URLRequest {
    let url = try objectURL(key: objectKey, configuration: configuration)
    guard let host = canonicalHost(for: url) else { throw S3RequestError.invalidEndpoint }
    let timestamp = timestampFormatter.string(from: date)
    let shortDate = shortDateFormatter.string(from: date)
    var headers: [(String, String)] = [
      ("content-type", contentType),
      ("host", host),
      ("x-amz-content-sha256", payloadHash),
      ("x-amz-date", timestamp),
    ]
    if let token = configuration.sessionToken, !token.isEmpty {
      headers.append(("x-amz-security-token", token))
    }
    headers.sort { $0.0 < $1.0 }
    let canonicalHeaders = headers.map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespacesAndNewlines))\n" }.joined()
    let signedHeaders = headers.map(\.0).joined(separator: ";")
    let canonicalRequest = [
      method,
      url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath,
      url.query ?? "",
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].joined(separator: "\n")
    let scope = "\(shortDate)/\(configuration.region)/s3/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      timestamp,
      scope,
      sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    let dateKey = hmac(Data(shortDate.utf8), key: Data("AWS4\(configuration.secretAccessKey)".utf8))
    let regionKey = hmac(Data(configuration.region.utf8), key: dateKey)
    let serviceKey = hmac(Data("s3".utf8), key: regionKey)
    let signingKey = hmac(Data("aws4_request".utf8), key: serviceKey)
    let signature = hmac(Data(stringToSign.utf8), key: signingKey).hexString

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 60
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
    if let token = configuration.sessionToken, !token.isEmpty {
      request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
    }
    request.setValue(
      "AWS4-HMAC-SHA256 Credential=\(configuration.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
      forHTTPHeaderField: "Authorization"
    )
    return request
  }

  public static func payloadHash(fileURL: URL) throws -> String {
    guard let stream = InputStream(url: fileURL) else {
      throw S3RequestError.unreadableFile(fileURL.path)
    }
    stream.open()
    defer { stream.close() }
    var digest = SHA256()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: 64 * 1024)
      if count < 0 { throw stream.streamError ?? S3RequestError.unreadableFile(fileURL.path) }
      if count == 0 { break }
      digest.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
    }
    return Data(digest.finalize()).hexString
  }

  public static func payloadHash(_ data: Data) -> String {
    sha256Hex(data)
  }

  public static var emptyPayloadHash: String { sha256Hex(Data()) }

  private static func objectURL(key: String, configuration: S3Configuration) throws -> URL {
    let bucket = configuration.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    let region = configuration.region.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !bucket.isEmpty, !region.isEmpty, !configuration.accessKeyID.isEmpty,
      !configuration.secretAccessKey.isEmpty
    else { throw S3RequestError.invalidConfiguration("Bucket, region, and credentials are required.") }

    var components: URLComponents
    var pathSegments: [String] = []
    if let endpoint = configuration.endpointURL {
      guard var endpointComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
        let scheme = endpointComponents.scheme, ["http", "https"].contains(scheme),
        endpointComponents.host != nil
      else { throw S3RequestError.invalidEndpoint }
      if configuration.forcePathStyle {
        pathSegments.append(bucket)
      } else {
        endpointComponents.host = "\(bucket).\(endpointComponents.host!)"
      }
      components = endpointComponents
    } else {
      components = URLComponents()
      components.scheme = "https"
      if configuration.forcePathStyle {
        components.host = "s3.\(region).amazonaws.com"
        pathSegments.append(bucket)
      } else {
        components.host = "\(bucket).s3.\(region).amazonaws.com"
      }
    }
    pathSegments.append(contentsOf: key.split(separator: "/").map(String.init))
    let encoded = pathSegments.map(percentEncodePathSegment).joined(separator: "/")
    let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.percentEncodedPath = "/" + [basePath, encoded].filter { !$0.isEmpty }.joined(separator: "/")
    guard let url = components.url else { throw S3RequestError.invalidEndpoint }
    return url
  }

  private static func canonicalHost(for url: URL) -> String? {
    guard let host = url.host else { return nil }
    if let port = url.port { return "\(host):\(port)" }
    return host
  }

  private static func percentEncodePathSegment(_ segment: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
  }

  private static func sha256Hex(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).hexString
  }

  private static func hmac(_ data: Data, key: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
  }

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }()

  private static let shortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    return formatter
  }()
}

private extension URL {
  var percentEncodedPath: String {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? path
  }
}

private extension Data {
  var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
