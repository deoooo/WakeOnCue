import Foundation
import Testing

struct VoiceReferenceTests {
  /// A unit vector pointing mostly along `axis`, tilted toward `toward` by `tilt`.
  private func voice(_ axis: Int, toward other: Int = 1, tilt: Float = 0, dimensions: Int = 8) -> [Float] {
    var vector = [Float](repeating: 0, count: dimensions)
    vector[axis] = 1
    vector[other] += tilt
    return VoiceReference.normalized(vector)
  }

  @Test func sameVoiceIsMeOthersAreNot() {
    let me = voice(0)
    #expect(VoiceReference.isMe(voice(0, toward: 3, tilt: 0.5), reference: me))  // similarity ≈ 0.89
    #expect(!VoiceReference.isMe(voice(2), reference: me))
    #expect(!VoiceReference.isMe(voice(2, toward: 0, tilt: 0.5), reference: me))  // ≈ 0.45
  }

  @Test func adaptingNeedsEnoughClearlyMineSentences() {
    let enrolled = voice(0)
    let fewMine = Array(repeating: voice(0, toward: 1, tilt: 0.6), count: VoiceReference.adaptMinimum - 1)
    let others = Array(repeating: voice(4), count: 50)
    #expect(VoiceReference.adapted(enrolled, with: fewMine + others) == nil)
  }

  @Test func adaptingMovesTowardHowTheMicrophoneHearsTheUser() {
    let enrolled = voice(0)
    // Across the room the same voice sounds a little different (tilted toward axis 1).
    let heard = voice(0, toward: 1, tilt: 0.8)
    let candidates = Array(repeating: heard, count: 20) + Array(repeating: voice(5), count: 40)
    let adapted = try! #require(VoiceReference.adapted(enrolled, with: candidates))
    #expect(VoiceReference.similarity(adapted, heard) > VoiceReference.similarity(enrolled, heard))
    #expect(VoiceReference.similarity(adapted, enrolled) > 0.9)
    // Other people's voices do not leak in.
    #expect(abs(VoiceReference.similarity(adapted, voice(5))) < 0.01)
  }

}

struct SummarySpeakerTests {
  private let start = Date(timeIntervalSince1970: 1_793_786_400)

  private func sentence(_ channel: AudioChannel, _ speaker: Speaker, name: String? = nil) -> Sentence {
    Sentence(
      id: 1, start: start, end: start.addingTimeInterval(3), channel: channel, speaker: speaker,
      source: "", text: "把权限写进文档。", speakerName: name)
  }

  @Test func unknownVoiceIsNotTheUser() {
    let lines = [
      sentence(.microphone, .me), sentence(.microphone, .other),
      sentence(.microphone, .other, name: "说话人 2"), sentence(.remote, .me),
    ]
    let labels = SummaryMaterial.forSummary(lines, knowsMyVoice: false).map(\.speakerLabel)
    #expect(labels == ["现场", "他人", "说话人 2", "我"])
    #expect(SummaryMaterial.numbered(SummaryMaterial.forSummary(lines, knowsMyVoice: false)).contains("现场：把权限写进文档"))
  }

  @Test func knownVoiceKeepsMe() {
    let lines = [sentence(.microphone, .me), sentence(.microphone, .other)]
    #expect(SummaryMaterial.forSummary(lines, knowsMyVoice: true).map(\.speakerLabel) == ["我", "他人"])
  }
}
