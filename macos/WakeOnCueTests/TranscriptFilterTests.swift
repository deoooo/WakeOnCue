import Testing

/// Cases from real recordings (see the PR that added these rules).
struct TranscriptFilterTests {
  @Test(arguments: ["M", "O", "Wa", "MB", "you", "Thank you", "Thak you", "Mm", "Wow", "。", "Hmm."])
  func noiseIsDropped(_ text: String) {
    #expect(TranscriptFilter.isNoise(text))
  }

  @Test(arguments: ["嗯。", "对", "47", "OK", "PPT", "OK，那我走了", "Hello world", "法院", "Claude Code"])
  func speechIsKept(_ text: String) {
    #expect(!TranscriptFilter.isNoise(text))
  }

  @Test func endTokenAndMadeUpTextAreCut() {
    #expect(TranscriptFilter.cleanModelOutput("听一下呀。<|endoftext|>Human Rights Watch（人权观察）是美国的非政府组织。") == "听一下呀。")
    #expect(TranscriptFilter.cleanModelOutput("嗯，群里发的这个什么？<|endoftext|>Human Rights Watch的这个") == "嗯，群里发的这个什么？")
  }

  @Test func languageTagAndReplacementCharacters() {
    #expect(TranscriptFilter.cleanModelOutput("language Chinese") == "")
    #expect(TranscriptFilter.cleanModelOutput("language Chinese<asr_text>你好。") == "你好。")
    #expect(TranscriptFilter.cleanModelOutput("<asr_text>Hello, world.") == "Hello, world.")
    #expect(TranscriptFilter.cleanModelOutput("\u{FFFD}") == "")
  }

  @Test func spelledLettersAreJoined() {
    #expect(TranscriptFilter.joinSpacedLetters("要先上A P P，然后") == "要先上APP，然后")
    #expect(TranscriptFilter.joinSpacedLetters("S M T P的那个") == "SMTP的那个")
    #expect(TranscriptFilter.joinSpacedLetters("那个O K班") == "那个OK班")
    #expect(TranscriptFilter.joinSpacedLetters("Hello world, I am here") == "Hello world, I am here")
    #expect(TranscriptFilter.joinSpacedLetters("用 A 方案") == "用 A 方案")
  }

  @Test func liveTextIsKeptOverMadeUpReplies() {
    #expect(!TranscriptFilter.shouldReplace(live: "他他在那个 AI", with: ""))
    #expect(!TranscriptFilter.shouldReplace(live: "他的方面", with: "Hello, world."))
    #expect(!TranscriptFilter.shouldReplace(live: "嗯也通你吧", with: "và thông diện những thông điệp mà"))
    #expect(!TranscriptFilter.shouldReplace(live: "对", with: "you"))
    #expect(TranscriptFilter.shouldReplace(live: "Command加鬼则他就是呃引导嘛", with: "command加回车，它就是呃引导嘛。"))
    #expect(TranscriptFilter.shouldReplace(live: "M", with: "嗯。"))
  }
}
