import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system
  case simplifiedChinese = "zh-Hans"
  case english = "en"

  public static let preferenceKey = "app-language"

  public var id: String { rawValue }

  public var locale: Locale {
    switch self {
    case .system: .autoupdatingCurrent
    case .simplifiedChinese: Locale(identifier: "zh-Hans")
    case .english: Locale(identifier: "en")
    }
  }

  public var title: LocalizedStringResource {
    switch self {
    case .system: "Follow System"
    case .simplifiedChinese: "Simplified Chinese"
    case .english: "English"
    }
  }

  public func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: localizationBundle, locale: locale)
  }

  public static func localized(_ key: String.LocalizationValue) -> String {
    current.localized(key)
  }

  public static var current: AppLanguage {
    #if DEBUG
      if let override = ProcessInfo.processInfo.environment["WAKEONCUE_UI_TEST_LANGUAGE"],
        let language = AppLanguage(rawValue: override)
      {
        return language
      }
    #endif
    guard let rawValue = sharedDefaults.string(forKey: preferenceKey),
      let language = AppLanguage(rawValue: rawValue)
    else { return .system }
    return language
  }

  public func persist() {
    Self.sharedDefaults.set(rawValue, forKey: Self.preferenceKey)
  }

  private var localizationBundle: Bundle {
    guard self != .system,
      let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else { return .main }
    return bundle
  }

  private static var sharedDefaults: UserDefaults {
    UserDefaults(suiteName: SharedRecordingState.appGroup) ?? .standard
  }
}
