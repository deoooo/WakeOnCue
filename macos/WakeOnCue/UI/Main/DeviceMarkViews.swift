import SwiftUI

/// The Watch and iPhone marks ("记下刚才") of an hour, with their tags. Clicking one plays from
/// where it starts.
struct DeviceMarkList: View {
  @Environment(AppModel.self) private var model
  let marks: [DeviceMark]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(marks) { mark in
        Button {
          model.play(from: mark.start)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: mark.source == "watch" ? "applewatch" : "iphone")
              .foregroundStyle(Color.sourceWatch)
            Text(Self.time(mark)).monospacedDigit()
            if let tag = mark.tag {
              Text(tag.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Self.color(tag).opacity(0.16)))
                .foregroundStyle(Self.color(tag))
            }
            if let title = mark.title { Text(title).lineLimit(1) }
            Text(mark.tag == nil && mark.title == nil ? "\(mark.sourceLabel) 上的标记" : mark.sourceLabel)
              .foregroundStyle(.secondary)
          }
          .font(.caption)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("从这里开始播放")
        .accessibilityLabel("\(mark.sourceLabel) 标记 \(Self.time(mark)) \(mark.tag?.label ?? "")，从这里开始播放")
      }
    }
  }

  static func time(_ mark: DeviceMark) -> String {
    guard let end = mark.end, end.timeIntervalSince(mark.start) >= 1 else { return TimeText.clock(mark.start) }
    return TimeText.range(mark.start, end)
  }

  private static func color(_ tag: DeviceMark.Tag) -> Color {
    switch tag {
    case .important: .recording
    case .todo: .event
    case .idea: .sourceOther
    }
  }
}
