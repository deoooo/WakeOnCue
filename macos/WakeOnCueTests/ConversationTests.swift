@preconcurrency import AVFoundation
import Foundation
import Testing

/// How the Mac's timeline is cut into conversations for the iPhone, and their audio.
@MainActor
struct ConversationTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func sentence(_ id: Int64, _ from: TimeInterval, _ to: TimeInterval, _ text: String = "话",
                        channel: AudioChannel = .microphone, source: String = "Mac 麦克风") -> Sentence {
    Sentence(id: id, start: start.addingTimeInterval(from), end: start.addingTimeInterval(to), channel: channel,
             speaker: .me, source: source, text: text)
  }

  @Test func silenceLongerThanTheGapStartsANewConversation() {
    let sentences = [
      sentence(1, 0, 5, "第一段对话的开头一句"), sentence(2, 60, 70), sentence(3, 70 + 179, 260),
      sentence(4, 260 + 181, 450, "第二段对话开头的一句比较长的话"),
    ]
    let conversations = ConversationBuilder.build(sentences: sentences, marks: [], titles: [:], remote: [])
    #expect(conversations.map(\.id) == ["c1", "c4"])
    #expect(conversations[0].sentences.map(\.id) == [1, 2, 3])
    #expect(conversations[0].end == start.addingTimeInterval(260))
  }

  @Test func strayWordsJoinANearbyConversationOrAreLeftOut() {
    let sentences = [
      sentence(1, 0, 10, "我们先看一下这个方案的问题"),
      sentence(2, 300, 301, "嗯"),  // 5 min after: joins the first
      sentence(3, 2_000, 2_001, "对"),  // far from anything: left out
      sentence(4, 4_000, 4_001, "好"),  // 6 min before the next: joins it
      sentence(5, 4_360, 4_380, "下午的会改到三点钟再开始吧"),
    ]
    let conversations = ConversationBuilder.build(sentences: sentences, marks: [], titles: [:], remote: [])
    #expect(conversations.map { $0.sentences.map(\.id) } == [[1, 2], [4, 5]])
    #expect(conversations.map(\.id) == ["c1", "c4"])
  }

  @Test func privateTimeIsLeftOutAndSplitsTheTalk() {
    let sentences = (0..<10).map { sentence(Int64($0 + 1), Double($0) * 60, Double($0) * 60 + 10, "这是一句足够长的话") }
    let hidden = TimeMark(id: 1, kind: .privateRange, start: start.addingTimeInterval(120), end: start.addingTimeInterval(400), createdAt: start)
    let conversations = ConversationBuilder.build(sentences: sentences, marks: [hidden], titles: [:], remote: [])
    #expect(conversations.flatMap { $0.sentences.map(\.id) } == [1, 2, 8, 9, 10])
    #expect(conversations.map(\.id) == ["c1", "c8"])
  }

  @Test func digestFollowsTextTitleAndTheDevicesRecordings() {
    let sentences = [
      sentence(1, 0, 5, "你好，今天我们聊一下上线"), sentence(2, 10, 15, "好的，那我先说一下进度吧", channel: .remote, source: "Apple Watch"),
    ]
    let base = ConversationBuilder.build(sentences: sentences, marks: [], titles: [:], remote: [])[0]
    #expect(base.sources == ["Mac", "Apple Watch"])
    let renamed = ConversationBuilder.build(sentences: sentences, marks: [], titles: ["c1": "午饭"], remote: [])[0]
    #expect(renamed.title == "午饭")
    #expect(renamed.digest != base.digest)
    var edited = sentences
    edited[0].text = "您好，今天我们聊一下上线"
    #expect(ConversationBuilder.build(sentences: edited, marks: [], titles: [:], remote: [])[0].digest != base.digest)
    let watch = ConversationBuilder.RemoteRecording(
      source: "watch", recordingID: "W1", start: start.addingTimeInterval(8), end: start.addingTimeInterval(20))
    let outside = ConversationBuilder.RemoteRecording(
      source: "iphone", recordingID: "P1", start: start.addingTimeInterval(500), end: start.addingTimeInterval(600))
    let withWatch = ConversationBuilder.build(sentences: sentences, marks: [], titles: [:], remote: [watch, outside])[0]
    #expect(withWatch.deviceRecordings == [SyncProtocol.DeviceRecording(source: "watch", recordingID: "W1")])
    #expect(withWatch.digest != base.digest)
    #expect(ConversationBuilder.build(sentences: sentences, marks: [], titles: [:], remote: [])[0].digest == base.digest)
  }

  @Test func dayKeysRoundTrip() {
    let key = ConversationBuilder.dayKey(start)
    let day = ConversationBuilder.day(fromKey: key)!
    #expect(ConversationBuilder.dayKey(day) == key)
    #expect(Calendar.current.isDate(day, inSameDayAs: start))
  }

  @Test func libraryDayPacksAndUnpacks() throws {
    let conversations = ConversationBuilder.build(sentences: [sentence(1, 0, 5, "测试一下压缩和解压是否一致")], marks: [], titles: [:], remote: [])
    let day = SyncProtocol.LibraryDay(day: "2027-01-15", digest: "d", conversations: conversations)
    #expect(try SyncProtocol.unpackDay(SyncProtocol.pack(day)) == day)
    let frame = try SyncProtocol.frame(.libraryDay(day: "2027-01-15", bodyLength: 4))
    #expect(frame.count > 4)
  }

  @Test func sentenceTimesKeepTheirMilliseconds() throws {
    let precise = Date(timeIntervalSince1970: 1_800_000_000.456)
    let line = SyncProtocol.LibrarySentence(id: 1, start: precise, end: precise.addingTimeInterval(1.5), speaker: "me", name: nil, text: "话")
    let decoded = try JSONDecoder.sync.decode(SyncProtocol.LibrarySentence.self, from: JSONEncoder.sync.encode(line))
    #expect(abs(decoded.start.timeIntervalSince(precise)) < 0.001)
    #expect(abs(decoded.end.timeIntervalSince(precise) - 1.5) < 0.001)
  }

  // MARK: Audio

  private func segment(_ id: Int64, _ channel: AudioChannel, _ from: TimeInterval, _ to: TimeInterval, path: String = "") -> AudioSegment {
    AudioSegment(id: id, channel: channel, start: start.addingTimeInterval(from), end: start.addingTimeInterval(to),
                 path: path.isEmpty ? "\(id).aac" : path, source: "")
  }

  @Test func macAudioWinsAndHiddenTimeStaysSilent() {
    let range = DateInterval(start: start, end: start.addingTimeInterval(100))
    let hidden = TimeMark(id: 1, kind: .deleted, start: start.addingTimeInterval(20), end: start.addingTimeInterval(30), createdAt: start)
    let pieces = ConversationAudio.plan(
      range: range,
      segments: [segment(1, .remote, -10, 120), segment(2, .microphone, 10, 60)],
      hidden: [hidden])
    let spans = pieces.map { ($0.segment.id, $0.range.start.timeIntervalSince(start), $0.range.end.timeIntervalSince(start)) }
    #expect(spans.map(\.0) == [1, 2, 2, 1])
    #expect(spans.map(\.1) == [0, 10, 30, 60])
    #expect(spans.map(\.2) == [10, 20, 60, 100])
  }

  @Test func renderedAudioKeepsTheConversationsLength() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "conversation-audio-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Two seconds of tone, recorded from second 1 to 3 of a 5-second conversation.
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    do {
      let file = try AVAudioFile(forWriting: folder.appending(path: "a.aac"), settings: ChannelPipeline.aacSettings,
                                 commonFormat: .pcmFormatFloat32, interleaved: false)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
      buffer.frameLength = 32_000
      for i in 0..<32_000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.1) * 0.3 }
      try file.write(from: buffer)
    }
    let range = DateInterval(start: start, end: start.addingTimeInterval(5))
    let pieces = ConversationAudio.plan(range: range, segments: [segment(1, .microphone, 1, 3, path: "a.aac")], hidden: [])
    let output = folder.appending(path: "out.m4a")
    try ConversationAudio.render(pieces, range: range, audioDirectory: folder, to: output)
    let rendered = try AVAudioFile(forReading: output)
    let seconds = Double(rendered.length) / rendered.processingFormat.sampleRate
    #expect(abs(seconds - 5) < 0.2)
  }
}
