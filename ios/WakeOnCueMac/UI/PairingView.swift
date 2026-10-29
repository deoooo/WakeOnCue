import SwiftUI

/// Shows the iPhone pairing QR. The payload carries the Gateway token, so it stays hidden
/// until the user asks for it and is never written to disk.
struct PairingView: View {
  let model: MacAppModel
  @State private var revealed = false
  @State private var image: NSImage?

  var body: some View {
    VStack(spacing: 14) {
      Text("Pair your iPhone").font(.title2.weight(.semibold))
      Text(
        "On iPhone, open Settings › Live transcription › Pair self-hosted service and scan this code. Both devices must be on the same network."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      ZStack {
        RoundedRectangle(cornerRadius: 12).fill(.white)
        if revealed, let image {
          Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(12)
        } else {
          Button("Show Pairing Code") { reveal() }
            .buttonStyle(.borderedProminent)
        }
      }
      .frame(width: 260, height: 260)

      Text(model.host.lanGatewayURL.absoluteString)
        .font(.callout.monospaced()).textSelection(.enabled)
      Label(
        "The code contains your Gateway token. Do not share it or take screenshots of it.",
        systemImage: "lock"
      )
      .font(.caption).foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
      if revealed, image == nil {
        Text("No Gateway token found. Start the realtime service once to create it.")
          .font(.caption).foregroundStyle(.red)
      }
    }
    .padding(24)
    .frame(width: 360)
    .onDisappear {
      revealed = false
      image = nil
    }
  }

  private func reveal() {
    image = model.pairingPayload().flatMap { PairingCode.qrImage(for: $0) }
    revealed = true
  }
}
