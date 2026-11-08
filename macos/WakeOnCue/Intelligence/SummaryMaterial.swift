import Foundation

/// A meeting the user has every day at the same time, e.g. the team's 早会 at 9:15.
nonisolated struct DailyMeeting: Equatable, Sendable {
  /// Minutes after midnight.
  var start: Int
  var end: Int
  var weekdaysOnly: Bool

  /// The meeting's time on the day of `hour` when it falls in that hour, or nil.
  func interval(in hour: DateInterval, calendar: Calendar = .current) -> DateInterval? {
    guard end > start else { return nil }
    if weekdaysOnly, calendar.isDateInWeekend(hour.start) { return nil }
    let day = calendar.startOfDay(for: hour.start)
    let meeting = DateInterval(
      start: day.addingTimeInterval(TimeInterval(start * 60)), end: day.addingTimeInterval(TimeInterval(end * 60)))
    guard meeting.start < hour.end, hour.start < meeting.end else { return nil }
    return meeting
  }
}

/// What the summaries know about the user's work besides the transcript.
nonisolated struct SummaryContext: Equatable, Sendable {
  /// 常用词: names and terms the recognizer is likely to have garbled.
  var vocabulary: [String] = []
  var meeting: DailyMeeting?
}

/// What goes to the summary engine and how its words are tidied, kept apart from scheduling so
/// the rules can be tested: which lines carry content, when an hour is too thin to summarize,
/// how a long day is fitted into one request without dropping its later hours, and the prompts.
nonisolated enum SummaryMaterial {
  /// Characters that make a line a bare reply (嗯, 对对对, 好的) rather than content.
  private static let fillerCharacters: Set<Character> = Set("嗯啊呃哦噢喔唔诶欸哎唉嘿喂对好是行嘛呀吧哈呢啦那的么嗨")

  /// A bare reply or noise: worth keeping in the transcript, not in a summary.
  static func isFiller(_ text: String) -> Bool {
    let compact = text.filter { !$0.isPunctuation && !$0.isWhitespace }
    return compact.allSatisfy { fillerCharacters.contains($0) } || TranscriptFilter.isNoise(text)
  }

  /// The lines a summary should read.
  static func meaningful(_ sentences: [Sentence]) -> [Sentence] {
    sentences.filter { !isFiller($0.text) }
  }

  /// Too little was said to summarize: a lone "嗯" at midnight, or half a sentence. Such an hour
  /// gets no summary instead of "只有一句应答，没有形成结论".
  static func isThin(_ sentences: [Sentence]) -> Bool {
    let lines = meaningful(sentences)
    let characters = lines.reduce(0) { $0 + $1.text.filter { !$0.isPunctuation && !$0.isWhitespace }.count }
    return lines.count < 2 || characters < 20
  }

  /// Before the user's voice is known, "我" on the microphone only means "heard by the Mac":
  /// colleagues across the desk and family at home land there too. The summary then calls it
  /// 现场 instead of attributing their words to the user.
  static let unknownMicrophoneSpeaker = "现场"

  static func forSummary(_ sentences: [Sentence], knowsMyVoice: Bool) -> [Sentence] {
    guard !knowsMyVoice else { return sentences }
    return sentences.map { sentence in
      guard sentence.channel == .microphone, sentence.speaker == .me, sentence.speakerName == nil else { return sentence }
      var copy = sentence
      copy.speakerName = unknownMicrophoneSpeaker
      return copy
    }
  }

  // MARK: Hours

  /// The hour's time is already next to its summary; repeating it reads as filler, and so does
  /// saying what did not happen.
  static let hourStyle = """
    直接从事情写起，比如「和供应商核对改价权限，决定把权限写进文档。」\
    不要用「这一小时」「本小时」「这段时间」「主要」开头，也不要复述时间。\
    有决定、数字、人名、时间或待办就写进去；没有结论就只写谈了什么，\
    不要写「没有形成明确结论」「转录里」「录音中」这类话。\
    转录来自语音识别，可能有同音错字，按上下文理解，拿不准的词不要写进总结。\
    麦克风离得远的人声音小，他们的话错字更多，要结合前后文理解，不要因为不通顺就略过；\
    周围不相干的人的谈话也会被录进来，零散、和前后内容接不上的闲聊不要写进总结。
    """

  /// Names and terms to read garbled words against, or nothing.
  static func vocabularyNote(_ words: [String]) -> String {
    guard !words.isEmpty else { return "" }
    return "\n常用的人名和词（转录里读音相近的词多半是它们，按这里的写法写）：\(words.joined(separator: "、"))。"
  }

  /// How a summary covering the daily meeting is written: notes per person or topic.
  static func meetingNote(_ meeting: DateInterval) -> String {
    """

    \(TimeText.range(meeting.start, meeting.end)) 是团队每天的例会，这段转录里有例会的内容。\
    这次的总结写成例会纪要，每行一条，用「· 」开头，三到八行：\
    先按人或按事项写进展、今天的计划和卡住的问题，再写会上定下的待办，带上负责人和时间。\
    人名只用转录或常用词里出现过的，拿不准是谁说的就按事项写，不要猜人名。\
    例会以外的内容合成最后一行带过，和工作无关的闲聊不写。
    """
  }

  static func hourPrompt(_ hour: Date, part: [Sentence], context: SummaryContext = SummaryContext()) -> String {
    let meeting = context.meeting?.interval(in: DateInterval(start: hour, duration: 3_600))
    let length = meeting == nil ? "用一到两句话写出谈了哪些事、有什么结论" : "写出谈了哪些事、有什么结论"
    return """
      下面是 \(TimeText.clock(hour)) 开始一小时的转录，每句前面有编号。\
      \(length)，并挑出最能代表内容的二到五句原话，\
      选有具体信息的句子，不选「嗯」「对」这样的应答。\(hourStyle)\(vocabularyNote(context.vocabulary))\(meeting.map(meetingNote) ?? "")

      \(numbered(part))
      """
  }

  static func mergePrompt(_ notes: [String], hour: Date? = nil, context: SummaryContext = SummaryContext()) -> String {
    if let hour, let meeting = context.meeting?.interval(in: DateInterval(start: hour, duration: 3_600)) {
      return "把下面几段笔记合成一份总结，只输出总结。\(hourStyle)\(vocabularyNote(context.vocabulary))\(meetingNote(meeting))\n\n"
        + notes.joined(separator: "\n")
    }
    return "把下面几段笔记合成一段总结，一到两句话，只输出总结。\(hourStyle)\(vocabularyNote(context.vocabulary))\n\n"
      + notes.joined(separator: "\n")
  }

  /// Drops a leading "这一小时（里），" and a closing "没有形成明确结论" that models still
  /// write, also from older summaries.
  static func tidy(_ summary: String) -> String {
    var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["这一个小时", "这一小时", "这个小时", "本小时", "这一时段", "这段时间"] where text.hasPrefix(prefix) {
      text.removeFirst(prefix.count)
      for word in ["里", "内", "中"] where text.hasPrefix(word) { text.removeFirst(word.count) }
      while let first = text.first, "，,：: ".contains(first) { text.removeFirst() }
      break
    }
    let ending = #/[，；。,;]?\s*(?:但|也|还|转录里|录音里|录音中|目前)?(?:没有|没|未|尚未)(?:能)?形成(?:明确|具体|最终)?的?(?:结论|决定)[。.]?$/#
    if let match = text.firstMatch(of: ending), match.range.lowerBound != text.startIndex {
      text = String(text[..<match.range.lowerBound])
      if let last = text.last, !"。！？.!?".contains(last) { text.append("。") }
    }
    return text.isEmpty ? summary : text
  }

  static func numbered(_ sentences: [Sentence]) -> String {
    sentences.enumerated().map { index, s in
      "[\(index + 1)] \(TimeText.clock(s.start)) \(s.speakerLabel)：\(s.text)"
    }.joined(separator: "\n")
  }

  /// Consecutive slices of at most about `limit` characters.
  static func parts(_ sentences: [Sentence], limit: Int) -> [[Sentence]] {
    var parts: [[Sentence]] = []
    var current: [Sentence] = []
    var size = 0
    for sentence in sentences {
      if size + sentence.text.count > limit, !current.isEmpty {
        parts.append(current)
        current = []
        size = 0
      }
      current.append(sentence)
      size += sentence.text.count + 12
    }
    if !current.isEmpty { parts.append(current) }
    return parts
  }

  /// Runs `request` on the part; when the engine says it is more than its context holds (Apple
  /// Intelligence's small window, a gateway model's limit), on each half instead.
  static func halving<T>(
    _ part: [Sentence], engine: any SummaryEngine, _ request: ([Sentence]) async throws -> T
  ) async throws -> [(result: T, part: [Sentence])] {
    do {
      return [(try await request(part), part)]
    } catch where part.count > 1 && engine.isContextOverflow(error) {
      let middle = part.count / 2
      return try await halving(Array(part[..<middle]), engine: engine, request)
        + halving(Array(part[middle...]), engine: engine, request)
    }
  }

  // MARK: Day

  /// One hour of the day: its summary and the key sentences it picked.
  struct DayHour {
    var start: Date
    var summary: String
    var keys: [Sentence]
  }

  /// Every hour's summary with some of its key sentences, numbered for citing. Each hour gets an
  /// equal share of `budget` characters, so a long day loses key sentences, never its evening.
  /// Numbers start at `firstNumber`, after sentences already listed (the user's marks).
  static func dayMaterial(_ hours: [DayHour], budget: Int, keysPerHour: Int = 4, firstNumber: Int = 1) -> (text: String, sources: [Sentence]) {
    guard !hours.isEmpty else { return ("", []) }
    let share = max(budget / hours.count, 80)
    var lines: [String] = []
    var sources: [Sentence] = []
    for hour in hours {
      let header = "\(TimeText.range(hour.start, hour.start.addingTimeInterval(3_600)))：\(String(hour.summary.prefix(share)))"
      lines.append(header)
      var used = header.count
      for sentence in hour.keys.prefix(keysPerHour) {
        let line = "  [\(firstNumber + sources.count)] \(TimeText.clock(sentence.start)) \(sentence.speakerLabel)：\(sentence.text)"
        guard used + line.count <= share else { break }
        sources.append(sentence)
        lines.append(line)
        used += line.count
      }
    }
    return (lines.joined(separator: "\n"), sources)
  }

  static func dayPrompt(material: String, vocabulary: [String] = []) -> String {
    """
    这是一天里每小时的总结和其中的原话，原话前有编号。先通读全天，再写出当天最重要的一句话和当天的要点。\
    要点是全天最重要的几件事：决定、发现的问题和待办，带上人名和数字。\
    后面几个小时和前面几个小时同样重要，不要只写前几个小时；每个小时最多一条，按时间顺序排列。\
    每条注明依据的原话编号。不要写「没有形成明确结论」这类话。\(vocabularyNote(vocabulary))
    \(material)
    """
  }
}
