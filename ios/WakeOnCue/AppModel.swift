import AVFoundation
import Foundation
import Observation
import UIKit
import WakeOnCueCore
import WidgetKit

/// The transcription and summary services that recordings are sent to.
@MainActor
struct RecordingProcessingServices {
  var canTranscribe: () -> Bool
  var transcribe: (_ audioURL: URL, _ recordingID: String) async throws -> [RealtimeTranscriptEvent]
  var supportsSpokenLanguage: () async -> Bool = { true }
  var canSummarize: () -> Bool
  var summarize: (_ transcript: [RealtimeTranscriptEvent], _ title: String?) async throws
    -> RecordingSummary

  /// Uses the services the user configured in Settings, otherwise Apple's on-device frameworks.
  static func configured(by settings: AppSettings) -> RecordingProcessingServices {
    RecordingProcessingServices(
      canTranscribe: { settings.activeSpeechEndpoint != nil || OnDeviceIntelligence.canTranscribe },
      transcribe: { audioURL, recordingID in
        if let endpoint = settings.activeSpeechEndpoint {
          return try await ThirdPartyTranscriber.transcribe(
            audioURL: audioURL,
            recordingID: recordingID,
            language: settings.spokenLanguage.recognitionCode,
            endpoint: endpoint
          )
        }
        return try await OnDeviceIntelligence.transcribe(
          audioURL: audioURL,
          recordingID: recordingID,
          spokenLanguage: settings.spokenLanguage
        )
      },
      supportsSpokenLanguage: {
        guard settings.activeSpeechEndpoint == nil else { return true }
        return await OnDeviceIntelligence.supports(spokenLanguage: settings.spokenLanguage)
      },
      canSummarize: {
        settings.activeLanguageModelProvider != nil || OnDeviceIntelligence.canSummarize
      },
      summarize: { transcript, title in
        if let provider = settings.activeLanguageModelProvider {
          return try await ThirdPartyIntelligence.summarize(
            transcript,
            title: title,
            language: AppLanguage.current,
            provider: provider
          )
        }
        return try await OnDeviceIntelligence.summarize(
          transcript,
          title: title,
          language: AppLanguage.current
        )
      }
    )
  }
}

@MainActor
@Observable
final class AppModel {
  private(set) var currentRecording: RecordingRecord?
  /// Forwards Watch and iPhone audio to the paired Mac.
  let macUploader = MacUploader()
  private(set) var lastFinishedRecording: RecordingRecord?
  private(set) var recentRecordings: [RecordingRecord] = []
  private(set) var currentSyncProgress = RecordingSyncProgress()
  private(set) var recentSyncProgress: [String: RecordingSyncProgress] = [:]
  private(set) var elapsed: TimeInterval = 0
  private(set) var microphonePermission = AVAudioApplication.shared.recordPermission
  private(set) var captureFeedback = RecordingCaptureFeedback.idle
  private(set) var isBusy = false
  private(set) var isSavingSettings = false
  private(set) var settingsStatusMessage: String?
  private(set) var settingsStatusIsError = false
  /// Recordings whose audio is being prepared, played, shared or transcribed, with how many
  /// such jobs each has; several can overlap.
  private var audioJobs: [String: Int] = [:]

  func isAudioBusy(_ recordingID: String) -> Bool { audioJobs[recordingID] != nil }

  private func beginAudioJob(_ recordingID: String) { audioJobs[recordingID, default: 0] += 1 }

  private func endAudioJob(_ recordingID: String) {
    guard let count = audioJobs[recordingID] else { return }
    audioJobs[recordingID] = count > 1 ? count - 1 : nil
  }
  private(set) var playingRecordingID: String?
  private(set) var playbackIsPlaying = false
  private(set) var playbackPosition: TimeInterval = 0
  private(set) var playbackDuration: TimeInterval = 0
  private(set) var retranscribingRecordingID: String?
  private(set) var retranscriptionProgress = 0.0
  private(set) var retranscriptionStatusMessage: String?
  private(set) var transcriptVersion = 0
  /// Recordings being transcribed or summarized on this iPhone.
  private(set) var onDeviceProcessingRecordingIDs: Set<String> = []
  /// Changes when recordings leave or return to the library, or their titles change.
  private(set) var libraryVersion = 0
  var errorMessage: String?
  var settingsPresented = false
  var shareItem: RecordingShareItem?

  let settings: AppSettings
  let places = PlaceAutomation()
  let meetings = CalendarAutomation()
  @ObservationIgnored var processingServices: RecordingProcessingServices

  @ObservationIgnored private let fileLayout: RecordingFileLayout
  @ObservationIgnored private let store: RecordingStore
  @ObservationIgnored private let library: RecordingLibraryService
  @ObservationIgnored private let liveActivity = RecordingLiveActivityController()
  @ObservationIgnored private var capture: AudioCaptureService?
  /// Changes when recording controls change `currentRecording`, so a refresh that read the store
  /// before then does not put the old state back.
  @ObservationIgnored private var recordingLifecycleRevision = 0
  @ObservationIgnored private var chunkConsumer: Task<Void, Never>?
  @ObservationIgnored private var timerTask: Task<Void, Never>?
  @ObservationIgnored private var commandObserver: RecordingCommandObserver?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var tickCount = 0
  @ObservationIgnored private var audioPlayer: AVAudioPlayer?
  @ObservationIgnored private var playbackMonitor: Task<Void, Never>?
  /// Work that sends or writes a recording's content, so deleting the recording can stop it.
  @ObservationIgnored private var processingTasks: [String: Set<Task<Void, Error>>] = [:]

  var canTranscribeRecordings: Bool {
    processingServices.canTranscribe()
  }

  var canSummarizeRecordings: Bool {
    processingServices.canSummarize()
  }

  init() throws {
    let fileLayout = try RecordingFileLayout()
    let settings = AppSettings()
    self.fileLayout = fileLayout
    self.settings = settings
    processingServices = .configured(by: settings)
    let store = try RecordingStore(databaseURL: fileLayout.databaseURL)
    self.store = store
    library = RecordingLibraryService(layout: fileLayout, store: store)
    // Recently Deleted and permanently deleted recordings never go to the Mac.
    macUploader.disposition = { [library] recordingID in
      await library.macForwardingDisposition(recordingID: recordingID)
    }
    RecordingIntentDispatcher.shared.install { [weak self] command in
      guard let self else { return }
      await self.start()
      await self.handle(command: command)
    }
    PhoneWatchBridge.shared.install(
      requestHandler: { [weak self] request in
        guard let self else { return WatchBridgeReply(failure: .failed("iPhone app is closing")) }
        return await self.handle(watchRequest: request)
      },
      inboxHandler: { [weak self] in
        guard let self else { return }
        await self.start()
        await self.importWatchRecordings()
      }
    )
    PhoneWatchBridge.shared.activate()
    places.onTrigger = { [weak self] action, place, arrived in
      await self?.handlePlace(action, at: place, arrived: arrived)
    }
    places.onStartRequested = { [weak self] in
      guard let self else { return }
      await self.start()
      if self.currentRecording == nil { await self.startRecording() }
    }
    places.start()
    meetings.onStartRequested = places.onStartRequested
    meetings.start()
  }

  private func handlePlace(
    _ action: PlaceTriggerAction, at place: RecordingPlace, arrived: Bool
  ) async {
    await start()
    switch action {
    case .none:
      return
    case .start:
      guard currentRecording == nil else { return }
      if UIApplication.shared.applicationState == .active {
        await startRecording()
      } else {
        await places.postStartPrompt(for: place)
      }
    case .finish:
      guard currentRecording != nil else { return }
      await finishRecording()
      await places.postFinishedNotice(for: place, arrived: arrived)
    }
  }

  static func bootstrap() -> AppModel {
    do {
      return try AppModel()
    } catch {
      fatalError("WakeOnCue cannot initialize reliable local storage: \(error)")
    }
  }

  func start() async {
    guard !started else {
      await processPendingCommand()
      return
    }
    started = true
    commandObserver = RecordingCommandObserver { [weak self] in
      Task { @MainActor in await self?.processPendingCommand() }
    }
    do {
      try await store.rebaseLocalFilePaths(to: fileLayout.root)
      await Self.cancelRetiredBackgroundUploads()
      let interrupted = try await store.recoverAfterProcessTermination()
      let recovery = RecordingRecoveryService(fileLayout: fileLayout)
      let prepareAudio: @Sendable (String) async -> Void = { [weak self] recordingID in
        _ = try? await self?.prepareM4A(recordingID: recordingID)
      }
      let interruptedOutcome = await recovery.finishInterrupted(
        interrupted, store: store, prepareAudio: prepareAudio)
      for recording in interruptedOutcome.finished where recording.status == .completed {
        rememberLastFinished(recording)
      }
      let retiredOutcome = await recovery.finishRetiredUploads(
        store: store, prepareAudio: prepareAudio)
      if let failure = interruptedOutcome.firstError ?? retiredOutcome.firstError {
        errorMessage = String(format: AppLanguage.localized("Recovery failed: %@"), failure)
      }
      await importWatchRecordings()
      await refresh()
      await liveActivity.removeStaleActivities(activeRecordingID: currentRecording?.id)
    } catch {
      errorMessage = String(
        format: AppLanguage.localized("Recovery failed: %@"), error.localizedDescription)
    }
    startTimer()
    await processPendingCommand()
    // Callers of `start` often have a command of their own, such as a shortcut starting a recording.
    Task { [weak self] in await self?.runLibraryUpkeep() }
  }

  /// Never holds up a command, because starting a recording comes first. All of it runs again
  /// on the next launch, so a failure here need not interrupt opening the app.
  private func runLibraryUpkeep() async {
    try? await library.removeFilesOfDeletedRecordings()
    for recordingID in (try? await library.purgeExpiredRecordings()) ?? [] {
      RecordingAnnotationsService.shared.removeCachedAnnotations(recordingID: recordingID)
    }
    try? await library.backfillSummaryDetails()
    await refresh()
    libraryVersion += 1
  }

  func requestMicrophonePermission() async -> Bool {
    let granted = await AVAudioApplication.requestRecordPermission()
    microphonePermission = AVAudioApplication.shared.recordPermission
    return granted
  }

  func startRecording() async {
    guard currentRecording == nil, !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    var startupStage = "requesting microphone permission"
    do {
      guard await requestMicrophonePermission() else {
        throw RecordingUIError.microphoneDenied
      }
      startupStage = "preparing local recording files"
      let now = Date()
      let recordingID =
        "rec_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
      let sourceURL = try fileLayout.sourceAudioURL(recordingID: recordingID)
      let recording = RecordingRecord(
        id: recordingID,
        createdAt: now,
        startedAt: now,
        status: .recording,
        localAudioPath: sourceURL.path,
        uploadStatus: .pending,
        deviceModel: DeviceInformation.modelIdentifier,
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
          as? String ?? "unknown",
        metadata: [:]
      )
      let payloadURL = try fileLayout.createPayload(recording: recording)
      let capture = AudioCaptureService(
        recordingID: recordingID,
        fileLayout: fileLayout,
        testFixtureURL: Self.debugAudioFixtureURL
      )
      if playingRecordingID != nil { stopPlayback() }
      self.capture = capture
      configure(capture)
      startupStage = "starting the iPhone audio session"
      do {
        try await capture.start()
        startupStage = "saving the recording session"
        try await store.createRecording(
          recording,
          createPayloadPath: payloadURL.path,
          enqueueUpload: false
        )
      } catch {
        try? await capture.stop()
        self.capture = nil
        throw error
      }
      startupStage = "publishing the recording state"
      setCurrentRecording(recording)
      elapsed = 0
      consumeChunks(from: capture, recordingID: recordingID)
      publishSharedState(isRecording: true, isPaused: false, recordingID: recordingID)
      await liveActivity.start(recording: recording)
      let meetingMetadata = meetings.recordingMetadata(startingAt: now)
      if !meetingMetadata.isEmpty {
        _ = try? await store.updateRecordingMetadata(recordingID: recordingID, values: meetingMetadata)
      }
      await refresh()
      writeStartupDiagnostic("PASS | recording_id=\(recordingID)")
    } catch {
      publishSharedState(isRecording: false, isPaused: false, recordingID: nil)
      let detail = String(reflecting: error)
      writeStartupDiagnostic("FAIL | stage=\(startupStage) | error=\(detail)")
      errorMessage =
        String(
          format: AppLanguage.localized("Could not start recording: %@"),
          error.localizedDescription
        )
    }
  }

  private func writeStartupDiagnostic(_ message: String) {
    let url = fileLayout.root.appending(path: "last-recording-start.txt")
    let payload = "\(Date().ISO8601Format()) | \(message)\n"
    try? payload.write(to: url, atomically: true, encoding: .utf8)
    try? RecordingFileLayout.protect(url)
    print("WakeOnCue recording diagnostic: \(payload)")
  }

  func pauseRecording() async {
    guard let recording = currentRecording, recording.status == .recording,
      let capture, !isBusy
    else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await capture.pause()
      try await recordPause(recordingID: recording.id, duration: capture.duration)
      if var paused = currentRecording { paused.status = .paused; setCurrentRecording(paused) }
      PhoneWatchBridge.shared.publish(watchSnapshot())
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func resumeRecording() async {
    guard let recording = currentRecording, recording.status == .paused,
      let capture, !isBusy
    else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      try await capture.resume()
      try await recordResume(recordingID: recording.id, duration: capture.duration)
      if var resumed = currentRecording { resumed.status = .recording; setCurrentRecording(resumed) }
      PhoneWatchBridge.shared.publish(watchSnapshot())
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func finishRecording() async {
    guard let recording = currentRecording,
      [.recording, .paused].contains(recording.status),
      let capture, !isBusy
    else { return }
    isBusy = true
    // Stopping the audio session ends the app's background audio time.
    let backgroundTime = BackgroundTime.begin(name: "Finish \(recording.id)")
    defer {
      backgroundTime.end()
      isBusy = false
    }
    do {
      try await capture.stop()
      let duration = capture.duration
      await chunkConsumer?.value
      chunkConsumer = nil
      self.capture = nil
      captureFeedback = .idle
      if duration <= 0, try await store.chunks(recordingID: recording.id).isEmpty {
        try await discardEmptyRecording(recordingID: recording.id)
        return
      }
      try await store.transition(
        recordingID: recording.id,
        to: .finishing,
        duration: duration
      )
      var finishingRecording = try await store.recording(id: recording.id)
      finishingRecording.duration = duration
      setCurrentRecording(finishingRecording)
      elapsed = duration
      publishSharedState(isRecording: false, isPaused: false, recordingID: nil)
      await refresh()
      let shareableAudio = try await prepareM4A(recordingID: recording.id)
      try await store.completeLocally(recordingID: recording.id, duration: duration)
      queueForMac(recording: finishingRecording, audio: shareableAudio, duration: duration)
      let finishedRecording = try await store.recording(id: recording.id)
      rememberLastFinished(finishedRecording)
      setCurrentRecording(nil)
      currentSyncProgress = .init()
      elapsed = 0
      publishSharedState(isRecording: false, isPaused: false, recordingID: nil)
      let progress = try await syncProgress(for: finishedRecording)
      if finishedRecording.status == .completed {
        await liveActivity.end(
          recording: finishedRecording,
          progress: progress
        )
      } else {
        await liveActivity.update(
          recording: finishedRecording,
          progress: progress
        )
      }
      await refresh()
      Task { await self.processOnDevice(recording: finishedRecording, audioURL: shareableAudio) }
    } catch {
      if self.capture == nil {
        await refresh()
        if var stranded = currentRecording,
          [.recording, .paused].contains(stranded.status)
        {
          stranded.status = .finishing
          setCurrentRecording(stranded)
        }
        publishSharedState(isRecording: false, isPaused: false, recordingID: nil)
      }
      errorMessage = error.localizedDescription
    }
  }

  func finishLocally() async {
    guard let recording = currentRecording ?? lastFinishedRecording,
      [.finishing, .uploading, .failed].contains(recording.status),
      !isBusy
    else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      if recording.duration <= 0, try await store.chunks(recordingID: recording.id).isEmpty {
        try await discardEmptyRecording(recordingID: recording.id)
        return
      }
      // Playing or sharing assembles the audio again, so a failure here must not trap the user
      // on the Finishing screen.
      _ = try? await prepareM4A(recordingID: recording.id)
      try await store.completeLocally(
        recordingID: recording.id,
        duration: recording.duration
      )
      let finishedRecording = try await store.recording(id: recording.id)
      rememberLastFinished(finishedRecording)
      if currentRecording?.id == recording.id { setCurrentRecording(nil) }
      currentSyncProgress = .init()
      elapsed = 0
      publishSharedState(isRecording: false, isPaused: false, recordingID: nil)
      await liveActivity.end(
        recording: finishedRecording,
        progress: try await syncProgress(for: finishedRecording)
      )
      await refresh()
    } catch {
      errorMessage = String(
        format: AppLanguage.localized("Could not finish locally: %@"),
        error.localizedDescription
      )
    }
  }

  /// A finished iPhone recording goes to the paired Mac as one piece.
  private func queueForMac(recording: RecordingRecord, audio: URL, duration: TimeInterval) {
    do {
      try MacOutbox.enqueue(
        file: audio, id: "iphone-\(recording.id)", source: "iphone", recordingID: recording.id, index: 1,
        startedAt: recording.startedAt, duration: duration)
      // Its bookmarks, including "记下刚才" from the Watch, go along at their real times.
      try MacOutbox.enqueue(marks: MacOutbox.marks(
        of: RecordingAnnotationsService.shared.annotations(for: recording.id).bookmarks,
        recordingID: recording.id, startedAt: recording.startedAt))
    } catch {
      errorMessage = error.localizedDescription
    }
    Task { await macUploader.sync() }
  }

  /// Finished before any audio arrived, so there is nothing to keep or to play.
  private func discardEmptyRecording(recordingID: String) async throws {
    try await store.completeLocally(recordingID: recordingID, duration: 0)
    try await library.moveToTrash(recordingID: recordingID)
    try await library.deletePermanently(recordingID: recordingID)
    setCurrentRecording(nil)
    currentSyncProgress = .init()
    elapsed = 0
    publishSharedState(isRecording: false, isPaused: false, recordingID: nil)
    await liveActivity.removeStaleActivities(activeRecordingID: nil)
    await refresh()
    libraryVersion += 1
    errorMessage = AppLanguage.localized("The recording was too short to save.")
  }

  private func setCurrentRecording(_ recording: RecordingRecord?) {
    recordingLifecycleRevision += 1
    currentRecording = recording
  }

  func handle(url: URL) async {
    if url.scheme == "wakeoncue", url.host == "pair" {
      _ = macUploader.pair(with: url)
      return
    }
    guard url.scheme == "wakeoncue", url.host == "recording" else { return }
    switch url.path {
    case "/start": SharedRecordingState.enqueue(.start)
    case "/pause": SharedRecordingState.enqueue(.pause)
    case "/resume": SharedRecordingState.enqueue(.resume)
    case "/finish": SharedRecordingState.enqueue(.finish)
    default: break
    }
    await processPendingCommand()
  }

  func saveSettings() async {
    guard !isSavingSettings else { return }
    guard currentRecording == nil else {
      settingsStatusIsError = true
      settingsStatusMessage = String(
        localized: "Finish the current recording before changing settings.")
      return
    }
    isSavingSettings = true
    settingsStatusIsError = false
    settingsStatusMessage = AppLanguage.localized("Testing configured services…")
    defer { isSavingSettings = false }
    do {
      // Saves exactly what was checked, whatever happens to the form during the checks.
      let draft = settings.aiProviderDraft
      let speechEndpoint = try settings.candidateSpeechEndpoint()
      let languageModelProvider = try settings.candidateLanguageModelProvider()

      // Checks cost the user a small API call, so unchanged services are not checked again.
      if let speechEndpoint, speechEndpoint != settings.activeSpeechEndpoint {
        try await ThirdPartyTranscriber.verify(endpoint: speechEndpoint)
      }
      if let languageModelProvider, languageModelProvider != settings.activeLanguageModelProvider {
        try await ThirdPartyLanguageModel.verify(provider: languageModelProvider)
      }

      try settings.persistAIProviders(
        draft, speech: speechEndpoint, languageModel: languageModelProvider)
      await refresh()
      settingsStatusIsError = false
      settingsStatusMessage = AppLanguage.localized("Settings saved.")
      try? await Task.sleep(for: .milliseconds(500))
      settingsPresented = false
    } catch {
      settingsStatusIsError = true
      settingsStatusMessage = error.localizedDescription
    }
  }

  /// Recordings whose audio only exists in S3 can no longer be played after this.
  func forgetLegacyS3Storage() {
    do {
      try settings.forgetLegacyS3Storage()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func cancelSettings() {
    guard !isSavingSettings else { return }
    settings.restorePersistedSettings()
    settingsPresented = false
  }

  func togglePlayback(for recording: RecordingRecord) async {
    if playingRecordingID == recording.id, let audioPlayer {
      if audioPlayer.isPlaying {
        audioPlayer.pause()
        playbackIsPlaying = false
        playbackPosition = audioPlayer.currentTime
      } else {
        guard audioPlayer.play() else {
          errorMessage = String(
            format: AppLanguage.localized("Could not play this recording: %@"),
            RecordingUIError.playbackFailed.localizedDescription
          )
          return
        }
        playbackIsPlaying = true
        startPlaybackMonitor(for: audioPlayer)
      }
      return
    }
    await startPlayback(for: recording, at: 0)
  }

  func seekPlayback(
    for recording: RecordingRecord,
    to requestedTime: TimeInterval,
    autoplay: Bool = true
  ) async {
    if playingRecordingID != recording.id || audioPlayer == nil {
      await startPlayback(for: recording, at: requestedTime, autoplay: autoplay)
      return
    }
    guard let audioPlayer else { return }
    audioPlayer.currentTime = min(max(0, requestedTime), audioPlayer.duration)
    playbackPosition = audioPlayer.currentTime
    if autoplay, !audioPlayer.isPlaying {
      guard audioPlayer.play() else { return }
      playbackIsPlaying = true
      startPlaybackMonitor(for: audioPlayer)
    }
  }

  private func startPlayback(
    for recording: RecordingRecord,
    at requestedTime: TimeInterval,
    autoplay: Bool = true
  ) async {
    // Playback takes over the audio session, which would silently stop the recording.
    guard capture == nil else {
      errorMessage = AppLanguage.localized(
        "Finish the current recording before playing another one.")
      return
    }
    beginAudioJob(recording.id)
    defer { endAudioJob(recording.id) }
    do {
      let chunks = try await store.chunks(recordingID: recording.id)
      let file = try await RecordingAudioFileProvider(fileLayout: fileLayout).file(
        for: recording,
        chunks: chunks,
        s3Configuration: await s3Configuration(for: recording)
      )
      // Preparing can take a while, and a download can outlast the screen that asked for it.
      guard await !isRecordingDeleted(recording.id) else { return }
      guard capture == nil else { return }
      stopPlayback()
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
      let player = try AVAudioPlayer(contentsOf: file)
      player.prepareToPlay()
      player.currentTime = min(max(0, requestedTime), player.duration)
      if autoplay, !player.play() { throw RecordingUIError.playbackFailed }
      audioPlayer = player
      playingRecordingID = recording.id
      playbackDuration = player.duration
      playbackPosition = player.currentTime
      playbackIsPlaying = autoplay
      startPlaybackMonitor(for: player)
    } catch {
      errorMessage = String(
        format: AppLanguage.localized("Could not play this recording: %@"),
        error.localizedDescription
      )
    }
  }

  private func startPlaybackMonitor(for player: AVAudioPlayer) {
    playbackMonitor?.cancel()
    playbackMonitor = Task { @MainActor [weak self, weak player] in
      while !Task.isCancelled {
        guard let self, let player, self.audioPlayer === player else { return }
        self.playbackPosition = player.currentTime
        self.playbackDuration = player.duration
        self.playbackIsPlaying = player.isPlaying
        if !player.isPlaying, player.currentTime >= max(0, player.duration - 0.05) {
          self.stopPlayback()
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  func share(recording: RecordingRecord) async {
    beginAudioJob(recording.id)
    defer { endAudioJob(recording.id) }
    do {
      let chunks = try await store.chunks(recordingID: recording.id)
      let file = try await RecordingAudioFileProvider(fileLayout: fileLayout).file(
        for: recording,
        chunks: chunks,
        s3Configuration: await s3Configuration(for: recording)
      )
      guard await !isRecordingDeleted(recording.id) else { return }
      shareItem = RecordingShareItem(url: file)
    } catch {
      errorMessage = String(
        format: AppLanguage.localized("Could not prepare the recording file: %@"),
        error.localizedDescription
      )
    }
  }

  func transcript(for recordingID: String) async throws -> [RealtimeTranscriptEvent] {
    let url = try fileLayout.transcriptURL(recordingID: recordingID)
    if !FileManager.default.fileExists(atPath: url.path) {
      let recording = try await store.recording(id: recordingID)
      guard recording.uploadStatus == .completed,
        let configuration = await s3Configuration(for: recording)
      else { return [] }
      do {
        _ = try await S3StorageClient.downloadTranscript(
          recordingID: recordingID,
          configuration: configuration,
          destinationURL: url
        )
      } catch S3StorageError.notFound {
        return []
      }
    }
    let segments = try JSONDecoder().decode(
      [RealtimeTranscriptEvent].self,
      from: Data(contentsOf: url)
    )
    return segments.sorted {
      if $0.startMilliseconds == $1.startMilliseconds { return $0.id < $1.id }
      return $0.startMilliseconds < $1.startMilliseconds
    }
  }

  func retranscribe(recording: RecordingRecord) async {
    guard retranscribingRecordingID == nil else { return }
    guard canTranscribeRecordings else {
      errorMessage = AppLanguage.localized(
        "Transcription needs iOS 26 or later, or a transcription service in Settings."
      )
      return
    }
    retranscribingRecordingID = recording.id
    retranscriptionProgress = 0
    retranscriptionStatusMessage = AppLanguage.localized("Transcribing…")
    beginAudioJob(recording.id)
    defer {
      retranscribingRecordingID = nil
      retranscriptionStatusMessage = nil
      endAudioJob(recording.id)
    }
    do {
      try await runStoppableByDeletion(recordingID: recording.id) { [self] in
        try await stopIfDeleted(recordingID: recording.id)
        let file = try await RecordingAudioFileProvider(fileLayout: fileLayout).file(
          for: recording,
          chunks: try await store.chunks(recordingID: recording.id),
          s3Configuration: await s3Configuration(for: recording)
        )
        try await stopIfDeleted(recordingID: recording.id)
        let segments = try await processingServices.transcribe(file, recording.id)
        try await stopIfDeleted(recordingID: recording.id)
        guard !segments.isEmpty else { return }
        try writeTranscript(segments, recordingID: recording.id)
        retranscriptionProgress = 1
        transcriptVersion += 1
      }
    } catch {
      guard await !wasStoppedByDeletion(error, recordingID: recording.id) else { return }
      errorMessage = String(
        format: AppLanguage.localized("Could not retranscribe this recording: %@"),
        error.localizedDescription
      )
    }
  }

  private func runStoppableByDeletion(
    recordingID: String,
    operation: @escaping @MainActor () async throws -> Void
  ) async throws {
    let task = Task { @MainActor in try await operation() }
    processingTasks[recordingID, default: []].insert(task)
    defer {
      processingTasks[recordingID]?.remove(task)
      if processingTasks[recordingID]?.isEmpty == true { processingTasks[recordingID] = nil }
    }
    try await task.value
  }

  /// Checked before each step, because a service may not stop as soon as it is cancelled.
  private func stopIfDeleted(recordingID: String) async throws {
    try Task.checkCancellation()
    if await isRecordingDeleted(recordingID) { throw CancellationError() }
  }

  private func isRecordingDeleted(_ recordingID: String) async -> Bool {
    do {
      return try await store.recording(id: recordingID).isDeleted
    } catch RecordingStoreError.notFound {
      return (try? await store.wasPermanentlyDeleted(recordingID: recordingID)) == true
    } catch {
      return false
    }
  }

  /// Which of these recordings were deleted, so that an answer stops linking to them.
  func deletedRecordingIDs(among recordingIDs: Set<String>) async -> Set<String> {
    var deleted: Set<String> = []
    for recordingID in recordingIDs where await isRecordingDeleted(recordingID) {
      deleted.insert(recordingID)
    }
    return deleted
  }

  func transcriptionSupportsSpokenLanguage() async -> Bool {
    await processingServices.supportsSpokenLanguage()
  }

  /// The store's errors are in English. These can reach the user when a screen is out of date.
  private func deletionFailureReason(_ error: Error) -> String {
    switch error {
    case RecordingStoreError.recordingInProgress:
      AppLanguage.localized("This recording is still being recorded or finished.")
    case RecordingStoreError.notInRecentlyDeleted:
      AppLanguage.localized("This recording is no longer in Recently Deleted.")
    case RecordingStoreError.notFound:
      AppLanguage.localized("This recording no longer exists.")
    default:
      error.localizedDescription
    }
  }

  /// A cancelled service can report its own error, which the user should not see as a failure.
  private func wasStoppedByDeletion(_ error: Error, recordingID: String) async -> Bool {
    if error is CancellationError { return true }
    return await isRecordingDeleted(recordingID)
  }

  private func writeTranscript(_ segments: [RealtimeTranscriptEvent], recordingID: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let transcriptURL = try fileLayout.transcriptURL(recordingID: recordingID)
    try encoder.encode(segments).write(to: transcriptURL, options: [.atomic])
    try RecordingFileLayout.protect(transcriptURL)
  }

  private func stopPlayback() {
    playbackMonitor?.cancel()
    playbackMonitor = nil
    audioPlayer?.stop()
    audioPlayer = nil
    playingRecordingID = nil
    playbackIsPlaying = false
    playbackPosition = 0
    playbackDuration = 0
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  /// Moves a recording to Recently Deleted. Returns whether it moved.
  @discardableResult
  func moveToTrash(_ recording: RecordingRecord) async -> Bool {
    do {
      try await library.moveToTrash(recordingID: recording.id)
    } catch {
      errorMessage = String(
        format: AppLanguage.localized("Could not delete this recording: %@"),
        deletionFailureReason(error)
      )
      return false
    }
    for task in processingTasks[recording.id] ?? [] { task.cancel() }
    if playingRecordingID == recording.id { stopPlayback() }
    if lastFinishedRecording?.id == recording.id { lastFinishedRecording = nil }
    await refresh()
    libraryVersion += 1
    return true
  }

  func restore(_ recording: RecordingRecord) async {
    do {
      try await library.restore(recordingID: recording.id)
    } catch {
      errorMessage = deletionFailureReason(error)
    }
    await refresh()
    libraryVersion += 1
  }

  func deletedRecordings() async throws -> [RecordingRecord] {
    try await library.deletedRecordings()
  }

  func deletePermanently(_ recordings: [RecordingRecord]) async {
    var failure: String?
    for recording in recordings {
      // Processing and preparing audio write into the recording's folder, bringing it back.
      guard !onDeviceProcessingRecordingIDs.contains(recording.id),
        retranscribingRecordingID != recording.id,
        !isAudioBusy(recording.id)
      else {
        failure = AppLanguage.localized(
          "This recording is still being processed. Try again when it finishes.")
        continue
      }
      do {
        try await library.deletePermanently(recordingID: recording.id)
        RecordingAnnotationsService.shared.removeCachedAnnotations(recordingID: recording.id)
      } catch {
        failure = String(
          format: AppLanguage.localized("Could not delete this recording: %@"),
          deletionFailureReason(error)
        )
      }
    }
    if let failure { errorMessage = failure }
    libraryVersion += 1
  }

  func refresh() async {
    let revision = recordingLifecycleRevision
    do {
      if let currentID = currentRecording?.id,
        let stored = try? await store.recording(id: currentID)
      {
        guard revision == recordingLifecycleRevision else { return }
        var displayed = stored
        if let capture, [.recording, .paused].contains(stored.status) {
          displayed.duration = capture.duration
          elapsed = capture.duration
        } else {
          elapsed = stored.duration
        }
        if stored.status == .completed {
          rememberLastFinished(stored)
          currentRecording = nil
          currentSyncProgress = .init()
          elapsed = 0
          let progress = try await syncProgress(for: stored)
          await liveActivity.end(
            recording: stored,
            progress: progress
          )
        } else if [.uploading, .failed].contains(stored.status) {
          if stored.status == .uploading { rememberLastFinished(stored) }
          currentRecording = nil
          currentSyncProgress = .init()
          elapsed = 0
        } else if [.recording, .paused, .finishing].contains(stored.status) {
          currentRecording = displayed
          let progress = try await syncProgress(for: displayed)
          guard revision == recordingLifecycleRevision else { return }
          currentSyncProgress = progress
          await liveActivity.update(
            recording: displayed,
            progress: progress
          )
        }
      } else if capture == nil {
        let active = try await store.activeRecording()
        guard revision == recordingLifecycleRevision, capture == nil else { return }
        currentRecording = active
        elapsed = currentRecording?.duration ?? 0
        if let currentRecording {
          currentSyncProgress = try await syncProgress(for: currentRecording)
        } else {
          currentSyncProgress = .init()
        }
      }
      recentRecordings = try await store.recordings(limit: 20)
      if let lastFinishedID = lastFinishedRecording?.id,
        let refreshedLastFinished = recentRecordings.first(where: { $0.id == lastFinishedID })
      {
        lastFinishedRecording = refreshedLastFinished
      }
      var progressByRecording: [String: RecordingSyncProgress] = [:]
      for recording in recentRecordings {
        progressByRecording[recording.id] = try await syncProgress(for: recording)
      }
      recentSyncProgress = progressByRecording
      if let lastFinishedRecording,
        let progress = progressByRecording[lastFinishedRecording.id]
      {
        if lastFinishedRecording.status == .completed {
          await liveActivity.end(
            recording: lastFinishedRecording,
            progress: progress
          )
        } else {
          await liveActivity.update(
            recording: lastFinishedRecording,
            progress: progress
          )
        }
      }
      let isRecording =
        currentRecording.map {
          [.recording, .paused].contains($0.status)
        } ?? false
      publishSharedState(
        isRecording: isRecording,
        isPaused: currentRecording?.status == .paused,
        recordingID: isRecording ? currentRecording?.id : nil
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func processPendingCommand() async {
    guard let command = SharedRecordingState.consumePendingCommand() else { return }
    await handle(command: command)
  }

  private func syncProgress(for recording: RecordingRecord) async throws
    -> RecordingSyncProgress
  {
    let persisted = try await store.syncProgress(recordingID: recording.id)
    return persisted.includingUnindexedDuration(recording.duration)
  }

  private func rememberLastFinished(_ recording: RecordingRecord) {
    guard (lastFinishedRecording?.createdAt ?? .distantPast) <= recording.createdAt else { return }
    lastFinishedRecording = recording
  }

  /// A command from the Watch, a widget or Shortcuts can arrive while another is still running;
  /// waiting means Finish takes effect rather than being dropped.
  private func waitUntilNotBusy() async {
    while isBusy { try? await Task.sleep(for: .milliseconds(50)) }
  }

  private func handle(command: RecordingCommand) async {
    await waitUntilNotBusy()
    switch command {
    case .start: await startRecording()
    case .pause: await pauseRecording()
    case .resume: await resumeRecording()
    case .finish: await finishRecording()
    }
  }

  private func configure(_ capture: AudioCaptureService) {
    captureFeedback = .idle
    capture.onCaptureFeedback = { [weak self, weak capture] feedback in
      guard let self, let capture, self.capture === capture else { return }
      self.captureFeedback = feedback
    }
    capture.onCaptureError = { [weak self] error in
      Task { @MainActor in
        self?.errorMessage = String(
          format: AppLanguage.localized("Recording error: %@"),
          error.localizedDescription
        )
      }
    }
    capture.onInterruptionChanged = { [weak self] interrupted, resumed in
      Task { @MainActor in
        guard let self, let recordingID = self.currentRecording?.id,
          let capture = self.capture
        else { return }
        do {
          if interrupted {
            try await self.recordPause(recordingID: recordingID, duration: capture.duration)
          } else if resumed {
            try await self.recordResume(recordingID: recordingID, duration: capture.duration)
          }
        } catch {
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  private static var debugAudioFixtureURL: URL? {
    #if DEBUG
      guard
        let fileName = ProcessInfo.processInfo.environment[
          "WAKEONCUE_TEST_AUDIO_FIXTURE_FILENAME"
        ],
        !fileName.isEmpty,
        fileName == URL(filePath: fileName).lastPathComponent,
        let documents = FileManager.default.urls(
          for: .documentDirectory,
          in: .userDomainMask
        ).first
      else { return nil }
      let url = documents.appending(path: fileName)
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    #else
      return nil
    #endif
  }

  func summary(for recordingID: String) -> RecordingSummary? {
    guard let url = try? fileLayout.summaryURL(recordingID: recordingID),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(RecordingSummary.self, from: data)
  }

  /// Transcribes when no transcript exists, then writes a summary. Uses the services the
  /// user configured in Settings, otherwise Apple's on-device frameworks.
  /// `regenerateSummary` replaces an existing summary.
  func processOnDevice(
    recording: RecordingRecord,
    audioURL: URL? = nil,
    regenerateSummary: Bool = false
  ) async {
    guard !onDeviceProcessingRecordingIDs.contains(recording.id) else { return }
    onDeviceProcessingRecordingIDs.insert(recording.id)
    defer { onDeviceProcessingRecordingIDs.remove(recording.id) }
    do {
      try await runStoppableByDeletion(recordingID: recording.id) { [self] in
        try await stopIfDeleted(recordingID: recording.id)
        // A transcript that exists but cannot be read now must not be replaced.
        var segments = try await transcript(for: recording.id)
        if segments.isEmpty, canTranscribeRecordings {
          let file: URL
          if let audioURL {
            file = audioURL
          } else {
            file = try await RecordingAudioFileProvider(fileLayout: fileLayout).file(
              for: recording,
              chunks: try await store.chunks(recordingID: recording.id),
              s3Configuration: await s3Configuration(for: recording)
            )
          }
          try await stopIfDeleted(recordingID: recording.id)
          segments = try await processingServices.transcribe(file, recording.id)
          try await stopIfDeleted(recordingID: recording.id)
          guard !segments.isEmpty else { return }
          try writeTranscript(segments, recordingID: recording.id)
          transcriptVersion += 1
        }
        guard !segments.isEmpty, canSummarizeRecordings,
          regenerateSummary || summary(for: recording.id) == nil
        else { return }
        try await stopIfDeleted(recordingID: recording.id)
        let summary = try await processingServices.summarize(segments, recording.title)
        try await stopIfDeleted(recordingID: recording.id)
        let summaryURL = try fileLayout.summaryURL(recordingID: recording.id)
        try JSONEncoder().encode(summary).write(to: summaryURL, options: [.atomic])
        try RecordingFileLayout.protect(summaryURL)
        try await library.saveSummaryDetails(summary, recordingID: recording.id)
        await refresh()
        libraryVersion += 1
        transcriptVersion += 1
      }
    } catch {
      guard await !wasStoppedByDeletion(error, recordingID: recording.id) else { return }
      errorMessage = String(
        format: AppLanguage.localized("Could not process this recording: %@"),
        error.localizedDescription
      )
    }
  }

  private func consumeChunks(from capture: AudioCaptureService, recordingID: String) {
    chunkConsumer = Task { [weak self] in
      for await captured in capture.chunks {
        guard let self else { return }
        do {
          try await self.store.insertChunk(
            ChunkRecord(
              id: "\(recordingID)_\(String(format: "%06d", captured.index))",
              recordingID: recordingID,
              index: captured.index,
              localPath: captured.url.path,
              checksum: captured.checksum,
              size: captured.size,
              startedAt: captured.startedAt,
              duration: captured.duration
            ),
            enqueueUpload: false
          )
          await self.refresh()
        } catch {
          self.errorMessage =
            "Unable to queue chunk \(captured.index): \(error.localizedDescription)"
        }
      }
    }
  }

  private func recordPause(recordingID: String, duration: TimeInterval) async throws {
    try await store.transition(recordingID: recordingID, to: .paused, duration: duration)
    publishSharedState(isRecording: true, isPaused: true, recordingID: recordingID)
    await refresh()
  }

  private func recordResume(recordingID: String, duration: TimeInterval) async throws {
    try await store.transition(recordingID: recordingID, to: .recording, duration: duration)
    publishSharedState(isRecording: true, isPaused: false, recordingID: recordingID)
    await refresh()
  }

  private func prepareM4A(recordingID: String) async throws -> URL {
    let chunks = try await store.chunks(recordingID: recordingID)
    let url = try await RecordingAudioAssembler(fileLayout: fileLayout).assemble(
      recordingID: recordingID,
      chunks: chunks
    )
    // Opening the player reads the file, which is noticeable on the main thread.
    try await Task.detached(priority: .userInitiated) {
      let playbackProbe = try AVAudioPlayer(contentsOf: url)
      guard playbackProbe.prepareToPlay(), playbackProbe.duration > 0 else {
        throw RecordingUIError.playbackFailed
      }
    }.value
    return url
  }

  /// Uploads ended, but stops an older version's system-managed transfers still in flight.
  private static func cancelRetiredBackgroundUploads() async {
    let key = "recording-storage.background-uploads-retired"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    let session = URLSession(
      configuration: .background(withIdentifier: "com.deoooo.WakeOnCue.recording-uploads"))
    for task in await session.allTasks { task.cancel() }
    session.invalidateAndCancel()
    UserDefaults.standard.set(true, forKey: key)
  }

  /// Audio an older version already moved to S3 stays reachable; nothing new is uploaded.
  private func s3Configuration(for recording: RecordingRecord) async -> S3Configuration? {
    guard let configuration = settings.legacyS3Configuration,
      configuration.matchesRecordedLocation(recording.metadata),
      (try? await store.isBackedUpToS3(recordingID: recording.id)) == true
    else { return nil }
    return configuration
  }

  private func startTimer() {
    timerTask?.cancel()
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self else { return }
        if let capture = self.capture {
          self.elapsed = capture.duration
          self.currentSyncProgress = self.currentSyncProgress.includingUnindexedDuration(
            capture.duration
          )
          if var recording = self.currentRecording {
            recording.duration = capture.duration
            self.currentRecording = recording
          }
        }
        self.tickCount += 1
        if self.tickCount.isMultiple(of: 5) { await self.refresh() }
      }
    }
  }

  private func publishSharedState(
    isRecording: Bool,
    isPaused: Bool,
    recordingID: String?
  ) {
    PhoneWatchBridge.shared.publish(watchSnapshot())
    let snapshot = SharedRecordingState.snapshot()
    guard
      snapshot.isRecording != isRecording || snapshot.isPaused != isPaused
        || snapshot.recordingID != recordingID
    else { return }
    SharedRecordingState.update(
      isRecording: isRecording,
      isPaused: isPaused,
      recordingID: recordingID
    )
    ControlCenter.shared.reloadControls(ofKind: SharedRecordingState.controlKind)
  }
}

// MARK: - Apple Watch

extension AppModel {
  static let watchRecentMarkLimit: TimeInterval = 10 * 60

  func watchSnapshot(now: Date = Date()) -> WatchRecordingSnapshot {
    let phase: WatchRecordingPhase
    switch currentRecording?.status {
    case .recording: phase = .recording
    case .paused: phase = .paused
    case .finishing: phase = .finishing
    default: phase = .idle
    }
    let calendar = Calendar.current
    let todayCompleted = recentRecordings
      .filter { $0.id != currentRecording?.id && calendar.isDate($0.startedAt, inSameDayAs: now) }
      .reduce(0) { $0 + $1.duration }
    return WatchRecordingSnapshot(
      phase: phase,
      recordingID: phase == .idle ? nil : currentRecording?.id,
      elapsed: phase == .idle ? 0 : elapsed,
      capturedAt: now,
      todayCompletedDuration: todayCompleted
    )
  }

  func handle(watchRequest request: WatchBridgeRequest) async -> WatchBridgeReply {
    await start()
    await waitUntilNotBusy()
    var reply = WatchBridgeReply()
    switch request {
    case .snapshot:
      break
    case .start:
      errorMessage = nil
      await startRecording()
      if currentRecording == nil {
        reply.failure = .failed(errorMessage ?? AppLanguage.localized("Open WakeOnCue on iPhone to start recording."))
      }
    case .pause:
      await pauseRecording()
    case .resume:
      await resumeRecording()
    case .finish:
      await finishRecording()
    case .bookmark:
      reply = markWatchRange(seconds: 0)
    case .markRecent(let seconds):
      reply = markWatchRange(seconds: min(max(0, seconds), Self.watchRecentMarkLimit))
    case .tagBookmark(let recordingID, let bookmarkID, let tag):
      do {
        try RecordingAnnotationsService.shared.setBookmarkTag(
          recordingID: recordingID, bookmarkID: bookmarkID, tag: tag)
      } catch {
        reply.failure = .failed(error.localizedDescription)
      }
    }
    let snapshot = watchSnapshot()
    reply.snapshot = snapshot
    PhoneWatchBridge.shared.publish(snapshot)
    return reply
  }

  /// Imports audio files as local recordings, then transcribes and summarizes them on device.
  func importAudioFiles(_ urls: [URL]) async {
    for url in urls {
      do {
        let recording = try await AudioFileImporter(store: store, fileLayout: fileLayout)
          .importFile(at: url)
        await refresh()
        Task { await self.processOnDevice(recording: recording) }
      } catch {
        errorMessage = String(
          format: AppLanguage.localized("Could not import %@: %@"),
          url.lastPathComponent,
          error.localizedDescription
        )
      }
    }
  }

  func importWatchRecordings() async {
    let imported = await WatchRecordingImporter(
      store: store, fileLayout: fileLayout, annotations: .shared
    ).importPendingSessions()
    if !imported.isEmpty { await refresh() }
    await macUploader.sync()
  }

  /// `seconds == 0` drops a point bookmark at "now"; otherwise the span ending now is marked.
  private func markWatchRange(seconds: TimeInterval) -> WatchBridgeReply {
    guard let recording = currentRecording,
      [.recording, .paused].contains(recording.status)
    else { return WatchBridgeReply(failure: .notRecording) }
    let end = elapsed
    let start = max(0, end - seconds)
    do {
      let bookmark = try RecordingAnnotationsService.shared.addBookmark(
        recordingID: recording.id,
        position: start,
        duration: seconds > 0 ? end - start : nil
      )
      return WatchBridgeReply(
        mark: WatchMarkResult(
          recordingID: recording.id, bookmarkID: bookmark.id, savedSeconds: end - start))
    } catch {
      return WatchBridgeReply(failure: .failed(error.localizedDescription))
    }
  }
}

enum RecordingUIError: Error, LocalizedError {
  case microphoneDenied
  case playbackFailed

  var errorDescription: String? {
    switch self {
    case .microphoneDenied:
      AppLanguage.localized(
        "Microphone access is required. You can enable it in iOS Settings."
      )
    case .playbackFailed:
      AppLanguage.localized("The audio player could not start.")
    }
  }
}

struct RecordingShareItem: Identifiable {
  let id = UUID()
  let url: URL
}

enum DeviceInformation {
  static var modelIdentifier: String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    return mirror.children.reduce(into: "") { identifier, element in
      guard let value = element.value as? Int8, value != 0 else { return }
      identifier.append(Character(UnicodeScalar(UInt8(value))))
    }
  }
}

