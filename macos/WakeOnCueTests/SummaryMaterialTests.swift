import Foundation
import Testing

struct SummaryMaterialTests {
  private let hour = Date(timeIntervalSince1970: 1_793_786_400)

  private func sentence(_ id: Int64, _ text: String, minute: Double = 0) -> Sentence {
    let start = hour.addingTimeInterval(minute * 60)
    return Sentence(id: id, start: start, end: start.addingTimeInterval(3), channel: .microphone, speaker: .me, source: "Mac 麦克风", text: text)
  }

  @Test func fillerLinesAreLeftOut() {
    let lines = ["嗯。", "对对对。", "好的", "对吧？", "you", "把订单查询的日期参数改成必填。"].enumerated().map { sentence(Int64($0), $1) }
    #expect(SummaryMaterial.meaningful(lines).map(\.text) == ["把订单查询的日期参数改成必填。"])
  }

  @Test func thinHoursAreNotSummarized() {
    #expect(SummaryMaterial.isThin([sentence(1, "嗯")]))
    #expect(SummaryMaterial.isThin(["对", "那", "you"].enumerated().map { sentence(Int64($0), $1) }))
    #expect(SummaryMaterial.isThin([sentence(1, "那我们先这样，等一下")]))
    #expect(!SummaryMaterial.isThin([sentence(1, "先上 APP，APP 出去之后再上线 Web。"), sentence(2, "定时任务提前到六点零五。")]))
  }

  @Test func closingNoConclusionIsDropped() {
    #expect(SummaryMaterial.tidy("讨论在看板上直接创建任务、发版日志能否关联用户问题；没有形成明确结论。") == "讨论在看板上直接创建任务、发版日志能否关联用户问题。")
    #expect(SummaryMaterial.tidy("围绕产品问题和老板查看权限展开；转录里没有形成明确结论。") == "围绕产品问题和老板查看权限展开。")
    #expect(SummaryMaterial.tidy("还提到电子票和部署连接。未形成明确结论。") == "还提到电子票和部署连接。")
    #expect(SummaryMaterial.tidy("这一小时里，核对支付流水号。") == "核对支付流水号。")
    #expect(SummaryMaterial.tidy("确认测试后再发布。") == "确认测试后再发布。")
  }

  @Test func hourPromptAsksForSpecificsAndNumbersLines() {
    let prompt = SummaryMaterial.hourPrompt(hour, part: [sentence(1, "改到六点零五。")])
    #expect(prompt.contains("[1]"))
    #expect(prompt.contains("没有形成明确结论"))
    #expect(prompt.contains("人名"))
  }

  @Test func dayMaterialKeepsEveryHourWithinBudget() {
    var hours: [SummaryMaterial.DayHour] = []
    for index in 0..<10 {
      var keys: [Sentence] = []
      for key in 0..<4 {
        keys.append(sentence(Int64(index * 10 + key), String(repeating: "原话", count: 40), minute: Double(index * 60 + key)))
      }
      let start = hour.addingTimeInterval(Double(index) * 3_600)
      hours.append(SummaryMaterial.DayHour(start: start, summary: String(repeating: "核对订单", count: 30), keys: keys))
    }
    let (text, sources) = SummaryMaterial.dayMaterial(hours, budget: 3_600)
    #expect(text.count <= 3_600 + 10 * 2)
    // Every hour is there, the last one too, even when key sentences had to go.
    for item in hours { #expect(text.contains(TimeText.range(item.start, item.start.addingTimeInterval(3_600)))) }
    #expect(!sources.isEmpty)
    #expect(Set(sources.map { Calendar.current.component(.hour, from: $0.start) }).count == 10)
  }

  @Test func dayMaterialNumbersSourcesInOrder() {
    let hours = [SummaryMaterial.DayHour(start: hour, summary: "核对订单。", keys: [sentence(7, "改到六点零五。"), sentence(9, "先上 APP。")])]
    let (text, sources) = SummaryMaterial.dayMaterial(hours, budget: 24_000)
    #expect(sources.map(\.id) == [7, 9])
    #expect(text.contains("[1]") && text.contains("[2]"))
  }

  @Test func overflowingPartIsHalved() async throws {
    nonisolated struct Small: SummaryEngine {
      struct TooLong: Error {}
      var name: String { "test" }
      var destination: String? { nil }
      var partCharacters: Int { 100 }
      func isContextOverflow(_ error: Error) -> Bool { error is TooLong }
      func hour(_ prompt: String) async throws -> HourResult { HourResult(summary: "", keySentences: []) }
      func text(_ prompt: String) async throws -> String { "" }
      func day(_ prompt: String) async throws -> DayResult { DayResult(headline: CitedResult(text: "", sources: []), details: []) }
      func plan(_ prompt: String) async throws -> SearchPlan { SearchPlan(keywords: [], days: 0) }
      func answer(_ prompt: String) async throws -> [CitedResult] { [] }
    }
    let part = (0..<8).map { sentence(Int64($0), "第\($0)句") }
    let results = try await SummaryMaterial.halving(part, engine: Small()) { piece in
      if piece.count > 2 { throw Small.TooLong() }
      return piece.count
    }
    #expect(results.map(\.result) == [2, 2, 2, 2])
    #expect(results.flatMap(\.part).map(\.id) == part.map(\.id))
  }

  @Test func gatewayContextErrorsAreRecognized() {
    #expect(GatewayError.isContextMessage(#"{"error":{"message":"This model's maximum context length is 128000 tokens"}}"#))
    #expect(GatewayError.isContextMessage(#"{"error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#))
    #expect(!GatewayError.isContextMessage(#"{"error":{"message":"Invalid API key"}}"#))
  }
}
