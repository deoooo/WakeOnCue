import Foundation

/// How the Mac's all-day timeline is cut into conversations for the iPhone.
nonisolated enum ConversationRules {
  /// Silence longer than this ends a conversation.
  static let gap: TimeInterval = 3 * 60
  /// A stray "嗯" or "对" between conversations is not one of its own: at most this many
  /// sentences and characters…
  static let minorSentences = 2
  static let minorCharacters = 12
  /// …joins the nearest conversation this close, or is left out of the list.
  static let minorReach: TimeInterval = 10 * 60
  /// Bumped when the cutting or the digest changes, so every phone fetches every day again.
  static let version = "3"
}

/// Builds a day's conversations from its sentences. Pure: the same input gives the same
/// conversations and digests.
nonisolated enum ConversationBuilder {
  struct RemoteRecording: Hashable {
    var source: String
    var recordingID: String
    var start: Date
    var end: Date
  }

  static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func day(fromKey key: String, calendar: Calendar = .current) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  /// `sentences` are the day's, hidden ones included; `marks` hide private, deleted and paused
  /// time. A conversation never crosses midnight because only one day's sentences come in.
  static func build(
    sentences: [Sentence], marks: [TimeMark], titles: [String: String], remote: [RemoteRecording]
  ) -> [SyncProtocol.LibraryConversation] {
    let visible = sentences
      .filter { sentence in !marks.contains { $0.covers(sentence.start) } }
      .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    var groups: [[Sentence]] = []
    for sentence in visible {
      if var last = groups.last, let previous = last.last,
        sentence.start.timeIntervalSince(max(previous.end, previous.start)) <= ConversationRules.gap
      {
        last.append(sentence)
        groups[groups.count - 1] = last
      } else {
        groups.append([sentence])
      }
    }
    return foldMinor(groups).map { group in
      let start = group[0].start
      let end = max(group.map(\.end).max() ?? start, group.last!.start)
      let id = "c\(group[0].id)"
      let range = DateInterval(start: start, end: max(end, start))
      var sources: [String] = []
      for sentence in group {
        let label = sentence.channel == .remote ? sentence.source : "Mac"
        if !sources.contains(label) { sources.append(label) }
      }
      let recordings = Array(Set(remote.filter { $0.start < range.end && $0.end > range.start }
        .map { SyncProtocol.DeviceRecording(source: $0.source, recordingID: $0.recordingID) }))
        .sorted { ($0.source, $0.recordingID) < ($1.source, $1.recordingID) }
      let lines = group.map {
        SyncProtocol.LibrarySentence(
          id: $0.id, start: $0.start, end: $0.end, speaker: $0.speaker.rawValue, name: $0.speakerName, text: $0.text)
      }
      let title = titles[id]
      let digestText = ([ConversationRules.version, id, title ?? ""]
        + lines.map { "\($0.id)|\($0.start.timeIntervalSince1970)|\($0.end.timeIntervalSince1970)|\($0.speaker)|\($0.name ?? "")|\($0.text)" }
        + recordings.map { "\($0.source)/\($0.recordingID)" }).joined(separator: "\n")
      return SyncProtocol.LibraryConversation(
        id: id, start: start, end: range.end, sources: sources, title: title, overview: nil, keyPoints: [], todos: [],
        sentences: lines, deviceRecordings: recordings, digest: SyncProtocol.digest(digestText))
    }
  }
}

nonisolated extension ConversationBuilder {
  /// Joins each minor group to the nearer neighbour within `minorReach`, or drops it.
  static func foldMinor(_ groups: [[Sentence]]) -> [[Sentence]] {
    let isMinor = { (group: [Sentence]) in
      group.count <= ConversationRules.minorSentences
        && group.reduce(0) { $0 + $1.text.count } < ConversationRules.minorCharacters
    }
    var result: [[Sentence]] = []
    var pending: [[Sentence]] = []
    func distance(_ earlier: [Sentence], _ later: [Sentence]) -> TimeInterval {
      later[0].start.timeIntervalSince(earlier.map(\.end).max() ?? earlier[0].start)
    }
    for group in groups {
      if isMinor(group) {
        pending.append(group)
        continue
      }
      var current = group
      for minor in pending {
        let before = result.last.map { distance($0, minor) } ?? .infinity
        let after = distance(minor, current)
        if before <= after, before <= ConversationRules.minorReach {
          result[result.count - 1] += minor
        } else if after <= ConversationRules.minorReach {
          current = minor + current
        }
      }
      pending = []
      result.append(current)
    }
    for minor in pending {
      if let last = result.last, distance(last, minor) <= ConversationRules.minorReach {
        result[result.count - 1] += minor
      }
    }
    return result
  }
}

/// Answers a phone's `libraryPull` and `audioFetch` from the store.
@MainActor
struct ConversationLibrary {
  let store: Store
  /// The paired phone asking; its own recordings are listed per conversation.
  let device: String

  /// Every day's digest, from cheap aggregates: a day is built in full only when the phone's
  /// digest differs.
  func dayDigests() -> [String: String] {
    let sentences = store.sentenceDaySignatures()
    let remote = store.remoteDaySignatures(device: device)
    let titles = store.conversationTitleSignatures()
    let marks = store.marks()
    var result: [String: String] = [:]
    for day in sentences.keys {
      guard let start = ConversationBuilder.day(fromKey: day),
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)
      else { continue }
      let dayMarks = marks.filter { $0.start < end && $0.end > start }
        .map { "\($0.kind.rawValue):\($0.start.timeIntervalSince1970)-\($0.end.timeIntervalSince1970)" }
      result[day] = SyncProtocol.digest(
        [ConversationRules.version, sentences[day] ?? "", remote[day] ?? "", titles[day] ?? ""].joined(separator: "#")
          + dayMarks.joined(separator: ","))
    }
    return result
  }

  /// Days whose digest differs from what the phone has, newest first, at most `limit`. A day
  /// the phone has that no longer exists here comes back empty, so the phone removes it.
  func changedDays(known: [String: String], current: [String: String], limit: Int) -> (days: [String], more: Bool) {
    let all = Set(current.keys).union(known.keys)
    let changed = all.filter { current[$0] != known[$0] && !(current[$0] == nil && known[$0] == "") }.sorted(by: >)
    return (Array(changed.prefix(limit)), changed.count > limit)
  }

  func day(_ key: String, digest: String? = nil) -> SyncProtocol.LibraryDay {
    guard let start = ConversationBuilder.day(fromKey: key),
      let end = Calendar.current.date(byAdding: .day, value: 1, to: start)
    else { return SyncProtocol.LibraryDay(day: key, digest: "", conversations: []) }
    let interval = DateInterval(start: start, end: end)
    let remote = store.remoteRecordings(device: device, overlapping: interval).map {
      ConversationBuilder.RemoteRecording(source: $0.source, recordingID: $0.recordingID, start: $0.start, end: $0.end)
    }
    let conversations = ConversationBuilder.build(
      sentences: store.sentences(in: interval), marks: store.marks(overlapping: interval),
      titles: store.conversationTitles(day: key), remote: remote)
    return SyncProtocol.LibraryDay(
      day: key, digest: digest ?? dayDigests()[key] ?? "", conversations: conversations)
  }

  /// Finds a conversation by its ID: the first sentence it starts with.
  func conversation(_ id: String) -> SyncProtocol.LibraryConversation? {
    guard id.hasPrefix("c"), let sentenceID = Int64(id.dropFirst()),
      let first = store.sentences(ids: [sentenceID]).first
    else { return nil }
    return day(ConversationBuilder.dayKey(first.start), digest: "-").conversations.first { $0.id == id }
  }
}
