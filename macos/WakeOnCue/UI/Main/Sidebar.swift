import SwiftUI

/// Month calendar, the "整理" list and this Mac's status.
struct Sidebar: View {
  @Environment(AppModel.self) private var model
  @State private var month = Calendar.current.dateInterval(of: .month, for: .now)!.start

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      MonthCalendar(month: $month)
      VStack(alignment: .leading, spacing: 2) {
        Text("整理").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
        Button {
          model.ui.page = .deleted
        } label: {
          HStack {
            Text("最近删除")
            Spacer()
            let count = model.deletedMarks.count
            if count > 0 { Text("\(count)").foregroundStyle(.secondary).font(.caption) }
          }
          .padding(.vertical, 6)
          .padding(.horizontal, 8)
          .background(RoundedRectangle(cornerRadius: 6).fill(model.ui.page == .deleted ? Color.highlight : .clear))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Spacer()
      Divider()
      HStack {
        let status = model.macStatus
        Image(systemName: "laptopcomputer")
          .font(.system(size: 17))
          .overlay(alignment: .topTrailing) {
            Circle().fill(status.dot).frame(width: 7, height: 7).offset(x: 3, y: -2)
          }
          .help("这台 Mac：\(status.text)")
          .accessibilityLabel("这台 Mac：\(status.text)")
        ForEach(model.deviceStatuses) { device in
          Button { model.showSettings(.devices) } label: {
            Image(systemName: device.symbol)
              .font(.system(size: 16))
              .foregroundStyle(device.dot == nil ? .tertiary : .primary)
              .overlay(alignment: .topTrailing) {
                if let dot = device.dot {
                  Circle().fill(dot).frame(width: 7, height: 7).offset(x: 3, y: -2)
                }
              }
          }
          .buttonStyle(.borderless)
          .help(device.text)
          .accessibilityLabel(device.text)
        }
        .padding(.leading, 6)
        Spacer()
        SettingsLink {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("设置（⌘,）")
      }
      .padding(.horizontal, 6)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .onChange(of: model.ui.day) {
      month = Calendar.current.dateInterval(of: .month, for: model.ui.day)!.start
    }
  }
}

private struct MonthCalendar: View {
  @Environment(AppModel.self) private var model
  @Binding var month: Date

  private var calendar: Calendar {
    var calendar = Calendar.current
    calendar.firstWeekday = 2
    return calendar
  }

  var body: some View {
    let _ = model.store.revision
    let days = gridDays()
    let recorded = model.store.recordedDays(in: DateInterval(start: days.first!, end: days.last!.addingTimeInterval(86_400)))
    VStack(spacing: 3) {
      HStack {
        Text(TimeText.month(month)).font(.system(size: 13, weight: .semibold))
        Spacer()
        Button { shift(-1) } label: { Image(systemName: "chevron.left") }
          .accessibilityLabel("上个月")
        Button { shift(1) } label: { Image(systemName: "chevron.right") }
          .accessibilityLabel("下个月")
          .disabled(calendar.date(byAdding: .month, value: 1, to: month)! > .now)
      }
      .buttonStyle(.borderless)
      .padding(.leading, 8)
      .padding(.bottom, 3)
      HStack(spacing: 0) {
        ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).frame(maxWidth: .infinity) }
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
        ForEach(days, id: \.self) { day in
          cell(day, hasRecording: recorded.contains(day))
        }
      }
    }
  }

  private func cell(_ day: Date, hasRecording: Bool) -> some View {
    let selected = calendar.isDate(day, inSameDayAs: model.ui.day) && model.ui.page != .deleted
    let today = calendar.isDateInToday(day)
    let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
    let future = day > .now
    return Button {
      model.ui.show(day: day)
    } label: {
      VStack(spacing: 1) {
        Text("\(calendar.component(.day, from: day))")
          .font(.system(size: 12, weight: today || selected ? .semibold : .regular))
          .monospacedDigit()
        Circle().fill(hasRecording ? (selected ? Color.white : .secondary) : .clear).frame(width: 3, height: 3)
      }
      .frame(maxWidth: .infinity, minHeight: 28)
      .foregroundStyle(selected ? Color.white : future || !inMonth ? .secondary : today ? Color.accentColor : .primary)
      .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(future)
    .accessibilityLabel(TimeText.day(day) + (today ? "，今天" : "") + (hasRecording ? "，有录音" : "，没有录音"))
  }

  private func shift(_ months: Int) {
    month = calendar.date(byAdding: .month, value: months, to: month)!
  }

  /// Full weeks covering the month, Monday first.
  private func gridDays() -> [Date] {
    let first = calendar.dateInterval(of: .month, for: month)!
    let leading = (calendar.component(.weekday, from: first.start) - calendar.firstWeekday + 7) % 7
    let start = calendar.date(byAdding: .day, value: -leading, to: first.start)!
    let count = calendar.range(of: .day, in: .month, for: month)!.count
    let cells = Int(ceil(Double(leading + count) / 7)) * 7
    return (0..<cells).map { calendar.date(byAdding: .day, value: $0, to: start)! }
  }
}
