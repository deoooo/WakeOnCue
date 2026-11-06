import SwiftUI

/// Full-text search over every transcript, grouped by day and hour, with the surrounding
/// conversation for the selected hit. Private and deleted ranges never show up.
struct SearchPage: View {
  @Environment(AppModel.self) private var model
  @State private var selected: Int64?
  @State private var days = 0
  @State private var speaker: Speaker?
  @State private var channel: AudioChannel?

  private struct Group: Identifiable {
    let id: String
    let title: String
    let hits: [Sentence]
  }

  var body: some View {
    let _ = model.store.revision
    let query = model.ui.searchText.trimmingCharacters(in: .whitespaces)
    let hits = results(for: query)
    let groups = group(hits)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text("共 \(hits.count) 处，分布在 \(groups.count) 段录音").font(.callout).foregroundStyle(.secondary)
        Spacer()
        Picker("时间", selection: $days) {
          Text("时间：全部").tag(0)
          Text("今天").tag(1)
          Text("最近 7 天").tag(7)
          Text("最近 30 天").tag(30)
        }
        .fixedSize()
        Picker("说话人", selection: $speaker) {
          Text("说话人：全部").tag(Speaker?.none)
          ForEach([Speaker.me, .other], id: \.self) { Text($0.label).tag(Speaker?.some($0)) }
        }
        .fixedSize()
        .help("我、他人")
        Picker("来源", selection: $channel) {
          Text("来源：全部").tag(AudioChannel?.none)
          Text("Mac 麦克风").tag(AudioChannel?.some(.microphone))
          Text("手表 / iPhone").tag(AudioChannel?.some(.remote))
        }
        .fixedSize()
      }
      .labelsHidden()
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      Divider()
      HStack(spacing: 0) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            if hits.isEmpty {
              Text(query.isEmpty ? "输入要找的词。" : "没有找到“\(query)”。标为私人或已删除的时段不会出现在搜索里。")
                .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
              VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
                ForEach(group.hits) { hit in
                  Button {
                    selected = hit.id
                  } label: {
                    VStack(alignment: .leading, spacing: 2) {
                      Text("\(TimeText.seconds(hit.start)) · \(hit.speakerLabel) · \(hit.source)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                      Text(Self.highlight(hit.text, query)).font(.system(size: 13)).foregroundStyle(.primary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected == hit.id ? Color.highlight : .clear))
                    .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                }
              }
            }
          }
          .padding(16)
        }
        .frame(minWidth: 320, maxWidth: .infinity)
        Divider()
        context(for: hits.first { $0.id == selected } ?? hits.first, query: query)
          .frame(width: 380)
      }
    }
  }

  private func results(for query: String) -> [Sentence] {
    guard !query.isEmpty else { return [] }
    let hidden = model.store.marks()
    let calendar = Calendar.current
    let since = days == 0 ? Date.distantPast : calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: .now))!
    return model.store.search(query).filter { hit in
      hit.start >= since && !hidden.contains { $0.covers(hit.start) }
        && (speaker == nil || hit.speaker == speaker) && (channel == nil || hit.channel == channel)
    }
  }

  private func group(_ hits: [Sentence]) -> [Group] {
    var groups: [Group] = []
    for hit in hits {
      let key = "h\(Int(Calendar.current.hourStart(hit.start).timeIntervalSince1970))"
      let title = TimeText.relativeDay(hit.start) + " · \(TimeText.clock(Calendar.current.hourStart(hit.start))) 这一小时"
      if let index = groups.firstIndex(where: { $0.id == key }) {
        groups[index] = Group(id: key, title: title, hits: groups[index].hits + [hit])
      } else {
        groups.append(Group(id: key, title: title, hits: [hit]))
      }
    }
    return groups
  }

  @ViewBuilder private func context(for hit: Sentence?, query: String) -> some View {
    if let hit {
      let hidden = model.store.marks()
      let around = model.store.sentences(in: DateInterval(start: hit.start.addingTimeInterval(-90), end: hit.start.addingTimeInterval(90)))
        .filter { s in !hidden.contains { $0.covers(s.start) } }
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(TimeText.clock(Calendar.current.hourStart(hit.start))) 这一小时").font(.system(size: 15, weight: .semibold))
          Text(TimeText.relativeDay(hit.start))
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(around) { sentence in
              (Text(sentence.speakerLabel + " ").fontWeight(.semibold) + Text(Self.highlight(sentence.text, query)))
                .font(.system(size: 13))
                .lineSpacing(3)
                .opacity(sentence.id == hit.id ? 1 : 0.75)
                .textSelection(.enabled)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        HStack {
          Button("从 \(TimeText.seconds(hit.start)) 播放") {
            model.ui.searchText = ""
            model.ui.show(day: hit.start)
            model.play(hit)
          }
          Button("在时间线中打开") {
            model.ui.searchText = ""
            model.cite(hit.id)
          }
        }
        .padding(16)
      }
    } else {
      Color.clear
    }
  }

  static func highlight(_ text: String, _ query: String) -> AttributedString {
    var result = AttributedString(text)
    guard !query.isEmpty else { return result }
    var searchStart = result.startIndex
    while let range = result[searchStart...].range(of: query, options: .caseInsensitive) {
      result[range].backgroundColor = .yellow.opacity(0.45)
      result[range].foregroundColor = .primary
      searchStart = range.upperBound
    }
    return result
  }
}

/// Deleted ranges stay here for 30 days and can be restored.
struct DeletedPage: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let marks = model.deletedMarks.sorted { $0.start > $1.start }
    List {
      if marks.isEmpty {
        Text("没有最近删除的录音。").foregroundStyle(.secondary)
      }
      ForEach(marks) { mark in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(TimeText.relativeDay(mark.start)) \(TimeText.range(mark.start, mark.end))").fontWeight(.semibold)
            let left = max(0, 30 - Int(Date().timeIntervalSince(mark.createdAt) / 86_400))
            Text("\(left) 天后彻底删除").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("恢复") { model.undoDelete(DateInterval(start: mark.start, end: mark.end)) }
        }
        .padding(.vertical, 4)
      }
    }
    .listStyle(.inset)
  }
}
