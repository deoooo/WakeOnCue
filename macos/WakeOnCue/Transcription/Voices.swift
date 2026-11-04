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
  static var meThreshold: Float = 0.5
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
  private(set) var people: [Voiceprint] = VoiceprintKeychain.read("people", as: [Voiceprint].self) ?? []
  /// After enrolling: how recent microphone sentences compare with the user's voice.
  private(set) var calibration: String?

  @ObservationIgnored private let store: Store
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private let models: ASRModels
  @ObservationIgnored private let recorder: Recorder
  @ObservationIgnored private var embedder: SpeakerEmbedder?
  @ObservationIgnored private var queue: [Sentence] = []
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

  /// Anything to do with voices at all.
  var isActive: Bool { myVoice != nil || preferences.splitSpeakers || (preferences.rememberVoices && !people.isEmpty) }

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
    enrollment = .idle
    Task { await calibrate() }
  }

  /// Compares the last 200 microphone sentences of two seconds or more with the user's voice,
  /// logs the spread, and says how many would count as "我" at the current threshold.
  func calibrate() async {
    guard let myVoice, await prepareModel() else { return }
    calibration = "正在用最近的录音检查…"
    let interval = DateInterval(start: .now.addingTimeInterval(-2 * 86_400), end: .now)
    let recent = store.sentences(in: interval).filter { $0.channel == .microphone && $0.end.timeIntervalSince($0.start) >= 2 }.suffix(200)
    var similarities: [Float] = []
    for sentence in recent {
      if let embedding = await embedding(of: sentence) { similarities.append(SpeakerEmbedder.similarity(embedding, myVoice)) }
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
    VoiceprintKeychain.write([Float]?.none, "me")
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
    queue.append(sentence)
    guard !running else { return }
    running = true
    Task {
      while !queue.isEmpty {
        let next = queue.removeFirst()
        let wait = next.end.addingTimeInterval(Self.settle).timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        await identify(next)
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

  private func identify(_ sentence: Sentence) async {
    guard await prepareModel(), let embedding = await embedding(of: sentence) else { return }
    if let myVoice {
      let mine = SpeakerEmbedder.similarity(embedding, myVoice)
      if mine >= Self.meThreshold {
        if sentence.speaker != .me || sentence.speakerName != nil { store.setSpeaker(id: sentence.id, speaker: .me, name: nil) }
        return
      }
    } else if sentence.speaker == .me {
      // Without the user's voiceprint, only the quieter voices already marked 他人 are looked at.
      return
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
    store.setSpeaker(id: sentence.id, speaker: .other, name: name)
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
