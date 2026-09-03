import Foundation
@preconcurrency import Network
import WakeOnCueCore

protocol RealtimeGatewayDiscovering: Sendable {
  func discoverGateways(timeout: Duration) async -> [URL]
}

struct BonjourRealtimeGatewayDiscovery: RealtimeGatewayDiscovering {
  static let serviceType = "_wakeoncue._tcp"

  func discoverGateways(timeout: Duration) async -> [URL] {
    let results = GatewayDiscoveryResults()
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
      using: .tcp
    )
    browser.browseResultsChangedHandler = { discovered, _ in
      let urls = Self.gatewayURLs(from: discovered)
      guard !urls.isEmpty else { return }
      Task { await results.resolve(urls) }
    }
    browser.stateUpdateHandler = { state in
      guard case .failed = state else { return }
      Task { await results.resolve([]) }
    }
    browser.start(queue: DispatchQueue(label: "WakeOnCue.RealtimeGatewayDiscovery"))

    let timeoutTask = Task {
      try? await Task.sleep(for: timeout)
      await results.resolve([])
    }
    let urls = await withTaskCancellationHandler {
      await results.wait()
    } onCancel: {
      browser.cancel()
      Task { await results.resolve([]) }
    }
    timeoutTask.cancel()
    browser.cancel()
    return urls
  }

  static func gatewayURLs(from results: Set<NWBrowser.Result>) -> [URL] {
    var seen = Set<String>()
    return results.compactMap { result in
      guard case .bonjour(let record) = result.metadata,
        record["protocol"] == String(RealtimeProtocol.version),
        let host = record["host"]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !host.isEmpty,
        let portText = record["port"],
        let port = Int(portText),
        (1...65_535).contains(port)
      else { return nil }

      let scheme = record["scheme"] == "https" ? "https" : "http"
      var components = URLComponents()
      components.scheme = scheme
      components.host = host
      components.port = port
      guard let url = components.url, seen.insert(url.absoluteString).inserted else { return nil }
      return url
    }
  }
}

enum RealtimeGatewaySelector {
  static let localDiscoveryTimeout: Duration = .milliseconds(650)

  static func select(
    configuration: RealtimeProcessingConfiguration,
    discovery: any RealtimeGatewayDiscovering,
    urlSession: URLSession
  ) async throws -> URL {
    let localGateways = await discovery.discoverGateways(
      timeout: Self.localDiscoveryTimeout
    )
    for gateway in localGateways where gateway != configuration.gatewayURL {
      if await probe(
        gateway: gateway,
        bearerToken: nil,
        urlSession: urlSession
      ) {
        return gateway
      }
    }
    return configuration.gatewayURL
  }

  static func probe(
    gateway: URL,
    bearerToken: String?,
    urlSession: URLSession
  ) async -> Bool {
    let path = bearerToken == nil ? "health" : "v1/realtime/validate"
    var request = URLRequest(url: gateway.appending(path: path))
    request.httpMethod = bearerToken == nil ? "GET" : "POST"
    request.timeoutInterval = 3
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    do {
      let (data, response) = try await urlSession.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        let status = try? JSONDecoder().decode(GatewayValidationResponse.self, from: data)
      else { return false }
      return status.protocolVersion == RealtimeProtocol.version
    } catch {
      return false
    }
  }
}

private struct GatewayValidationResponse: Decodable {
  let protocolVersion: Int

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
  }
}

private actor GatewayDiscoveryResults {
  private var continuation: CheckedContinuation<[URL], Never>?
  private var resolved: [URL]?

  func wait() async -> [URL] {
    if let resolved { return resolved }
    return await withCheckedContinuation { continuation = $0 }
  }

  func resolve(_ urls: [URL]) {
    guard resolved == nil else { return }
    resolved = urls
    continuation?.resume(returning: urls)
    continuation = nil
  }
}
