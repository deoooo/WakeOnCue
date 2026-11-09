import Foundation
import Testing

struct SentenceGroupsTests {
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  private func sentence(_ id: Int64, _ start: Double, _ end: Double, _ text: String = "实时文字") -> Sentence {
    Sentence(id: id, start: base.addingTimeInterval(start), end: base.addingTimeInterval(end), channel: .microphone, speaker: .me, source: "Mac 麦克风", text: text)
  }

  @Test func closeSentencesGoTogetherUpTo20Seconds() {
    let list = [
      sentence(1, 0, 3), sentence(2, 3.4, 6), sentence(3, 6.5, 9),  // one stretch
      sentence(4, 11, 13),  // after a 2 s pause
      sentence(5, 13.2, 25), sentence(6, 25.5, 33), sentence(7, 33.2, 36),  // longer than 20 s
    ]
    #expect(SentenceGroups.group(containing: 2, in: list).map(\.id) == [1, 2, 3])
    #expect(SentenceGroups.group(containing: 4, in: list).map(\.id) == [4, 5])
    #expect(SentenceGroups.group(containing: 6, in: list).map(\.id) == [6, 7])
    // Every member of a group finds the same group.
    #expect(SentenceGroups.group(containing: 3, in: list).map(\.id) == [1, 2, 3])
    #expect(SentenceGroups.group(containing: 9, in: list).isEmpty)
  }

  @Test func aLiveStretchWaitsForWhatMayFollow() {
    let group = [sentence(1, 0, 3)]
    #expect(SentenceGroups.mayGrow(group, now: base.addingTimeInterval(8), settle: 8))
    #expect(!SentenceGroups.mayGrow(group, now: base.addingTimeInterval(13), settle: 8))
    #expect(!SentenceGroups.mayGrow([sentence(1, 0, 21)], now: base.addingTimeInterval(22), settle: 8))
  }

  @Test func theTailRunsOnButNotIntoTheNextSentenceOrPrivateTime() {
    let group = [sentence(1, 0, 3), sentence(2, 3.4, 6)]
    let free = SentenceGroups.audioRange(of: group, next: nil)
    #expect(free == DateInterval(start: base.addingTimeInterval(-0.25), end: base.addingTimeInterval(7)))
    let beforeNext = SentenceGroups.audioRange(of: group, next: base.addingTimeInterval(6.6))
    #expect(beforeNext?.end == base.addingTimeInterval(6.6))
    let beforeMark = SentenceGroups.audioRange(of: group, next: base.addingTimeInterval(6.8), stop: base.addingTimeInterval(6.3))
    #expect(beforeMark?.end == base.addingTimeInterval(6.3))
    // A "next" sentence that overlaps the last one does not cut into the group's own audio.
    #expect(SentenceGroups.audioRange(of: group, next: base.addingTimeInterval(5))?.end == base.addingTimeInterval(7))
  }

  /// From the 11-06 早会: the model's text for four sentences, split back along the live text.
  @Test func textIsSplitAtTheLiveBoundaries() {
    let live = ["我把它拿过来，买点小玩意儿。", "呃，这个路线产品，昨天自测发现了一些case，然后也在修，但。", "核心就大的流程上是没什么问题的，今天。", "也会妨碍贝塔数据。"]
    let text = "我把它拿过来，那等一下我。呃，这个路线产品，昨天自测发现了一些case，然后也在修改。核心就大的流程上是没什么问题了。今天应该会发给贝塔说。"
    #expect(TextSplitter.split(text, along: live) == [
      "我把它拿过来，那等一下我。", "呃，这个路线产品，昨天自测发现了一些case，然后也在修改。", "核心就大的流程上是没什么问题了。", "今天应该会发给贝塔说。",
    ])
  }

  @Test func halfQuotesAndTrailingCommasAreTidied() {
    let live = ["他说没什么问题了，我们就开始跟老罗说。然后你自己也花时间盘一盘，帮你过一遍。", "确保不要通知二零一四出问题。"]
    let text = "他说：“没什么问题。”那我们就开始跟老罗说：“然后你自己也花时间盘一盘，帮你过一遍，确保不要通知，让一试出问题。”"
    let pieces = TextSplitter.split(text, along: live)
    #expect(pieces == ["他说：“没什么问题。”那我们就开始跟老罗说：然后你自己也花时间盘一盘，帮你过一遍。", "确保不要通知，让一试出问题。"])
  }

  @Test func oneSentenceKeepsTheWholeTextAndNothingIsLost() {
    #expect(TextSplitter.split("今天会新上一个贝塔。", along: ["今天会新上一个贝塔"]) == ["今天会新上一个贝塔。"])
    let pieces = TextSplitter.split("好的。我们开始吧。", along: ["好的", "", "我们开始吧"])
    #expect(pieces.count == 3)
    #expect(pieces.joined() == "好的。我们开始吧。")
  }
}
