import AppKit
import SwiftUI
import WakeOnCueCore

struct TranscriptWindow: View {
  let model: MacAppModel

  private var transcript: LiveTranscript { model.recorder.transcript }

  var body: some View {
    Group {
      if transcript.segments.isEmpty {
        ContentUnavailableView(
          model.recorder.isRecording ? "Listening…" : "No live transcript",
          systemImage: "text.bubble",
          description: Text(
            model.recorder.isRecording
              ? "Text appears here a few seconds after someone speaks."
              : "Start a meeting recording with the realtime service running to see live text.")
        )
      } else {
        ScrollViewReader { proxy in
          List(transcript.segments) { event in
            SegmentRow(event: event).id(event.id)
          }
          .onChange(of: transcript.segments.last?.id) { _, last in
            if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
          }
        }
      }
    }
    .frame(minWidth: 320, minHeight: 280)
    .toolbar {
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.plainText(), forType: .string)
      } label: {
        Label("Copy Transcript", systemImage: "doc.on.doc")
      }
      .disabled(transcript.segments.isEmpty)
    }
  }
}

private struct SegmentRow: View {
  let event: RealtimeTranscriptEvent

  private var isMe: Bool { event.channel == .microphone }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(LiveTranscript.speakerName(for: event))
          .font(.caption.weight(.semibold))
          .foregroundStyle(isMe ? Color.accentColor : Color.orange)
        Text(LiveTranscript.timestamp(event.startMilliseconds))
          .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      }
      Text(event.text)
        .foregroundStyle(event.isFinal ? .primary : .secondary)
        .textSelection(.enabled)
    }
    .padding(.vertical, 2)
  }
}
