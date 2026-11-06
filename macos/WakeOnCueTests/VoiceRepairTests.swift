@preconcurrency import AVFoundation
import Foundation
import XCTest

nonisolated final class VoiceRepairTests: XCTestCase {
  private var directory: URL!
  private var store: Store!

  override func setUpWithError() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "VoiceRepairTests-\(UUID().uuidString)")
    self.directory = directory
    store = try MainActor.assumeIsolated { try Store(directory: directory) }
  }

  override func tearDownWithError() throws {
    store = nil
    try? FileManager.default.removeItem(at: directory)
  }

  @MainActor
  private func sentence(
    at start: Date, channel: AudioChannel = .microphone, speaker: Speaker = .me,
    name: String? = nil
  ) -> Int64 {
    let id = store.insertSentence(
      start: start, end: start.addingTimeInterval(3), channel: channel, speaker: speaker,
      source: "Mac 麦克风", text: "一句话")
    if let name { store.setSpeaker(id: id, speaker: speaker, name: name) }
    return id
  }

  @MainActor func testRepairOnlyResetsUnnamedMicrophoneSentencesInTheWeek() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recent = Calendar.current.startOfDay(for: now).addingTimeInterval(9 * 3_600)
    let enough = sentence(at: recent)
    let unnamedOther = sentence(at: recent.addingTimeInterval(60), speaker: .other)
    let numbered = sentence(at: recent.addingTimeInterval(120), speaker: .other, name: "说话人 2")
    let named = sentence(at: recent.addingTimeInterval(180), speaker: .other, name: "林雨")
    let meeting = sentence(at: recent.addingTimeInterval(240), channel: .meeting, speaker: .remote)
    let old = sentence(at: now.addingTimeInterval(-8 * 86_400), speaker: .other)

    let hours = store.resetUnnamedMicrophoneSpeakers(in: DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now))
    let all = store.sentences(in: DateInterval(start: .distantPast, end: now.addingTimeInterval(86_400)))
    func saved(_ id: Int64) -> Sentence? { all.first { $0.id == id } }

    XCTAssertEqual(saved(enough)?.speaker, .me)
    XCTAssertEqual(saved(unnamedOther)?.speaker, .me)
    XCTAssertNil(saved(unnamedOther)?.speakerName)
    XCTAssertEqual(saved(numbered)?.speaker, .me)
    XCTAssertNil(saved(numbered)?.speakerName)
    XCTAssertEqual(saved(named)?.speaker, .other)
    XCTAssertEqual(saved(named)?.speakerName, "林雨")
    XCTAssertEqual(saved(meeting)?.speaker, .remote)
    XCTAssertEqual(saved(old)?.speaker, .other)
    XCTAssertEqual(hours, [Calendar.current.hourStart(recent)])
  }

  func testPeakOfAWholeAudioFile() throws {
    let silent = try writeFile(amplitude: 0)
    XCTAssertLessThan(try XCTUnwrap(VoiceRepair.peak(of: silent)), AudioLevel.silenceThreshold)

    let sound = try writeFile(amplitude: 0.1)
    XCTAssertGreaterThan(try XCTUnwrap(VoiceRepair.peak(of: sound)), 0.09)
  }

  func testSilentMeetingSegmentIDsOnlyPicksDigitalSilence() async throws {
    let silent = try writeFile(amplitude: 0)
    let sound = try writeFile(amplitude: 0.1)
    let segments = [
      AudioSegment(id: 1, channel: .meeting, start: .now, end: .now, path: silent.lastPathComponent, source: "飞书"),
      AudioSegment(id: 2, channel: .meeting, start: .now, end: .now, path: sound.lastPathComponent, source: "飞书"),
      AudioSegment(id: 3, channel: .meeting, start: .now, end: .now, path: "missing.wav", source: "飞书"),
      AudioSegment(id: 4, channel: .microphone, start: .now, end: .now, path: silent.lastPathComponent, source: "Mac 麦克风"),
    ]
    let ids = await VoiceRepair.silentMeetingSegmentIDs(segments, directory: directory)
    XCTAssertEqual(ids, [1], "microphone segments must never be candidates")
  }

  private func writeFile(amplitude: Float) throws -> URL {
    let url = directory.appending(path: "\(UUID().uuidString).wav")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
    buffer.frameLength = 16_000
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<16_000 {
      samples[index] = amplitude * sin(Float(index) * 2 * .pi * 440 / 16_000)
    }
    try file.write(from: buffer)
    return url
  }
}
