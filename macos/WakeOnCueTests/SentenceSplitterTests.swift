import Testing

struct SentenceSplitterTests {
  private typealias Piece = SentenceSplitter.Piece

  @Test func splitsAtSentenceEnders() {
    let spans = SentenceSplitter.split([Piece(text: "先上APP。", start: 0, end: 1.5), Piece(text: "再上Web？", start: 1.6, end: 3)])
    #expect(spans.map(\.text) == ["先上APP。", "再上Web？"])
    #expect(spans.map(\.start) == [0, 1.6])
    #expect(spans.map(\.end) == [1.5, 3])
  }

  @Test func aPauseEndsASentenceWithoutPunctuation() {
    let spans = SentenceSplitter.split([
      Piece(text: "那个方案不行", start: 0, end: 2), Piece(text: "就取消", start: 2.1, end: 3),
      Piece(text: "然后想问一下邱总", start: 4.2, end: 6),
    ])
    #expect(spans.map(\.text) == ["那个方案不行就取消", "然后想问一下邱总"])
    #expect(spans.last?.start == 4.2)
  }

  @Test func aShortReplyStaysWithWhatFollows() {
    let spans = SentenceSplitter.split([Piece(text: "嗯", start: 0, end: 0.3), Piece(text: "这个要现在开始做吗", start: 1.5, end: 3)])
    #expect(spans.map(\.text) == ["嗯这个要现在开始做吗"])
  }

  @Test func aLongSentenceEndsAtAComma() {
    let spans = SentenceSplitter.split([
      Piece(text: "我们会新做一个海外运营的工具台", start: 0, end: 5), Piece(text: "节点是交互的入口，", start: 5.1, end: 8.5),
      Piece(text: "工具台存数据", start: 8.6, end: 10),
    ])
    #expect(spans.map(\.text) == ["我们会新做一个海外运营的工具台节点是交互的入口，", "工具台存数据"])
  }

  @Test func aShortSentenceKeepsItsCommas() {
    let spans = SentenceSplitter.split([Piece(text: "对，可以发，", start: 0, end: 2), Piece(text: "发出去吧", start: 2.1, end: 3)])
    #expect(spans.count == 1)
  }

  @Test func textAfterAnEnderInsideARunKeepsItsTime() {
    let spans = SentenceSplitter.split([Piece(text: "好的。然后", start: 0, end: 1), Piece(text: "我们看下一个", start: 1.1, end: 2)])
    #expect(spans.map(\.text) == ["好的。", "然后我们看下一个"])
    #expect(spans.last?.start == 0)
  }

  @Test func punctuationOnlyIsDropped() {
    #expect(SentenceSplitter.split([Piece(text: "。", start: 0, end: 0.1), Piece(text: "，", start: 0.2, end: 0.3)]).isEmpty)
  }
}
