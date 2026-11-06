import AppKit
import SwiftUI

/// Fixed colours from the design. The system accent is only for selection, links and things
/// you can click; audio sources and marks have colours of their own.
extension Color {
  private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    })
  }

  static let event = dynamic(0x7A4FD0, 0xB79CFF)
  static let sourceMac = dynamic(0x3D5A80, 0x8FB0D9)
  static let sourceOther = dynamic(0x0B7F82, 0x4CC7C9)
  static let sourceWatch = dynamic(0xE8890C, 0xF2A33C)
  static let recording = dynamic(0xC8102E, 0xFF6B7F)
  static let activity = dynamic(0x5B5C61, 0xA9AAB1)
  static let emptyBar = dynamic(0xE2E3E6, 0x3D3D42)
  static let hatch = dynamic(0xC9CBD1, 0x55555B)
  static let hero = dynamic(0xF4F4F6, 0x29292C)
  static let warningBackground = dynamic(0xFFF1F0, 0x3A2426)
  static let soft = dynamic(0xEEF1F6, 0x2E3138)
  static let highlight = dynamic(0xE3EDFC, 0x1E3557)
}

/// Diagonal stripes for private hours.
nonisolated struct Hatch: Shape {
  var spacing: CGFloat = 6

  func path(in rect: CGRect) -> Path {
    var path = Path()
    var x = -rect.height
    while x < rect.width {
      path.move(to: CGPoint(x: x, y: rect.maxY))
      path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
      x += spacing
    }
    return path
  }
}
