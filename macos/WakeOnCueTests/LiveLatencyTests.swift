import Testing

struct LiveLatencyTests {
  /// Measured on four meeting clips: fast results cost accuracy unless a model replaces the words.
  @Test func fastResultsOnlyWhenSentencesAreRetranscribed() {
    #expect(LiveLatency.fastResults(sentencesAreRetranscribed: true))
    #expect(!LiveLatency.fastResults(sentencesAreRetranscribed: false))
  }
}
