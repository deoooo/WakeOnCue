import SwiftUI

extension Color {
  static let cueAccent = Color(red: 1, green: 159 / 255, blue: 10 / 255)
  static let cueRecording = Color(red: 1, green: 69 / 255, blue: 58 / 255)
  static let cueSaved = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
  static let cueControl = Color(white: 0.17)
}

enum WatchDurationText {
  static func hoursMinutes(_ value: TimeInterval) -> String {
    Duration.seconds(Int(value)).formatted(
      .units(allowed: [.hours, .minutes], width: .abbreviated, zeroValueUnits: .show(length: 1)))
  }

  static func minutesSeconds(_ value: TimeInterval) -> String {
    Duration.seconds(Int(value.rounded())).formatted(
      .units(allowed: [.minutes, .seconds], width: .wide, maximumUnitCount: 1))
  }
}

struct WatchHomeView: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    @Bindable var model = model
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        WatchStatusHeader()
        if model.isWatchRecording {
          WatchLevelMeter(level: model.inputLevel)
        }
        TimelineView(.periodic(from: .now, by: 1)) { context in
          VStack(alignment: .leading, spacing: 0) {
            Text(clockCaption)
              .font(.footnote)
              .foregroundStyle(.secondary)
            Text(clockText(at: context.date))
              .font(.title3.weight(.semibold).monospacedDigit())
          }
        }

        Button {
          Task { await model.captureRecent() }
        } label: {
          VStack(spacing: 1) {
            if model.isWorking {
              ProgressView().tint(.black)
            } else {
              Text("Save that")
                .font(.headline)
              Text("Marks the last 2 minutes")
                .font(.caption2.weight(.medium))
            }
          }
          .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cueAccent)
        .foregroundStyle(.black)
        .disabled(model.isWorking || !model.isRecording)
        .accessibilityIdentifier("watch-capture-recent")

        HStack(spacing: 8) {
          Button {
            Task { await model.togglePause() }
          } label: {
            Text(pauseTitle).frame(maxWidth: .infinity, minHeight: 40)
          }
          .accessibilityIdentifier("watch-toggle-recording")
          .disabled(model.isWorking || (model.phoneIsRecording && model.snapshot.phase == .finishing))
          Button {
            Task { await model.bookmark() }
          } label: {
            Text("Mark").frame(maxWidth: .infinity, minHeight: 40)
          }
          .disabled(!model.isRecording)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cueControl)
        .foregroundStyle(.white)

        if let message = model.message {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if model.isReachable && model.snapshot.isActive {
          Button(role: .destructive) {
            Task { await model.finish() }
          } label: {
            Text("Finish recording").frame(maxWidth: .infinity)
          }
          .accessibilityIdentifier("watch-finish-recording")
        }
      }
    }
    .task {
      // Application context is the primary channel; polling while on screen covers a missed push.
      while !Task.isCancelled {
        await model.refresh()
        try? await Task.sleep(for: .seconds(5))
      }
    }
    .sheet(item: $model.captureResult, onDismiss: { model.finishCapture() }) { _ in
      WatchSavedView()
        .environment(model)
    }
  }

  private var pauseTitle: LocalizedStringKey {
    if model.isWatchRecording { return "Stop" }
    switch model.phoneIsRecording ? model.snapshot.phase : .idle {
    case .recording: return "Pause"
    case .paused: return "Resume"
    case .idle, .finishing: return "Record"
    }
  }

  private var clockCaption: LocalizedStringKey {
    if model.isWatchRecording { return "Recording on Watch" }
    return model.phoneIsRecording ? "Recording on iPhone" : "Recorded today · on device"
  }

  private func clockText(at date: Date) -> String {
    if let startedAt = model.watchRecordingStartedAt {
      return Duration.seconds(Int(date.timeIntervalSince(startedAt)))
        .formatted(.time(pattern: .hourMinuteSecond))
    }
    if model.phoneIsRecording {
      return Duration.seconds(Int(model.snapshot.elapsed(at: date)))
        .formatted(.time(pattern: .hourMinuteSecond))
    }
    return WatchDurationText.hoursMinutes(model.snapshot.todayDuration(at: date))
  }
}

struct WatchStatusHeader: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(color)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("watch-status")
    .accessibilityValue(
      model.isWatchRecording
        ? "watch-recording" : (model.isReachable ? model.snapshot.phase.rawValue : "unreachable"))
  }

  private var title: LocalizedStringKey {
    if model.isWatchRecording { return "Recording on Watch" }
    if !model.isReachable { return "iPhone not connected" }
    switch model.snapshot.phase {
    case .recording: return "Recording"
    case .paused: return "Paused"
    case .finishing: return "Saving on iPhone"
    case .idle: return "Not recording"
    }
  }

  private var color: Color {
    if model.isWatchRecording { return .cueRecording }
    if model.isReachable && model.snapshot.phase == .recording { return .cueRecording }
    return .secondary
  }
}

struct WatchLevelMeter: View {
  let level: Float

  var body: some View {
    GeometryReader { proxy in
      Capsule()
        .fill(Color.cueControl)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(Color.cueAccent)
            .frame(width: max(4, proxy.size.width * CGFloat(min(1, level * 3))))
        }
    }
    .frame(height: 4)
    .accessibilityHidden(true)
  }
}

struct WatchSavedView: View {
  @Environment(WatchModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 36))
          .foregroundStyle(Color.cueSaved)
          .accessibilityLabel("Saved")
        if let result = model.captureResult {
          Text("Saved the last \(WatchDurationText.minutesSeconds(result.savedSeconds))")
            .font(.headline)
            .multilineTextAlignment(.center)
          Text(subtitle(for: result))
            .accessibilityIdentifier(savedIdentifier(for: result.destination))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

          Text("Add a tag (optional)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
          HStack(spacing: 6) {
            ForEach(RecordingMarkTag.allCases, id: \.self) { tag in
              Button {
                Task { await model.choose(tag: tag) }
              } label: {
                Text(tag.watchTitle)
                  .font(.footnote.weight(result.tag == tag ? .semibold : .regular))
                  .frame(maxWidth: .infinity, minHeight: 40)
              }
              .buttonStyle(.plain)
              .background(Color.cueControl, in: RoundedRectangle(cornerRadius: 12))
              .overlay {
                if result.tag == tag {
                  RoundedRectangle(cornerRadius: 12).stroke(Color.cueAccent, lineWidth: 1.5)
                }
              }
              .accessibilityAddTraits(result.tag == tag ? .isSelected : [])
              .accessibilityIdentifier("watch-tag-\(tag.rawValue)")
            }
          }
        }
        Button("Done") { dismiss() }
          .accessibilityIdentifier("watch-capture-done")
          .padding(.top, 2)
      }
    }
  }

  private func savedIdentifier(for destination: WatchCaptureResult.Destination) -> String {
    switch destination {
    case .phone: "watch-saved-on-phone"
    case .watchRecording: "watch-saved-on-watch-recording"
    }
  }

  private func subtitle(for result: WatchCaptureResult) -> LocalizedStringKey {
    switch result.destination {
    case .phone: "Marked in the iPhone recording"
    case .watchRecording: "Marked in the Watch recording"
    }
  }
}

extension RecordingMarkTag {
  var watchTitle: LocalizedStringKey {
    switch self {
    case .todo: "To-do"
    case .important: "Important"
    case .idea: "Idea"
    }
  }
}
