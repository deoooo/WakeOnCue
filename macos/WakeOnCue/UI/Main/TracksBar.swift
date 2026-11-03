import SwiftUI

/// The player and the day's audio tracks, hidden until the user plays something or asks for
/// them. Tracks use the same 0–24 scale as the activity chart.
struct TracksBar: View {
  @Environment(AppModel.self) private var model
  let data: DayData

  var body: some View {
    let player = model.player
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Button("−15") { player.skip(-15) }.help("后退 15 秒（←）").accessibilityLabel("后退 15 秒")
        Button(player.isPlaying ? "暂停" : "播放") { player.toggle() }
          .frame(minWidth: 56)
          .fontWeight(.semibold)
          .help("播放或暂停（空格）")
          .disabled(player.position == nil)
        Button("+15") { player.skip(15) }.help("前进 15 秒（→）").accessibilityLabel("前进 15 秒")
        Text(player.position.map(TimeText.seconds) ?? "--:--:--")
          .font(.system(size: 16, weight: .semibold))
          .monospacedDigit()
        Text(player.sourceLabel.isEmpty ? "" : "音频来源：\(player.sourceLabel)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        Menu("\(player.rate.formatted())× 倍速") {
          ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { rate in
            Button("\(rate.formatted())×") { player.rate = rate }
          }
        }
        .fixedSize()
        Button("回到播放位置") {
          if let position = player.position { model.revealPlaying(at: position) }
        }
        .disabled(player.position == nil)
        Button("隐藏") { model.ui.showTracks = false }
      }
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
        GridRow {
          Color.clear.frame(width: 76, height: 1)
          HStack {
            ForEach(["00:00", "06:00", "12:00", "18:00", "24:00"], id: \.self) { label in
              Text(label)
              if label != "24:00" { Spacer() }
            }
          }
          .font(.caption2)
          .monospacedDigit()
          .foregroundStyle(.secondary)
        }
        lane("Mac 麦克风", channel: .microphone, color: .sourceMac, height: 14)
        lane("会议声音", channel: .meeting, color: .sourceMeeting, height: 8)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .background(.bar)
  }

  private func lane(_ name: String, channel: AudioChannel, color: Color, height: CGFloat) -> some View {
    GridRow {
      Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      GeometryReader { geometry in
        let width = geometry.size.width
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 4).fill(Color.soft)
          ForEach(data.segments.filter { $0.channel == channel }) { segment in
            Rectangle()
              .fill(color)
              .frame(width: max(1, (fraction(segment.end) - fraction(segment.start)) * width), height: height)
              .offset(x: fraction(segment.start) * width)
              .help("\(segment.channel == .microphone ? "Mac 麦克风" : segment.source) \(TimeText.range(segment.start, segment.end))")
          }
          // Hidden hours cover every lane so nothing in them can be played.
          ForEach(data.marks) { mark in
            Group {
              if mark.kind == .privateRange {
                Hatch(spacing: 4).stroke(Color.hatch, lineWidth: 1.5).background(Color.soft)
              } else {
                Color.soft
              }
            }
            .frame(width: max(1, (fraction(mark.end) - fraction(mark.start)) * width), height: height)
            .clipped()
            .offset(x: fraction(mark.start) * width)
            .help(mark.kind == .privateRange ? "已标为私人，不能回放" : "已删除")
          }
          if let position = model.player.position, Calendar.current.isDate(position, inSameDayAs: data.day) {
            Rectangle().fill(.primary).frame(width: 2, height: height).offset(x: fraction(position) * width - 1)
          }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { location in
          let date = data.day.addingTimeInterval(Double(location.x / width) * 86_400)
          guard !data.marks.contains(where: { $0.covers(date) }),
            data.segments.contains(where: { $0.channel == channel && $0.start <= date && $0.end > date })
          else { return }
          model.play(from: date)
        }
      }
      .frame(height: height)
    }
  }

  private func fraction(_ date: Date) -> CGFloat {
    CGFloat(min(1, max(0, date.timeIntervalSince(data.day) / 86_400)))
  }
}
