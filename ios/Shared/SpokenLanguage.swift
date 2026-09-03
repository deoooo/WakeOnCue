import Foundation

public enum SpokenLanguage: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case simplifiedChinese = "zh"
  case english = "en"

  public var id: String { rawValue }

  public var recognitionCode: String? {
    self == .automatic ? nil : rawValue
  }

  public var title: LocalizedStringResource {
    switch self {
    case .automatic: "Automatic detection"
    case .simplifiedChinese: "Chinese"
    case .english: "English"
    }
  }
}
