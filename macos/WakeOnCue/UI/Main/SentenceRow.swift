import SwiftUI

/// One transcript line. A click plays from here; dragging selects text to copy without playing.
struct SentenceRow: View {
  let sentence: Sentence
  let highlighted: Bool
  let play: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(TimeText.seconds(sentence.start))
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 62, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        (Text(sentence.speaker.label).fontWeight(.semibold) + Text(" · \(sentence.source)").foregroundStyle(.secondary))
          .font(.caption)
        Text(sentence.text)
          .font(.system(size: 13))
          .lineSpacing(2)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.vertical, 7)
    .padding(.horizontal, 10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(highlighted ? Color.highlight : hovering ? Color.soft : .clear))
    .contentShape(Rectangle())
    // A tap only fires when the pointer did not move, so a drag-selection never plays.
    .simultaneousGesture(TapGesture().onEnded(play))
    .onHover { hovering = $0 }
    .help("单击从这句播放，拖选可复制")
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "从这句播放", play)
    .id(MainState.sentenceAnchor(sentence.id))
  }
}

/// A time reference inside a summary. It shows the original words; it never plays.
struct CiteButton: View {
  let label: String
  let action: () -> Void

  var body: some View {
    Button(label, action: action)
      .buttonStyle(.link)
      .font(.caption)
      .monospacedDigit()
      .help("查看原话，不播放")
      .accessibilityLabel("查看 \(label) 的原话")
  }
}

/// Text followed by its citations inline. Citations are links handled in-app: they find
/// and highlight the original words and never play.
struct CitedText: View {
  let text: String
  let cites: [Sentence]
  var font: Font = .system(size: 14)
  let cite: (Int64) -> Void

  var body: some View {
    Text(attributed)
      .font(font)
      .lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
      .environment(\.openURL, OpenURLAction { url in
        guard url.scheme == "wakeoncue-cite", let id = Int64(url.host() ?? "") else { return .systemAction }
        cite(id)
        return .handled
      })
  }

  private var attributed: AttributedString {
    var result = AttributedString(text)
    for sentence in cites {
      var link = AttributedString(" \(TimeText.clock(sentence.start))")
      link.link = URL(string: "wakeoncue-cite://\(sentence.id)")
      link.font = .caption.monospacedDigit()
      result += link
    }
    return result
  }
}

/// Lays children out left to right, wrapping to new lines; a child wider than the line
/// gets the full width.
nonisolated struct FlowLayout: Layout {
  var spacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
    for (index, frame) in result.frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    let width = proposal.width ?? .infinity
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      var size = subview.sizeThatFits(.unspecified)
      if size.width > width {
        size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      }
      if x > 0, x + size.width > width {
        x = 0
        y += lineHeight + 2
        lineHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (CGSize(width: min(widest, width), height: y + lineHeight), frames)
  }
}
