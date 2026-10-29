@preconcurrency import AVFoundation
import SwiftUI

struct RealtimePairingScanner: UIViewControllerRepresentable {
  let onPayload: @MainActor (String) -> Void
  let onError: @MainActor (String) -> Void

  func makeUIViewController(context: Context) -> RealtimePairingScannerViewController {
    let controller = RealtimePairingScannerViewController()
    controller.onPayload = onPayload
    controller.onError = onError
    return controller
  }

  func updateUIViewController(
    _ uiViewController: RealtimePairingScannerViewController,
    context: Context
  ) {}
}

final class RealtimePairingScannerViewController: UIViewController {
  var onPayload: (@MainActor (String) -> Void)?
  var onError: (@MainActor (String) -> Void)?

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "WakeOnCue.RealtimePairingScanner")
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var didDeliverPayload = false
  private var isVisible = false
  private var isConfigured = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    isVisible = true
    configurePermissionAndSession()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    isVisible = false
    sessionQueue.async { [session] in
      if session.isRunning { session.stopRunning() }
    }
  }

  private func configurePermissionAndSession() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        Task { @MainActor in
          guard let self, self.isVisible else { return }
          if granted {
            self.configureSession()
          } else {
            self.onError?(
              AppLanguage.localized(
                "Camera access is off. Allow it in Settings or paste the pairing JSON instead."
              ))
          }
        }
      }
    default:
      onError?(
        AppLanguage.localized(
          "Camera access is off. Allow it in Settings or paste the pairing JSON instead."
        ))
    }
  }

  private func configureSession() {
    guard isVisible, !didDeliverPayload else { return }
    if isConfigured {
      sessionQueue.async { [session] in session.startRunning() }
      return
    }
    guard let camera = AVCaptureDevice.default(for: .video) else {
      onError?(AppLanguage.localized("No camera is available. Paste the pairing JSON instead."))
      return
    }
    do {
      let input = try AVCaptureDeviceInput(device: camera)
      let output = AVCaptureMetadataOutput()
      guard session.canAddInput(input), session.canAddOutput(output) else {
        onError?(AppLanguage.localized("The camera could not start. Paste the pairing JSON instead."))
        return
      }
      session.addInput(input)
      session.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: .main)
      output.metadataObjectTypes = [.qr]
      isConfigured = true

      let previewLayer = AVCaptureVideoPreviewLayer(session: session)
      previewLayer.videoGravity = .resizeAspectFill
      view.layer.addSublayer(previewLayer)
      self.previewLayer = previewLayer
      previewLayer.frame = view.bounds
      sessionQueue.async { [session] in session.startRunning() }
    } catch {
      onError?(
        String(
          format: AppLanguage.localized("The camera could not start: %@"),
          error.localizedDescription
        ))
    }
  }

}

extension RealtimePairingScannerViewController: @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard !didDeliverPayload,
      let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
      code.type == .qr,
      let value = code.stringValue
    else { return }
    didDeliverPayload = true
    sessionQueue.async { [session] in
      if session.isRunning { session.stopRunning() }
    }
    onPayload?(value)
  }
}
