import Foundation
import Observation
import OSLog
import Security

/// A remembered person: a name and the average of their voice.
nonisolated struct Voiceprint: Codable, Identifiable, Hashable, Sendable {
  var id = UUID()
  var name: String
  var embedding: [Float]
  var samples: Int
  var lastHeard: Date
}

/// Voiceprints in the login keychain, never in the library or anywhere else.
nonisolated enum VoiceprintKeychain {
  private static let service = "com.deoooo.WakeOnCue.macos.voiceprints"

  static func read<T: Decodable>(_ account: String, as type: T.Type) -> T? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  static func write<T: Encodable>(_ value: T?, _ account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    guard let value, let data = try? JSONEncoder().encode(value) else { return }
    var attributes = query
    attributes[kSecValueData as String] = data
    attributes[kSecAttrLabel as String] = "WakeOnCue 声纹"
    SecItemAdd(attributes as CFDictionary, nil)
  }
}

/// Who is speaking, from the voice. With the user's voiceprint, the microphone tells "我" from
/// "他人" by voice instead of by loudness. Others can be told apart as 说话人 1, 2… (nothing
/// kept) or, when the user turns on 记住声音 and names someone, recognized by name later.
/// Voiceprints live only in the keychain; one not heard for a year is deleted.
@Observable
final class Voices {
  private static let logger = Logger(subsystem: "com.deoooo.WakeOnCue.macos", category: "Voices")

  /// Cosine similarity needed to call a voice the user's, a remembered person's, or the same
  /// unnamed speaker as before. Checked against real recordings; see `calibrate`.
  static var meThreshold: Float { VoiceReference.meThreshold }
  static var personThreshold: Float = 0.55
  static var clusterThreshold: Float = 0.6
  /// Wait this long after a sentence ends, so its audio is on disk.
  private static let settle: TimeInterval = 8

  /// sherpa-onnx's 3D-Speaker CAM++ model for Chinese and English, from its official release.
  nonisolated static let model = ReleaseFile(
    url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")!,
    bytes: 28_281_164,
    sha256: "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2",
    folder: "speaker-models")

  nonisolated static var modelFile: URL {
    ASRModels.directory.appending(path: model.folder).appending(path: model.url.lastPathComponent)
  }

  enum ModelState: Equatable {
    case missing
    case downloading
    case ready
    case failed(String)
  }

  enum Enrollment: Equatable {
    case idle
    case listening(since: Date)
    case failed(String)
  }

  private(set) var modelState: ModelState = FileManager.default.fileExists(atPath: Voices.modelFile.path) ? .ready : .missing
  private(set) var enrollment: Enrollment = .idle
  private(set) var myVoice: [Float]? = VoiceprintKeychain.read("me", as: [Float].self)
  /// `myVoice` moved toward how this Mac's microphone hears the user; see `VoiceReference.adapted`.
  private(set) var myVoiceAdapted: [Float]? = VoiceprintKeychain.read("me-adapted", as: [Float].self)
  /// The user's voice learned from online meetings, when they have not enrolled.
  private(set) var learnedVoice: LearnedVoice? = VoiceprintKeychain.read("me-learned", as: LearnedVoice.self)
  /// Re-checking the last days' sentences after the user's voice became known.
  private(set) var isRecheckingPast = false
  private(set) var people: [Voiceprint] = VoiceprintKeychain.read("people", as: [Voiceprint].self) ?? []
  /// After enrolling: how recent microphone sentences compare with the user's voice.
  private(set) var calibration: String?

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private let models: ASRModels
  @ObservationIgnored private let recorder: Recorder
  @ObservationIgnored private var embedder: SpeakerEmbedder?
  @ObservationIgnored private var queue: [(sentence: Sentence, duringMeeting: Bool)] = []
  /// Hours whose speakers changed; the summaries of these hours are redone.
  @ObservationIgnored var onSpeakersChanged: (([Date]) -> Void)?
  @ObservationIgnored private var running = false
  /// Unnamed speakers heard today, by label, for 区分说话人.
  @ObservationIgnored private var clusters: [(day: Date, label: String, embedding: [Float], count: Int)] = []
  @ObservationIgnored private var enrollmentAudio: EnrollmentBuffer?

  init(store: Store, preferences: Preferences, models: ASRModels, recorder: Recorder) {
    self.store = store
    self.preferences = preferences
    self.models = models
    self.recorder = recorder
  }

  /// What the user's voice is compared with: the enrolled voice (adapted when possible), else
  /// the voice learned from online meetings once there is enough of it.
  var reference: [Float]? {
    if let myVoiceAdapted, myVoice != nil { return myVoiceAdapted }
    if let myVoice { return myVoice }
    if let learnedVoice, learnedVoice.isUsable { return learnedVoice.embedding }
    return nil
  }

  /// "我" means the user's voice, not just whatever the microphone heard.
  var knowsMyVoice: Bool { reference != nil }

  /// Learning from online meetings needs the voice model already on this Mac; it is never
  /// downloaded just for that.
  private var canLearn: Bool { myVoice == nil && modelState == .ready }

  /// Anything to do with voices at all.
  var isActive: Bool {
    reference != nil || canLearn || preferences.splitSpeakers || (preferences.rememberVoices && !people.isEmpty)
  }

  // MARK: Model

  /// Downloads the voice model (and the shared runtime) from the official releases.
  func prepareModel() async -> Bool {
    if modelState == .ready { return loadEmbedder() }
    guard modelState != .downloading else { return false }
    modelState = .downloading
    do {
      try await models.ensureRuntime()
      let downloader = Downloader(url: Self.model.url, resumeData: nil)
      guard case .finished(let location) = await downloader.run() else { throw downloader.error ?? URLError(.cannotLoadFromNetwork) }
      guard try ASRModels.sha256(of: location) == Self.model.sha256 else {
        try? FileManager.default.removeItem(at: location)
        throw URLError(.cannotDecodeContentData)
      }
      try FileManager.default.createDirectory(at: Self.modelFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: Self.modelFile)
      try FileManager.default.moveItem(at: location, to: Self.modelFile)
      modelState = .ready
    } catch {
      modelState = .failed("声纹模型下载失败：\(error.localizedDescription)")
      return false
    }
    return loadEmbedder()
  }

  @discardableResult
  private func loadEmbedder() -> Bool {
    if embedder != nil { return true }
    do {
      embedder = try SpeakerEmbedder(runtime: ASRModels.runtimeFolder, model: Self.modelFile)
      return true
    } catch {
      modelState = .failed(error.localizedDescription)
      return false
    }
  }

  // MARK: My voice

  /// "开始朗读": keeps the next microphone audio in memory, nowhere else.
  func startEnrollment() async {
    guard await prepareModel() else { return }
    guard recorder.isRecording else {
      enrollment = .failed("录音暂停时没法录入，请先继续录音")
      return
    }
    let buffer = EnrollmentBuffer()
    enrollmentAudio = buffer
    recorder.audioOut.setTap { channel, timed in
      guard channel == .microphone else { return }
      buffer.append(timed)
    }
    enrollment = .listening(since: .now)
  }

  /// "完成": averages 3-second windows of the reading into the user's voiceprint, then forgets the audio.
  func finishEnrollment() {
    recorder.audioOut.setTap(nil)
    let samples = enrollmentAudio?.take() ?? []
    enrollmentAudio = nil
    guard Double(samples.count) / 16_000 >= 10 else {
      enrollment = .failed("读的时间太短了，请读满 10 秒以上")
      return
    }
    guard let embedder else { return }
    let window = 3 * 16_000
    var vectors: [[Float]] = []
    var start = 0
    while start + window <= samples.count {
      if let vector = embedder.embedding(Array(samples[start..<(start + window)])) { vectors.append(vector) }
      start += window / 2
    }
    guard let voice = SpeakerEmbedder.mean(vectors) else {
      enrollment = .failed("没能从录音里提取声纹，请在安静的地方再试一次")
      return
    }
    myVoice = voice
    VoiceprintKeychain.write(voice, "me")
    myVoiceAdapted = nil
    VoiceprintKeychain.write([Float]?.none, "me-adapted")
    enrollment = .idle
    Task {
      await recheckPast(adapting: true)
      await calibrate()
    }
  }

  private func recentMicrophoneSentences(days: Double, limit: Int) -> [Sentence] {
    let interval = DateInterval(start: .now.addingTimeInterval(-days * 86_400), end: .now)
    return Array(store.sentences(in: interval)
      .filter { $0.channel == .microphone && $0.end.timeIntervalSince($0.start) >= VoiceReference.minimumSeconds }
      .suffix(limit))
  }

  /// Once the user's voice is known, checks the last week's microphone sentences again, so the
  /// summaries stop treating everyone in the room as the user. After enrolling, the voice is first
  /// adapted to these sentences. Changed hours are summarized again.
  func recheckPast(days: Double = 7, adapting: Bool = false) async {
    guard reference != nil, !isRecheckingPast, await prepareModel() else { return }
    isRecheckingPast = true
    defer { isRecheckingPast = false }
    let interval = DateInterval(start: .now.addingTimeInterval(-days * 86_400), end: .now.addingTimeInterval(-Self.settle))
    let sentences = store.sentences(in: interval).filter { $0.channel == .microphone }
    var embeddings: [Int64: [Float]] = [:]
    for sentence in sentences {
      if let embedding = await embedding(of: sentence) { embeddings[sentence.id] = embedding }
    }
    if adapting, let myVoice {
      let candidates = sentences
        .filter { $0.end.timeIntervalSince($0.start) >= VoiceReference.minimumSeconds }
        .compactMap { embeddings[$0.id] }
      if let adapted = VoiceReference.adapted(myVoice, with: candidates) {
        myVoiceAdapted = adapted
        VoiceprintKeychain.write(adapted, "me-adapted")
        Self.logger.notice("Adapted the enrolled voice to \(candidates.count) sentences")
      } else {
        Self.logger.notice("Adapting: too few of \(candidates.count) sentences close to the enrolled voice")
      }
    }
    var changed = Set<Date>()
    for sentence in sentences {
      guard let embedding = embeddings[sentence.id] else { continue }
      if classify(sentence, embedding: embedding, duringMeeting: false) { changed.insert(Calendar.current.hourStart(sentence.start)) }
    }
    Self.logger.notice("Rechecked \(sentences.count) sentences, speakers changed in \(changed.count) hours")
    if !changed.isEmpty { onSpeakersChanged?(changed.sorted()) }
  }

  /// Compares the last 200 microphone sentences of two seconds or more with the user's voice,
  /// logs the spread, and says how many would count as "我" at the current threshold.
  func calibrate() async {
    guard myVoice != nil, let reference, await prepareModel() else { return }
    calibration = "正在用最近的录音检查…"
    var similarities: [Float] = []
    for sentence in recentMicrophoneSentences(days: 2, limit: 200) {
      if let embedding = await embedding(of: sentence) { similarities.append(VoiceReference.similarity(embedding, reference)) }
    }
    guard !similarities.isEmpty else {
      calibration = nil
      return
    }
    var buckets = [Int](repeating: 0, count: 10)
    for value in similarities { buckets[min(9, max(0, Int(value * 10)))] += 1 }
    let mine = similarities.filter { $0 >= Self.meThreshold }.count
    Self.logger.notice("Calibration: \(similarities.count) sentences, buckets \(buckets, privacy: .public), me at \(Self.meThreshold): \(mine)")
    calibration = "最近 \(similarities.count) 句里，约 \(mine * 100 / similarities.count)% 认成了你的声音，其余算作他人。"
  }

  func cancelEnrollment() {
    recorder.audioOut.setTap(nil)
    enrollmentAudio = nil
    enrollment = .idle
  }

  func forgetMyVoice() {
    myVoice = nil
    myVoiceAdapted = nil
    VoiceprintKeychain.write([Float]?.none, "me")
    VoiceprintKeychain.write([Float]?.none, "me-adapted")
  }

  /// Forgets the voice learned from online meetings, e.g. when it learned someone else.
  func forgetLearnedVoice() {
    learnedVoice = nil
    VoiceprintKeychain.write(LearnedVoice?.none, "me-learned")
  }

  // MARK: Remembered people

  /// Turning 记住声音 off deletes every voiceprint; names already in recordings stay.
  func setRemembering(_ on: Bool) {
    preferences.rememberVoices = on
    if !on {
      people = []
      VoiceprintKeychain.write([Voiceprint]?.none, "people")
    }
  }

  func forget(_ person: Voiceprint) {
    people.removeAll { $0.id == person.id }
    savePeople()
  }

  /// Removes voices not heard for a year.
  func cleanUp() {
    let cutoff = Date().addingTimeInterval(-365 * 86_400)
    guard people.contains(where: { $0.lastHeard < cutoff }) else { return }
    people.removeAll { $0.lastHeard < cutoff }
    savePeople()
  }

  private func savePeople() {
    VoiceprintKeychain.write(people, "people")
  }

  /// "这是谁…": names this sentence's speaker. An unnamed 说话人 N is renamed across the day,
  /// and with 记住声音 on, the voice is remembered for later recordings.
  func name(_ sentence: Sentence, as name: String) async {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let day = Calendar.current.dateInterval(of: .day, for: sentence.start)!
    if let old = sentence.speakerName, old.hasPrefix("说话人 ") {
      store.renameSpeaker(old, to: name, in: day)
      for index in clusters.indices where clusters[index].label == old && clusters[index].day == day.start {
        clusters[index].label = name
      }
    } else {
      store.setSpeaker(id: sentence.id, speaker: sentence.speaker == .me ? .other : sentence.speaker, name: name)
    }
    guard preferences.rememberVoices, await prepareModel(), let embedding = await embedding(of: sentence) else { return }
    if let index = people.firstIndex(where: { $0.name == name }) {
      let person = people[index]
      people[index].embedding = SpeakerEmbedder.normalized(zip(person.embedding, embedding).map {
        ($0.0 * Float(person.samples) + $0.1) / Float(person.samples + 1)
      })
      people[index].samples += 1
      people[index].lastHeard = .now
    } else {
      people.append(Voiceprint(name: name, embedding: embedding, samples: 1, lastHeard: .now))
    }
    savePeople()
  }

  // MARK: Recognition

  /// A new microphone sentence; its speaker is checked once its audio is on disk.
  func enqueue(_ sentence: Sentence) {
    guard sentence.channel == .microphone, isActive else { return }
    // Whether a meeting app was playing right now; by the time the audio is on disk it may not be.
    queue.append((sentence, !recorder.activeMeetingApps.isEmpty))
    guard !running else { return }
    running = true
    Task {
      while !queue.isEmpty {
        let next = queue.removeFirst()
        let wait = next.sentence.end.addingTimeInterval(Self.settle).timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        await identify(next.sentence, duringMeeting: next.duringMeeting)
      }
      running = false
    }
  }

  private func embedding(of sentence: Sentence) async -> [Float]? {
    guard let embedder else { return nil }
    let segments = store.segments(overlapping: DateInterval(start: sentence.start, end: max(sentence.end, sentence.start)))
      .filter { $0.channel == sentence.channel }
    let start = sentence.start
    let end = sentence.end
    return await Task.detached(priority: .utility) {
      embedder.embedding(Refiner.samples(from: segments, start: start, end: end))
    }.value
  }

  /// Sets the sentence's speaker from its voice. Returns whether it changed.
  @discardableResult
  private func identify(_ sentence: Sentence, duringMeeting: Bool) async -> Bool {
    // A name the user gave stays; only 我 / 他人 / 说话人 N are worked out here.
    if let name = sentence.speakerName, !name.hasPrefix("说话人 ") { return false }
    // Learning alone never downloads the model.
    guard reference != nil || preferences.splitSpeakers || preferences.rememberVoices || modelState == .ready else { return false }
    guard await prepareModel(), let embedding = await embedding(of: sentence) else { return false }
    return classify(sentence, embedding: embedding, duringMeeting: duringMeeting)
  }

  private func classify(_ sentence: Sentence, embedding: [Float], duringMeeting: Bool) -> Bool {
    if let name = sentence.speakerName, !name.hasPrefix("说话人 ") { return false }
    let seconds = sentence.end.timeIntervalSince(sentence.start)
    if canLearn, duringMeeting, sentence.speaker == .me, seconds >= VoiceReference.minimumSeconds {
      learn(embedding, seconds: seconds)
    }
    if let reference {
      if VoiceReference.isMe(embedding, reference: reference) { return set(sentence, .me, nil) }
    } else if sentence.speaker == .me {
      // Without the user's voice, only the quieter voices already marked 他人 are looked at.
      return false
    }
    var name: String?
    if preferences.rememberVoices,
      let best = people.max(by: { SpeakerEmbedder.similarity(embedding, $0.embedding) < SpeakerEmbedder.similarity(embedding, $1.embedding) }),
      SpeakerEmbedder.similarity(embedding, best.embedding) >= Self.personThreshold
    {
      name = best.name
      if let index = people.firstIndex(of: best) {
        people[index].lastHeard = .now
        savePeople()
      }
    } else if preferences.splitSpeakers {
      name = cluster(embedding, day: Calendar.current.startOfDay(for: sentence.start))
    }
    return set(sentence, .other, name)
  }

  private func set(_ sentence: Sentence, _ speaker: Speaker, _ name: String?) -> Bool {
    guard sentence.speaker != speaker || sentence.speakerName != name else { return false }
    store.setSpeaker(id: sentence.id, speaker: speaker, name: name)
    return true
  }

  /// One more sentence of the user's voice from an online meeting. When there is first enough
  /// of it, the last week is checked again.
  private func learn(_ embedding: [Float], seconds: TimeInterval) {
    let wasUsable = learnedVoice?.isUsable ?? false
    let voice = learnedVoice?.adding(embedding, seconds: seconds) ?? .first(embedding, seconds: seconds)
    learnedVoice = voice
    if voice.sentences % 5 == 0 || voice.isUsable != wasUsable { VoiceprintKeychain.write(voice, "me-learned") }
    if voice.isUsable, !wasUsable {
      Self.logger.notice("Learned the user's voice from \(voice.sentences) meeting sentences")
      Task { await recheckPast() }
    }
  }

  /// The day's unnamed speaker this voice belongs to, or a new 说话人 N.
  private func cluster(_ embedding: [Float], day: Date) -> String {
    clusters.removeAll { $0.day < day.addingTimeInterval(-86_400) }
    let today = clusters.indices.filter { clusters[$0].day == day }
    if let best = today.max(by: { SpeakerEmbedder.similarity(embedding, clusters[$0].embedding) < SpeakerEmbedder.similarity(embedding, clusters[$1].embedding) }),
      SpeakerEmbedder.similarity(embedding, clusters[best].embedding) >= Self.clusterThreshold
    {
      let count = clusters[best].count
      clusters[best].embedding = SpeakerEmbedder.normalized(zip(clusters[best].embedding, embedding).map { ($0.0 * Float(count) + $0.1) / Float(count + 1) })
      clusters[best].count += 1
      return clusters[best].label
    }
    // 说话人 1 is the user, so others start at 2.
    let label = "说话人 \(today.count + 2)"
    clusters.append((day, label, embedding, 1))
    return label
  }
}

/// Microphone audio kept in memory while the user reads for their voiceprint.
nonisolated final class EnrollmentBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [Float] = []

  func append(_ timed: TimedBuffer) {
    guard let data = timed.buffer.floatChannelData?[0] else { return }
    let chunk = Array(UnsafeBufferPointer(start: data, count: Int(timed.buffer.frameLength)))
    lock.withLock { if samples.count < 16_000 * 60 { samples += chunk } }
  }

  func take() -> [Float] {
    lock.withLock {
      defer { samples = [] }
      return samples
    }
  }
}
