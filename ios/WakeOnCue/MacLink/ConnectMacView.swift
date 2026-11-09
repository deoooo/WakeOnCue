import AVFoundation
import SwiftUI
import VisionKit

/// 连接 Mac: nearby Macs, the code, the QR code, and how it went.
struct ConnectMacView: View {
  @Bindable var flow: MacPairingFlow
  let currentMac: String?
  @Environment(\.dismiss) private var dismiss
  @State private var scanning = false

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Connect Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            if case .done = flow.stage {
              EmptyView()
            } else {
              Button("Cancel") { dismiss() }
            }
          }
        }
    }
    .onAppear { flow.startBrowsing() }
    .fullScreenCover(isPresented: $scanning) {
      QRScannerScreen { code in
        scanning = false
        flow.offer(code)
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch flow.stage {
    case .choose: chooser
    case .requesting(let mac):
      progress(String(format: AppLanguage.localized("Asking “%@” for a code…"), mac.name))
    case .enterCode(let mac, let request):
      CodeEntryView(macName: request.macName, error: flow.codeError, checking: flow.checkingCode) { flow.submit(code: $0, for: mac, request: request) } again: {
        flow.request(mac)
      }
    case .confirmQR(let code): confirmCard(code)
    case .connecting(let macName, let method, let step): ConnectingView(macName: macName, method: method, step: step)
    case .done(let macName): doneView(macName)
    case .failed(let failure): FailureView(failure: failure, retry: { flow.backToList() }, close: { dismiss() })
    }
  }

  private var chooser: some View {
    List {
      if flow.localNetworkDenied {
        Section {
          Label("WakeOnCue needs Local Network access to find your Mac.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Button("Open Settings") { openSystemSettings() }
        }
      }
      Section {
        ForEach(flow.nearby) { mac in
          Button { flow.request(mac) } label: {
            HStack {
              Label(mac.name, systemImage: "desktopcomputer").foregroundStyle(.primary)
              Spacer()
              Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
          }
        }
        HStack(spacing: 10) {
          ProgressView()
          Text("Looking…").foregroundStyle(.secondary)
        }
      } header: {
        Text("Nearby")
      }
      Section {
        Button { scanning = true } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
      } footer: {
        if let currentMac {
          Text(String(format: AppLanguage.localized("This replaces “%@”."), currentMac))
        } else {
          Text("Can’t find it? Make sure the iPhone and the Mac are on the same Wi-Fi.")
        }
      }
    }
  }

  private func confirmCard(_ code: SyncProtocol.Pairing) -> some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "laptopcomputer").font(.system(size: 56)).foregroundStyle(.tint)
      Text(String(format: AppLanguage.localized("Connect to “%@”?"), code.macName))
        .font(.title2.bold()).multilineTextAlignment(.center)
      Spacer()
      Button { flow.confirm(code) } label: { Text("Connect").frame(maxWidth: .infinity) }
        .buttonStyle(.borderedProminent).controlSize(.large)
      Button("Cancel") { dismiss() }
    }
    .padding(24)
  }

  private func doneView(_ macName: String) -> some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(.green)
      Text(String(format: AppLanguage.localized("Connected to “%@”"), macName))
        .font(.title2.bold()).multilineTextAlignment(.center)
      Text("Recordings will go to this Mac automatically.").foregroundStyle(.secondary)
      Spacer()
      Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
        .buttonStyle(.borderedProminent).controlSize(.large)
    }
    .padding(24)
  }

  private func progress(_ text: String) -> some View {
    VStack(spacing: 16) {
      ProgressView().controlSize(.large)
      Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

func openSystemSettings() {
  if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

/// Six boxes over one number field; sends the code once six digits are in.
private struct CodeEntryView: View {
  let macName: String
  let error: String?
  let checking: Bool
  let submit: (String) -> Void
  let again: () -> Void
  @State private var code = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 12) {
      Text("Enter Pairing Code").font(.title2.bold()).padding(.top, 40)
      Text(String(format: AppLanguage.localized("Shown on “%@”"), macName)).foregroundStyle(.secondary)
      ZStack {
        HStack(spacing: 8) {
          ForEach(0..<6, id: \.self) { index in
            let digits = Array(code)
            Text(index < digits.count ? String(digits[index]) : "")
              .font(.system(size: 28, weight: .semibold, design: .rounded))
              .frame(width: 46, height: 58)
              .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
              .overlay {
                RoundedRectangle(cornerRadius: 10)
                  .stroke(error != nil ? Color.orange : index == digits.count ? Color.accentColor : Color(.separator), lineWidth: 2)
              }
            if index == 2 { Spacer().frame(width: 6) }
          }
        }
        TextField("", text: $code)
          .keyboardType(.numberPad)
          .textContentType(.oneTimeCode)
          .focused($focused)
          .opacity(0.02)
          .accessibilityLabel("Pairing code")
      }
      .padding(.top, 20)
      .onTapGesture { focused = true }
      if checking {
        ProgressView()
      } else if let error {
        Text(error).foregroundStyle(.orange)
      }
      Button("Get a New Code") {
        code = ""
        again()
      }
      .padding(.top, 8)
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .background(Color(.systemGroupedBackground))
    .onAppear { focused = true }
    .onChange(of: code) {
      let digits = String(code.filter(\.isNumber).prefix(6))
      if digits != code { code = digits }
      if digits.count == 6 { submit(digits) }
    }
    .onChange(of: error) {
      if error != nil { code = "" }
    }
  }
}

private struct ConnectingView: View {
  let macName: String
  let method: MacPairingFlow.Method
  let step: Int

  var body: some View {
    let steps: [LocalizedStringKey] =
      method == .code ? ["Code accepted", "Exchanging keys", "Mac confirms"] : ["QR code read", "Finding the Mac", "Mac confirms"]
    VStack(spacing: 12) {
      ProgressView().controlSize(.large).padding(.top, 80)
      Text("Connecting").font(.title2.bold()).padding(.top, 12)
      Text(macName).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 14) {
        ForEach(steps.indices, id: \.self) { index in
          HStack(spacing: 12) {
            Group {
              if index < step {
                Image(systemName: "checkmark").foregroundStyle(.green)
              } else if index == step {
                ProgressView()
              } else {
                Image(systemName: "circle").foregroundStyle(.tertiary)
              }
            }
            .frame(width: 24)
            Text(steps[index]).foregroundStyle(index > step ? .secondary : .primary)
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 16)
      .padding(.top, 24)
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .background(Color(.systemGroupedBackground))
  }
}

private struct FailureView: View {
  let failure: MacPairingFlow.Failure
  let retry: () -> Void
  let close: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
      Text(title).font(.title2.bold()).multilineTextAlignment(.center)
      Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Spacer()
      if failure == .localNetwork {
        Button { openSystemSettings() } label: { Text("Open Settings").frame(maxWidth: .infinity) }
          .buttonStyle(.borderedProminent).controlSize(.large)
      } else {
        Button { retry() } label: { Text("Try Again").frame(maxWidth: .infinity) }
          .buttonStyle(.borderedProminent).controlSize(.large)
      }
      Button("Close", action: close)
    }
    .padding(24)
  }

  private var title: String {
    switch failure {
    case .localNetwork: AppLanguage.localized("Local Network access needed")
    case .notFound: AppLanguage.localized("Mac not found")
    case .expired: AppLanguage.localized("The code has expired")
    case .message: AppLanguage.localized("Couldn’t connect")
    }
  }

  private var detail: String {
    switch failure {
    case .localNetwork: AppLanguage.localized("Without it the iPhone can’t find the Mac.")
    case .notFound: AppLanguage.localized("Make sure both are on the same Wi-Fi.")
    case .expired: AppLanguage.localized("Get a new one on the Mac.")
    case .message(let text): text
    }
  }
}

/// The in-app scanner for the Mac's pairing QR code.
private struct QRScannerScreen: View {
  let found: (SyncProtocol.Pairing) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var allowed: Bool?

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.ignoresSafeArea()
      if allowed == true, DataScannerViewController.isSupported {
        QRScanner(found: found).ignoresSafeArea()
      } else if allowed != nil {
        Text("The camera isn’t available. You can also scan the Mac’s QR code with the Camera app.")
          .foregroundStyle(.white).multilineTextAlignment(.center).padding(32)
          .frame(maxHeight: .infinity)
      }
      VStack(spacing: 8) {
        HStack {
          Button("Cancel") { dismiss() }.foregroundStyle(.white)
          Spacer()
        }
        Text("Point at the pairing QR code on your Mac").foregroundStyle(.white)
      }
      .padding()
      .background(.black.opacity(0.4))
    }
    .task { allowed = await AVCaptureDevice.requestAccess(for: .video) }
  }
}

private struct QRScanner: UIViewControllerRepresentable {
  let found: (SyncProtocol.Pairing) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(found: found) }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    return scanner
  }

  func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
    if !scanner.isScanning { try? scanner.startScanning() }
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let found: (SyncProtocol.Pairing) -> Void
    private var done = false

    init(found: @escaping (SyncProtocol.Pairing) -> Void) {
      self.found = found
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
      for item in addedItems {
        guard !done, case .barcode(let barcode) = item, let text = barcode.payloadStringValue, let url = URL(string: text),
          let code = SyncProtocol.Pairing(url: url)
        else { continue }
        done = true
        dataScanner.stopScanning()
        found(code)
      }
    }
  }
}
