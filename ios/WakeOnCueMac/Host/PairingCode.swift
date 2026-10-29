import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The iPhone pairing payload from `docs/realtime-processing.md`, the same JSON
/// `server/scripts/generate_realtime_pairing.py` writes. It contains the Gateway token,
/// so it is only built on demand and never written to disk.
enum PairingCode {
  static let type = "wakeoncue.realtime-gateway"
  static let version = 1

  static func payload(gatewayURL: URL, token: String) throws -> String {
    let object: [String: Any] = [
      "type": type,
      "version": version,
      "gateway_url": gatewayURL.absoluteString,
      "gateway_token": token,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  static func qrImage(for payload: String, size: CGFloat = 240) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
    let scale = (size / output.extent.width).rounded(.down)
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext()
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
  }
}
