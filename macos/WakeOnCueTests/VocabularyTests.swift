import Foundation
import Testing

struct VocabularyTests {
  @Test func wordsAreSplitTrimmedAndDeduplicated() {
    let words = Vocabulary.words(from: "老罗，唐总、 贝塔版\n巡检;  老罗 ,APP，app。")
    #expect(words == ["老罗", "唐总", "贝塔版", "巡检", "APP"])
    #expect(Vocabulary.hotwords(words) == "老罗,唐总,贝塔版,巡检,APP")
    #expect(Vocabulary.hotwords([]) == nil)
  }

  @Test func wordsAreCapped() {
    let text = (0..<100).map { "词\($0)" }.joined(separator: ",")
    #expect(Vocabulary.words(from: text).count == Vocabulary.maxWords)
  }

  /// Qwen3-ASR read the hotwords back on a 2-second mumble during the 11-06 早会.
  @Test func hotwordsReadBackAreAnEcho() {
    let words = ["唐总", "老罗", "贝塔", "巡检", "线路产品", "改签", "插件"]
    #expect(Vocabulary.isEcho("唐总，老罗，贝塔，巡检，线路产品，改签，插件。", words: words))
    #expect(Vocabulary.isEcho("老罗，贝塔。", words: words))
    #expect(!Vocabulary.isEcho("那我们就开始跟老罗说。", words: words))
    #expect(!Vocabulary.isEcho("老罗，你那个巡检的规则今天能改完吗？", words: words))
    #expect(!Vocabulary.isEcho("老罗，贝塔。", words: []))
  }

  @Test func quietSpeechIsBroughtUpLoudSpeechIsLeftAlone() {
    let quiet = (0..<16_000).map { Float(sin(Double($0) / 10)) * 0.05 }
    let raised = AudioLevel.normalized(quiet)
    #expect(abs((raised.map(abs).max() ?? 0) - AudioLevel.target) < 0.02)

    let loud = quiet.map { $0 * 15 }
    #expect(AudioLevel.normalized(loud) == loud)

    // Near-silence gets at most +24 dB, not blown up to full scale.
    let hiss = quiet.map { $0 * 0.0006 }
    #expect(abs(AudioLevel.gain(for: hiss) - AudioLevel.maxGain) < 0.001)
    #expect(AudioLevel.normalized([]) == [])
  }
}

struct DailyMeetingTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }

  private func hour(_ day: Int, _ hour: Int) -> DateInterval {
    let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    return DateInterval(start: start, duration: 3_600)
  }

  @Test func meetingFallsInItsHourOnWeekdays() {
    let meeting = DailyMeeting(start: 9 * 60 + 15, end: 9 * 60 + 45, weekdaysOnly: true)
    // 11-06 is a Friday, 11-07 a Saturday.
    let found = meeting.interval(in: hour(6, 9), calendar: calendar)
    #expect(found?.start == hour(6, 9).start.addingTimeInterval(15 * 60))
    #expect(meeting.interval(in: hour(6, 10), calendar: calendar) == nil)
    #expect(meeting.interval(in: hour(7, 9), calendar: calendar) == nil)
    let everyDay = DailyMeeting(start: 9 * 60 + 15, end: 9 * 60 + 45, weekdaysOnly: false)
    #expect(everyDay.interval(in: hour(7, 9), calendar: calendar) != nil)
  }

  @Test func meetingAcrossTheHourCountsForBoth() {
    let meeting = DailyMeeting(start: 9 * 60 + 40, end: 10 * 60 + 20, weekdaysOnly: false)
    #expect(meeting.interval(in: hour(6, 9), calendar: calendar) != nil)
    #expect(meeting.interval(in: hour(6, 10), calendar: calendar) != nil)
    #expect(meeting.interval(in: hour(6, 11), calendar: calendar) == nil)
  }

  @Test func meetingHourAsksForNotesAndUsesTheVocabulary() {
    let start = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9))!
    let line = Sentence(id: 1, start: start, end: start.addingTimeInterval(3), channel: .microphone, speaker: .me, source: "Mac 麦克风", text: "今天会新上一个贝塔。")
    let context = SummaryContext(vocabulary: ["老罗", "贝塔"], meeting: DailyMeeting(start: 9 * 60, end: 10 * 60, weekdaysOnly: true))
    let prompt = SummaryMaterial.hourPrompt(start, part: [line], context: context)
    #expect(prompt.contains("例会纪要"))
    #expect(prompt.contains("老罗、贝塔"))
    #expect(!prompt.contains("用一到两句话"))

    let later = start.addingTimeInterval(3 * 3_600)
    let plain = SummaryMaterial.hourPrompt(later, part: [line], context: context)
    #expect(!plain.contains("例会纪要"))
    #expect(plain.contains("用一到两句话"))
    #expect(SummaryMaterial.mergePrompt(["a", "b"], hour: start, context: context).contains("例会纪要"))
    #expect(!SummaryMaterial.mergePrompt(["a", "b"]).contains("例会纪要"))
  }
}
