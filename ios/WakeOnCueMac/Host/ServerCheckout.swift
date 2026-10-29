import Foundation

/// The user's WakeOnCue checkout and the Python environments `server/scripts/setup_mac.sh`
/// creates in it. v1 does not bundle Python; it runs what the user already set up.
struct ServerCheckout: Equatable, Sendable {
  /// Where `server/recording_service` is run from (`PYTHONPATH=.` in `server/`).
  let root: URL
  /// Where the virtual environments live; a git worktree reuses its main checkout's.
  let environmentRoot: URL

  init(root: URL, environmentRoot: URL? = nil) {
    self.root = root
    self.environmentRoot = environmentRoot ?? root
  }

  var serverDirectory: URL { root.appending(path: "server", directoryHint: .isDirectory) }
  var gatewayPython: URL { environmentRoot.appending(path: "server/.venv/bin/python") }
  var qwenPython: URL { environmentRoot.appending(path: ".runtime/asr-qwen/.venv/bin/python") }
  var defaultQwenModel: URL {
    environmentRoot.appending(path: ".runtime/asr-qwen/models/Qwen3-ASR-1.7B")
  }
  /// `scripts/download_diarization_models.py` output, shared with the main checkout too.
  var diarizationModels: URL { environmentRoot.appending(path: "server/.local/models") }
  var runtimeDirectory: URL { serverDirectory.appending(path: ".runtime/mac-app") }

  var hasServerSources: Bool {
    FileManager.default.fileExists(
      atPath: serverDirectory.appending(path: "recording_service/realtime_main.py").path)
  }

  var hasGatewayEnvironment: Bool {
    FileManager.default.isExecutableFile(atPath: gatewayPython.path)
  }

  var hasQwenEnvironment: Bool {
    FileManager.default.isExecutableFile(atPath: qwenPython.path)
  }

  /// Looks at the user's choice first, then the checkout this build came from and its
  /// parents (a git worktree under `.claude/worktrees` shares the main checkout's venv).
  static func locate(preferred: URL?) -> ServerCheckout? {
    var candidates: [URL] = []
    if let preferred { candidates.append(preferred) }
    if let built = Bundle.main.object(forInfoDictionaryKey: "WakeOnCueSourceRoot") as? String,
      !built.isEmpty, !built.hasPrefix("$")
    {
      var url = URL(fileURLWithPath: built, isDirectory: true).standardizedFileURL
      for _ in 0..<5 {
        candidates.append(url)
        url = url.deletingLastPathComponent()
      }
    }
    let checkouts = candidates.map { ServerCheckout(root: $0) }.filter(\.hasServerSources)
    guard let sources = checkouts.first else { return nil }
    let environment = checkouts.first(where: \.hasGatewayEnvironment)
    return ServerCheckout(root: sources.root, environmentRoot: environment?.root)
  }
}

enum ProcessorBackend: String, CaseIterable, Identifiable, Sendable {
  case whisper
  case qwen

  var id: String { rawValue }

  var title: String {
    switch self {
    case .whisper: String(localized: "MLX Whisper")
    case .qwen: String(localized: "Qwen3-ASR")
    }
  }
}
