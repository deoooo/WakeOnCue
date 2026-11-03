import Foundation

/// Local-time formatting used across the app. Times are shown as 24-hour clocks.
nonisolated enum TimeText {
  private static func formatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = format
    return formatter
  }

  private static let folder = formatter("yyyy-MM-dd")
  private static let stamp = formatter("HHmmss")
  private static let clockFormatter = formatter("HH:mm")
  private static let secondsFormatter = formatter("HH:mm:ss")
  private static let dayFormatter = formatter("M 月 d 日 EEE")
  private static let monthFormatter = formatter("yyyy 年 M 月")

  static func dayFolder(_ date: Date) -> String { folder.string(from: date) }
  static func fileStamp(_ date: Date) -> String { stamp.string(from: date) }
  static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
  static func seconds(_ date: Date) -> String { secondsFormatter.string(from: date) }
  static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
  static func month(_ date: Date) -> String { monthFormatter.string(from: date) }

  static func range(_ start: Date, _ end: Date) -> String { "\(clock(start))–\(clock(end))" }

  /// "7 小时 30 分", "12 分钟".
  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "\(minutes) 分钟" }
    return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
  }

  /// "今天", "昨天", or "10 月 28 日".
  static func relativeDay(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "今天" }
    if calendar.isDateInYesterday(date) { return "昨天" }
    return formatter("M 月 d 日").string(from: date)
  }

  static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}

extension Calendar {
  /// The 24 hours of the day that contains `date`.
  func hours(of day: Date) -> [DateInterval] {
    let start = startOfDay(for: day)
    return (0..<24).map { hour in
      let from = date(byAdding: .hour, value: hour, to: start)!
      return DateInterval(start: from, duration: 3_600)
    }
  }

  func hourStart(_ date: Date) -> Date {
    dateInterval(of: .hour, for: date)!.start
  }
}
