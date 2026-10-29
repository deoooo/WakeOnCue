import AVFoundation
import Foundation
import Observation
import UIKit
import WakeOnCueCore
import WidgetKit

@MainActor
@Observable
final class AppModel {
  private(set) var currentRecording: RecordingRecord?
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
  private(set) var audioBusyRecordingID: String?
  private(set) var playingRecordingID: String?
  private(set) var playbackIsPlaying = false
  private(set) var playbackPosition: TimeInterval = 0
  private(set) var playbackDuration: TimeInterval = 0
  private(set) var realtimeState: RealtimeConnectionState = .disabled
  private(set) var liveTranscriptSegments: [RealtimeTranscriptEvent] = []
  private(set) var realtimeUpdateSequence = 0
  private(set) var retranscribingRecordingID: String?
  private(set) var retranscriptionProgress = 0.0
  private(set) var retranscriptionStatusMessage: String?
  private(set) var transcriptVersion = 0
  /// Recordings being transcribed or summarized on this iPhone.
  private(set) var onDeviceProcessingRecordingIDs: Set<String> = []
  var errorMessage: String?
  var settingsPresented = false
  var shareItem: RecordingShareItem?

  let settings: AppSettings
  let places = PlaceAutomation()
  let meetings = CalendarAutomation()

  @ObservationIgnored private let fileLayout: RecordingFileLayout
  @ObservationIgnored private let store: RecordingStore
  @ObservationIgnored private let uploader: BackgroundUploadCoordinator
  @ObservationIgnored private let liveActivity = RecordingLiveActivityController()
  @ObservationIgnored private var capture: AudioCaptureService?
  @ObservationIgnored private var chunkConsumer: Task<Void, Never>?
  @ObservationIgnored private var timerTask: Task<Void, Never>?
  @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
  @ObservationIgnored private var commandObserver: RecordingCommandObserver?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var tickCount = 0
  @ObservationIgnored private var audioPlayer: AVAudioPlayer?
  @ObservationIgnored private var playbackMonitor: Task<Void, Never>?
  @ObservationIgnored private var realtimeClient: RealtimeProcessingClient?
  @ObservationIgnored private var liveTranscriptRecordingID: String?

  private var s3Enabled: Bool { settings.activeS3Configuration != nil }

  init() throws {
    let fileLayout = try RecordingFileLayout()
    let settings = AppSettings()
    self.fileLayout = fileLayout
    self.settings = settings
    store = try RecordingStore(databaseURL: fileLayout.databaseURL)
    uploader = BackgroundUploadCoordinator(
      store: store,
      configuration: settings.activeS3Configuration
    )
    uploader.onStateChanged = { [weak self] in
      Task { @MainActor in await self?.refresh() }
    }
    uploader.onFinalAudioUploaded = { [weak self] recordingID in
      Task { @MainActor in
        await self?.removeUploadedSourceFiles(recordingID: recordingID)
      }
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

  func bind(appDelegate: AppDelegate) {
    appDelegate.backgroundUploadHandler = { [weak uploader] completion in
      uploader?.handleEvents(completionHandler: completion)
    }
  }

  func start() async {
    guard !started else {
      await processPendingCommand()
      return
    }
    started = true
    #if DEBUG
      await persistDebugRealtimeConfigurationIfRequested()
    #endif
    commandObserver = RecordingCommandObserver { [weak self] in
      Task { @MainActor in await self?.processPendingCommand() }
    }
    do {
      try await store.rebaseLocalFilePaths(to: fileLayout.root)
      let interrupted = try await uploader.activate(uploadsEnabled: s3Enabled)
      let recovery = RecordingRecoveryService(fileLayout: fileLayout)
      for recordingID in interrupted {
        let interruptedRecording = try await store.recording(id: recordingID)
        let needsCloudBackup = interruptedRecording.metadata[S3Configuration.metadataBucketKey] != nil
          && interruptedRecording.metadata["cloud_sync_abandoned"] != "true"
        try await recovery.recoverUnindexedChunks(
          recordingID: recordingID,
          store: store,
          enqueueUpload: needsCloudBackup
        )
        let chunks = try await store.chunks(recordingID: recordingID)
        let duration = chunks.reduce(0) { $0 + $1.duration }
        if !needsCloudBackup {
          if !chunks.isEmpty { _ = try? await prepareM4A(recordingID: recordingID) }
          try await store.completeLocally(recordingID: recordingID, duration: duration)
        } else if chunks.isEmpty {
          try await store.transition(
            recordingID: recordingID,
            to: .failed,
            duration: 0
          )
        } else {
          let payload = try await prepareM4A(recordingID: recordingID)
          try await store.enqueueControlTask(
            recordingID: recordingID,
            kind: .finish,
            payloadPath: payload.path
          )
          try await store.transition(
            recordingID: recordingID,
            to: .uploading,
            duration: duration
          )
        }
        let recovered = try await store.recording(id: recordingID)
        if [.uploading, .completed].contains(recovered.status) {
          rememberLastFinished(recovered)
        }
      }
      if s3Enabled { uploader.schedule() }
      await importWatchRecordings()
      await refresh()
      await performStorageMaintenance()
      await liveActivity.removeStaleActivities(activeRecordingID: currentRecording?.id)
    } catch {
      errorMessage = String(
        format: AppLanguage.localized("Recovery failed: %@"), error.localizedDescription)
    }
    startTimer()
    startMaintenanceTimer()
    await processPendingCommand()
  }

  #if DEBUG
    private func persistDebugRealtimeConfigurationIfRequested() async {
      let environment = ProcessInfo.processInfo.environment
      guard environment["WAKEONCUE_TEST_PERSIST_REALTIME_CONFIGURATION"] == "1",
        let configuration = settings.activeRealtimeConfiguration
      else { return }

      do {
        try await RealtimeProcessingClient.validate(configuration: configuration)
        try settings.persistRealtimeConfiguration(configuration)
        settings.restorePersistedSettings()
        writeRealtimeConfigurationDiagnostic("PASS")
      } catch {
        writeRealtimeConfigurationDiagnostic("FAIL | error=\(String(reflecting: error))")
        errorMessage = String(
          format: AppLanguage.localized("Could not save realtime processing settings: %@"),
          error.localizedDescription
        )
      }
    }

    private func writeRealtimeConfigurationDiagnostic(_ message: String) {
      let url = fileLayout.root.appending(path: "last-realtime-configuration.txt")
      let payload = "\(Date().ISO8601Format()) | \(message)\n"
      try? payload.write(to: url, atomically: true, encoding: .utf8)
      try? RecordingFileLayout.protect(url)
    }
  #endif

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
      await realtimeClient?.stop()
      realtimeClient = nil
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
        metadata: settings.activeS3Configuration?.recordingMetadata ?? [:]
      )
      let payloadURL = try fileLayout.createPayload(recording: recording)
      liveTranscriptSegments = []
      realtimeUpdateSequence += 1
      liveTranscriptRecordingID = recordingID
      let realtimeClient = makeRealtimeClient()
      self.realtimeClient = realtimeClient
      let capture = AudioCaptureService(
        recordingID: recordingID,
        fileLayout: fileLayout,
        testFixtureURL: Self.debugAudioFixtureURL
      )
      configure(capture, realtimeClient: realtimeClient)
      startupStage = "starting the iPhone audio session"
      try capture.start()
      do {
        startupStage = "saving the recording session"
        try await store.createRecording(
          recording,
          createPayloadPath: payloadURL.path,
          enqueueUpload: s3Enabled
        )
      } catch {
        try? capture.stop()
        throw error
      }
      startupStage = "publishing the recording state"
      self.capture = capture
      currentRecording = recording
      elapsed = 0
      consumeChunks(from: capture, recordingID: recordingID)
      publishSharedState(isRecording: true, isPaused: false, recordingID: recordingID)
      await liveActivity.start(recording: recording, usesS3: s3Enabled)
      if s3Enabled { uploader.schedule() }
      let meetingMetadata = meetings.recordingMetadata(startingAt: now)
      if !meetingMetadata.isEmpty {
        _ = try? await store.updateRecordingMetadata(recordingID: recordingID, values: meetingMetadata)
      }
      await refresh()
      if let realtimeClient {
        Task {
          await realtimeClient.start(
            recordingID: recordingID,
            language: settings.spokenLanguage.recognitionCode
          )
        }
      }
      writeStartupDiagnostic("PASS | recording_id=\(recordingID)")
    } catch {
      await realtimeClient?.stop()
      realtimeClient = nil
      realtimeState = .disabled
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
      try capture.pause()
      await realtimeClient?.pause()
      try await recordPause(recordingID: recording.id, duration: capture.duration)
      if var paused = currentRecording { paused.status = .paused; currentRecording = paused }
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
      try capture.resume()
      await realtimeClient?.resume()
      try await recordResume(recordingID: recording.id, duration: capture.duration)
      if var resumed = currentRecording { resumed.status = .recording; currentRecording = resumed }
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
    defer { isBusy = false }
    do {
      try capture.stop()
      let finishingRealtimeClient = realtimeClient
      realtimeClient = nil
      if liveTranscriptRecordingID == recording.id {
        persistLiveTranscript(recordingID: recording.id)
        await enqueueTranscriptPersistence(recordingID: recording.id)
      }
      if let finishingRealtimeClient {
        Task { await finishingRealtimeClient.finish() }
      }
      let duration = capture.duration
      await chunkConsumer?.value
      chunkConsumer = nil
      self.capture = nil
      try await store.transition(
        recordingID: recording.id,
        to: .finishing,
        duration: duration
      )
      var finishingRecording = try await store.recording(id: recording.id)
      finishingRecording.duration = duration
      currentRecording = finishingRecording
      elapsed = duration
      publishSharedState(isRecording: false, isPaused: false, recordingID: nil)
      await refresh()
      let shareableAudio = try await prepareM4A(recordingID: recording.id)
      if s3Enabled {
        try await store.enqueueControlTask(
          recordingID: recording.id,
          kind: .finish,
          payloadPath: shareableAudio.path
        )
        try await store.transition(
          recordingID: recording.id,
          to: .uploading,
          duration: duration
        )
      } else {
        try await store.completeLocally(recordingID: recording.id, duration: duration)
      }
      let finishedRecording = try await store.recording(id: recording.id)
      rememberLastFinished(finishedRecording)
      currentRecording = nil
      currentSyncProgress = .init()
      elapsed = 0
      publishSharedState(isRecording: false, isPaused: false, recordingID: nil)
      let progress = try await syncProgress(for: finishedRecording)
      if finishedRecording.status == .completed {
        await liveActivity.end(
          recording: finishedRecording,
          progress: progress,
          usesS3: s3Enabled
        )
      } else {
        await liveActivity.update(
          recording: finishedRecording,
          progress: progress,
          usesS3: s3Enabled
        )
      }
      await refresh()
      if s3Enabled { uploader.schedule() }
      Task { await self.processOnDevice(recording: finishedRecording, audioURL: shareableAudio) }
    } catch {
      if self.capture == nil {
        await refresh()
        if var stranded = currentRecording,
          [.recording, .paused].contains(stranded.status)
        {
          stranded.status = .finishing
          currentRecording = stranded
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
      _ = try await prepareM4A(recordingID: recording.id)
      try await store.completeLocally(
        recordingID: recording.id,
        duration: recording.duration
      )
      let finishedRecording = try await store.recording(id: recording.id)
      rememberLastFinished(finishedRecording)
      if currentRecording?.id == recording.id { currentRecording = nil }
      currentSyncProgress = .init()
      elapsed = 0
      publishSharedState(isRecording: false, isPaused: false, recordingID: nil)
      await liveActivity.end(
        recording: finishedRecording,
        progress: try await syncProgress(for: finishedRecording),
        usesS3: s3Configuration(for: finishedRecording) != nil
      )
      await refresh()
    } catch {
      errorMessage = String(
        format: AppLanguage.localized("Could not finish locally: %@"),
        error.localizedDescription
      )
    }
  }

  func handle(url: URL) async {
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
        localized: "Finish the current recording before changing storage settings.")
      return
    }
    isSavingSettings = true
    settingsStatusIsError = false
    settingsStatusMessage =
      settings.useS3 || settings.useRealtimeProcessing
      ? AppLanguage.localized("Testing configured services…")
      : AppLanguage.localized("Saving local storage…")
    defer { isSavingSettings = false }
    do {
      let s3Configuration = try settings.useS3 ? settings.candidateS3Configuration() : nil
      let realtimeConfiguration =
        try settings.useRealtimeProcessing ? settings.candidateRealtimeConfiguration() : nil

      if let s3Configuration {
        var offset = 0
        while true {
          let page = try await store.recordings(limit: 100, offset: offset)
          if page.contains(where: {
            [.finishing, .uploading].contains($0.status)
              && !s3Configuration.matchesRecordedLocation($0.metadata)
          }) {
            throw S3SettingsError.invalid(AppLanguage.localized(
              "Pending backups use a different destination. Reconnect that storage and finish backing up before changing destinations."
            ))
          }
          if page.count < 100 { break }
          offset += page.count
        }
      }

      if let s3Configuration {
        try await S3StorageClient.validate(configuration: s3Configuration)
      }
      if let realtimeConfiguration {
        try await RealtimeProcessingClient.validate(configuration: realtimeConfiguration)
      }

      if let s3Configuration {
        try settings.persistS3Configuration(
          s3Configuration,
          localAudioRetentionDays: settings.localAudioRetentionDays
        )
        uploader.updateConfiguration(s3Configuration)
        uploader.setUploadsEnabled(true)
      } else {
        settings.persistLocalMode()
        uploader.updateConfiguration(nil)
        uploader.setUploadsEnabled(false)
      }
      if let realtimeConfiguration {
        try settings.persistRealtimeConfiguration(realtimeConfiguration)
      } else {
        settings.persistRealtimeDisabled()
      }
      await refresh()
      settingsStatusIsError = false
      settingsStatusMessage =
        settings.useRealtimeProcessing
        ? AppLanguage.localized("Storage and realtime processing settings saved.")
        : (s3Enabled
          ? AppLanguage.localized("Connected directly to S3. Configuration saved.")
          : AppLanguage.localized("Local storage enabled."))
      try? await Task.sleep(for: .milliseconds(500))
      settingsPresented = false
    } catch {
      settingsStatusIsError = true
      settingsStatusMessage = error.localizedDescription
    }
  }

  func cancelSettings() {
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
    audioBusyRecordingID = recording.id
    defer { audioBusyRecordingID = nil }
    do {
      let chunks = try await store.chunks(recordingID: recording.id)
      let file = try await RecordingAudioFileProvider(fileLayout: fileLayout).file(
        for: recording,
        chunks: chunks,
        s3Configuration: s3Configuration(for: recording)
      )
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
    audioBusyRecordingID = recording.id
    defer { audioBusyRecordingID = nil }
    do {
      let chunks = try await store.chunks(recordingID: recording.id)
      let file = try await RecordingAudioFileProvider(fileLayout: fileLayout).file(
        for: recording,
        chunks: chunks,
        s3Configuration: s3Configuration(for: recording)
      )
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
        let configuration = s3Configuration(for: recording)
      else { return [] }
      _ = try await S3StorageClient.downloadTranscript(
        recordingID: recordingID,
        configuration: configuration,
        destinationURL: url
      )
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
    guard let configuration = settings.activeRealtimeConfiguration else {
      errorMessage = AppLanguage.localized(
        "Configure realtime processing before retranscribing a recording."
      )
      return
    }

    retranscribingRecordingID = recording.id
    retranscriptionProgress = 0
    retranscriptionStatusMessage = AppLanguage.localized("Preparing audio…")
    audioBusyRecordingID = recording.id
    defer {
      retranscribingRecordingID = nil
      retranscriptionStatusMessage = nil
      audioBusyRecordingID = nil
    }

    let pair = AsyncStream<RealtimeProcessingEvent>.makeStream()
    let client = RealtimeProcessingClient(configuration: configuration) { event in
      pair.continuation.yield(event)
    }
    let eventTask = Task {
      try await Self.collectRetranscriptionEvents(from: pair.stream)
    }

    do {
      let chunks = try await store.chunks(recordingID: recording.id)
      let file = try await RecordingAudioFileProvider(fileLayout: fileLayout).file(
        for: recording,
        chunks: chunks,
        s3Configuration: s3Configuration(for: recording)
      )

      retranscriptionStatusMessage = AppLanguage.localized("Connecting to processor…")
      await client.start(
        recordingID: recording.id,
        language: settings.spokenLanguage.recognitionCode
      )
      retranscriptionStatusMessage = AppLanguage.localized("Transcribing and identifying speakers…")

      for try await frame in try await RealtimeAudioFileReader.frames(from: file) {
        try Task.checkCancellation()
        await client.appendAudio(frame.audio)
        retranscriptionProgress = min(0.92, frame.progress * 0.92)
      }
      retranscriptionStatusMessage = AppLanguage.localized("Finalizing speaker identification…")
      await client.finish()

      let segments = try await eventTask.value
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let transcriptURL = try fileLayout.transcriptURL(recordingID: recording.id)
      try encoder.encode(segments).write(to: transcriptURL, options: [.atomic])
      try RecordingFileLayout.protect(transcriptURL)
      await enqueueTranscriptPersistence(recordingID: recording.id)
      retranscriptionProgress = 1
      retranscriptionStatusMessage = AppLanguage.localized("Retranscription completed.")
      transcriptVersion += 1
    } catch {
      eventTask.cancel()
      retranscriptionStatusMessage = nil
      errorMessage = String(
        format: AppLanguage.localized("Could not retranscribe this recording: %@"),
        error.localizedDescription
      )
    }
    pair.continuation.finish()
    await client.stop()
  }

  private static func collectRetranscriptionEvents(
    from stream: AsyncStream<RealtimeProcessingEvent>
  ) async throws -> [RealtimeTranscriptEvent] {
    var segments: [String: RealtimeTranscriptEvent] = [:]
    for await event in stream {
      try Task.checkCancellation()
      switch event {
      case .transcript(let transcript):
        if let existing = segments[transcript.id], existing.revision > transcript.revision {
          continue
        }
        segments[transcript.id] = transcript
      case .state(.unavailable(let message)):
        throw RecordingUIError.realtimeUnavailable(message)
      case .completed:
        return segments.values.sorted {
          if $0.startMilliseconds == $1.startMilliseconds { return $0.id < $1.id }
          return $0.startMilliseconds < $1.startMilliseconds
        }
      case .state:
        continue
      }
    }
    throw RealtimeClientError.disconnected
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

  func performStorageMaintenance(now: Date = Date()) async {
    guard s3Enabled else { return }
    do {
      let recordings = try await store.recordingsWithUploadedFinalAudio()
      let maintenance = RecordingStorageMaintenance(fileLayout: fileLayout)
      let expirationDate = now.addingTimeInterval(-settings.activeLocalAudioRetention)
      for recording in recordings {
        let chunks = try await store.chunks(recordingID: recording.id)
        try maintenance.removeUploadedSourceFiles(recording: recording, chunks: chunks)

        let completedAt = recording.endedAt ?? recording.createdAt
        let isAudioInUse =
          playingRecordingID == recording.id
          || audioBusyRecordingID == recording.id
          || shareItem?.url.lastPathComponent.contains(recording.id) == true
        let locationMatches =
          settings.activeS3Configuration?.matchesRecordedLocation(
            recording.metadata
          ) == true
        if completedAt <= expirationDate, !isAudioInUse, locationMatches {
          try maintenance.removeExpiredFinalAudio(recordingID: recording.id)
        }
      }
    } catch {
      print("WakeOnCue storage maintenance skipped: \(error.localizedDescription)")
    }
  }

  func refresh() async {
    do {
      if let currentID = currentRecording?.id,
        let stored = try? await store.recording(id: currentID)
      {
        var displayed = stored
        if let capture, [.recording, .paused].contains(stored.status) {
          displayed.duration = capture.duration
          elapsed = capture.duration
        } else {
          elapsed = stored.duration
        }
        if stored.status == .completed {
          rememberLastFinished(stored)
          let progress = try await syncProgress(for: stored)
          await liveActivity.end(
            recording: stored,
            progress: progress,
            usesS3: s3Enabled
          )
          currentRecording = nil
          currentSyncProgress = .init()
          elapsed = 0
        } else if [.uploading, .failed].contains(stored.status) {
          if stored.status == .uploading { rememberLastFinished(stored) }
          currentRecording = nil
          currentSyncProgress = .init()
          elapsed = 0
        } else if [.recording, .paused, .finishing].contains(stored.status) {
          currentRecording = displayed
          let progress = try await syncProgress(for: displayed)
          currentSyncProgress = progress
          await liveActivity.update(
            recording: displayed,
            progress: progress,
            usesS3: s3Enabled
          )
        }
      } else if capture == nil {
        currentRecording = try await store.activeRecording()
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
            progress: progress,
            usesS3: s3Configuration(for: lastFinishedRecording) != nil
          )
        } else {
          await liveActivity.update(
            recording: lastFinishedRecording,
            progress: progress,
            usesS3: s3Configuration(for: lastFinishedRecording) != nil
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

  private func handle(command: RecordingCommand) async {
    switch command {
    case .start: await startRecording()
    case .pause: await pauseRecording()
    case .resume: await resumeRecording()
    case .finish: await finishRecording()
    }
  }

  private func configure(
    _ capture: AudioCaptureService,
    realtimeClient: RealtimeProcessingClient?
  ) {
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
    capture.onRealtimeAudioFrame = { frame in
      guard let realtimeClient else { return }
      Task { await realtimeClient.appendAudio(frame) }
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

  /// Transcribes on this iPhone when no realtime transcript exists, then writes a summary.
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
      var segments = (try? await transcript(for: recording.id)) ?? []
      if segments.isEmpty, OnDeviceIntelligence.canTranscribe {
        let file: URL
        if let audioURL {
          file = audioURL
        } else {
          file = try await RecordingAudioFileProvider(fileLayout: fileLayout).file(
            for: recording,
            chunks: try await store.chunks(recordingID: recording.id),
            s3Configuration: s3Configuration(for: recording)
          )
        }
        segments = try await OnDeviceIntelligence.transcribe(
          audioURL: file,
          recordingID: recording.id,
          spokenLanguage: settings.spokenLanguage
        )
        guard !segments.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let transcriptURL = try fileLayout.transcriptURL(recordingID: recording.id)
        try encoder.encode(segments).write(to: transcriptURL, options: [.atomic])
        try RecordingFileLayout.protect(transcriptURL)
        await enqueueTranscriptPersistence(recordingID: recording.id)
        transcriptVersion += 1
      }
      guard !segments.isEmpty, OnDeviceIntelligence.canSummarize,
        regenerateSummary || summary(for: recording.id) == nil
      else { return }
      let summary = try await OnDeviceIntelligence.summarize(
        segments,
        title: recording.title,
        language: AppLanguage.current
      )
      let summaryURL = try fileLayout.summaryURL(recordingID: recording.id)
      try JSONEncoder().encode(summary).write(to: summaryURL, options: [.atomic])
      try RecordingFileLayout.protect(summaryURL)
      transcriptVersion += 1
    } catch {
      errorMessage = String(
        format: AppLanguage.localized("Could not process this recording on iPhone: %@"),
        error.localizedDescription
      )
    }
  }

  /// Saves the voice of one speaker in a finished recording under the name the user gave.
  /// Only the passages labeled with that speaker are sent, once, to the user's own service.
  func rememberVoice(
    recording: RecordingRecord,
    clusterID: String,
    name: String,
    transcript: [RealtimeTranscriptEvent],
    replacing personID: String? = nil
  ) async throws {
    guard settings.rememberVoicesEnabled else { return }
    let configuration = try settings.voiceEnrollmentConfiguration()
    let ranges = transcript
      .filter { $0.speaker?.clusterID == clusterID }
      .map { $0.startMilliseconds..<$0.endMilliseconds }
    let chunks = try await store.chunks(recordingID: recording.id)
    let file = try await RecordingAudioFileProvider(fileLayout: fileLayout).file(
      for: recording,
      chunks: chunks,
      s3Configuration: s3Configuration(for: recording)
    )
    let maximumBytes =
      Int(RealtimeVoiceprintEnrollmentRequest.recommendedDuration) * RealtimeProtocol.sampleRate * 2
    var sample = Data()
    for try await frame in try await RealtimeAudioFileReader.frames(from: file) {
      let start = frame.audio.startMilliseconds
      let end = start + frame.audio.pcm16LittleEndian.count * 1_000 / (RealtimeProtocol.sampleRate * 2)
      if ranges.contains(where: { $0.lowerBound <= start && end <= $0.upperBound }) {
        sample.append(frame.audio.pcm16LittleEndian)
        if sample.count >= maximumBytes { break }
      }
    }
    guard !sample.isEmpty else { throw RealtimeClientError.voiceprintNeedsMoreSpeech }
    let enrolled = try await RealtimeProcessingClient.enrollVoiceprint(
      configuration: configuration,
      pcm16LittleEndian: sample
    )
    try settings.saveVoice(name: name, voiceprint: enrolled.voiceprint, replacing: personID)
  }

  private func makeRealtimeClient() -> RealtimeProcessingClient? {
    guard let configuration = settings.activeRealtimeConfiguration else {
      realtimeState = .disabled
      return nil
    }
    return RealtimeProcessingClient(configuration: configuration) { [weak self] event in
      Task { @MainActor in self?.handleRealtimeEvent(event) }
    }
  }

  private func handleRealtimeEvent(_ event: RealtimeProcessingEvent) {
    switch event {
    case .state(let state):
      realtimeState = state
    case .transcript(let transcript):
      guard transcript.recordingID == liveTranscriptRecordingID else { return }
      if let personID = transcript.speaker?.personID {
        settings.markVoicesHeard([personID])
      }
      if let index = liveTranscriptSegments.firstIndex(where: { $0.id == transcript.id }) {
        guard transcript.revision >= liveTranscriptSegments[index].revision else { return }
        liveTranscriptSegments[index] = transcript
      } else {
        liveTranscriptSegments.append(transcript)
      }
      liveTranscriptSegments.sort {
        if $0.startMilliseconds == $1.startMilliseconds { return $0.id < $1.id }
        return $0.startMilliseconds < $1.startMilliseconds
      }
      realtimeUpdateSequence += 1
      persistLiveTranscript(recordingID: transcript.recordingID)
    case .completed:
      if let recordingID = liveTranscriptRecordingID {
        persistLiveTranscript(recordingID: recordingID)
        Task { await enqueueTranscriptPersistence(recordingID: recordingID) }
      }
      realtimeUpdateSequence += 1
    }
  }

  private func persistLiveTranscript(recordingID: String) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let url = try fileLayout.transcriptURL(recordingID: recordingID)
      try encoder.encode(liveTranscriptSegments).write(to: url, options: [.atomic])
      try RecordingFileLayout.protect(url)
    } catch {
      print("WakeOnCue could not persist live transcript: \(error.localizedDescription)")
    }
  }

  private func enqueueTranscriptPersistence(recordingID: String) async {
    guard s3Enabled else { return }
    do {
      let recording = try await store.recording(id: recordingID)
      guard s3Configuration(for: recording) != nil else { return }
      let transcriptURL = try fileLayout.transcriptURL(recordingID: recordingID)
      guard FileManager.default.fileExists(atPath: transcriptURL.path) else { return }
      try await store.enqueueTranscriptTask(
        recordingID: recordingID,
        transcriptPath: transcriptURL.path
      )
      uploader.schedule()
    } catch {
      print("WakeOnCue could not enqueue transcript persistence: \(error.localizedDescription)")
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
            enqueueUpload: self.s3Enabled
          )
          if self.s3Enabled { self.uploader.schedule() }
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
    let playbackProbe = try AVAudioPlayer(contentsOf: url)
    guard playbackProbe.prepareToPlay(), playbackProbe.duration > 0 else {
      throw RecordingUIError.playbackFailed
    }
    return url
  }

  private func s3Configuration(for recording: RecordingRecord) -> S3Configuration? {
    guard let configuration = settings.activeS3Configuration,
      configuration.matchesRecordedLocation(recording.metadata)
    else { return nil }
    return configuration
  }

  private func removeUploadedSourceFiles(recordingID: String) async {
    do {
      let recording = try await store.recording(id: recordingID)
      let chunks = try await store.chunks(recordingID: recordingID)
      try RecordingStorageMaintenance(fileLayout: fileLayout).removeUploadedSourceFiles(
        recording: recording,
        chunks: chunks
      )
    } catch {
      print("WakeOnCue could not prune uploaded source files: \(error.localizedDescription)")
    }
  }

  private func startMaintenanceTimer() {
    maintenanceTask?.cancel()
    maintenanceTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(6 * 60 * 60))
        guard !Task.isCancelled, let self else { return }
        await self.performStorageMaintenance()
      }
    }
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
  case realtimeUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .microphoneDenied:
      AppLanguage.localized(
        "Microphone access is required. You can enable it in iOS Settings."
      )
    case .playbackFailed:
      AppLanguage.localized("The audio player could not start.")
    case .realtimeUnavailable(let message):
      message
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
