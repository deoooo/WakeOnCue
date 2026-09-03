import AppIntents

struct RecordingShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartRecordingIntent(),
      phrases: ["Start a meeting recording with \(.applicationName)"],
      shortTitle: "Start Recording",
      systemImageName: "record.circle"
    )
    AppShortcut(
      intent: PauseRecordingIntent(),
      phrases: ["Pause my \(.applicationName) recording"],
      shortTitle: "Pause Recording",
      systemImageName: "pause.circle"
    )
    AppShortcut(
      intent: ResumeRecordingIntent(),
      phrases: ["Resume my \(.applicationName) recording"],
      shortTitle: "Resume Recording",
      systemImageName: "play.circle"
    )
    AppShortcut(
      intent: FinishRecordingIntent(),
      phrases: ["Finish my \(.applicationName) recording"],
      shortTitle: "Finish Recording",
      systemImageName: "stop.circle"
    )
  }
}
