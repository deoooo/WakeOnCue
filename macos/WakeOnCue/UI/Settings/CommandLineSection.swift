import AppKit
import SwiftUI

/// Installs `wakeoncue`, the read-only command-line tool inside the app, as a link in
/// ~/.local/bin, which needs no administrator password.
struct CommandLineSection: View {
  @State private var installed = Self.isInstalled
  @State private var message: String?

  static var tool: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/wakeoncue") }
  static var link: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/wakeoncue") }

  static var isInstalled: Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == tool.path
  }

  var body: some View {
    Section {
      LabeledContent {
        HStack {
          if installed {
            Text("已安装").foregroundStyle(.green)
            Button("移除", action: remove)
          } else {
            Button("安装", action: install)
          }
        }
      } label: {
        Text("命令行工具 wakeoncue")
        Text("在终端或 Claude 等 AI 工具里只读查询总结、转录和会议，例如 wakeoncue day、wakeoncue search 告警 --json。不包含标为私人或已删除的时段。")
      }
      if let message {
        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    } header: {
      Text("命令行")
    }
  }

  private func install() {
    do {
      try FileManager.default.createDirectory(at: Self.link.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: Self.link)
      try FileManager.default.createSymbolicLink(at: Self.link, withDestinationURL: Self.tool)
      installed = true
      message = "已链接到 ~/.local/bin/wakeoncue。如果终端提示找不到命令，把 ~/.local/bin 加进 PATH，例如在 ~/.zshrc 里加一行：export PATH=\"$HOME/.local/bin:$PATH\""
    } catch {
      message = "安装失败：\(error.localizedDescription)"
    }
  }

  private func remove() {
    try? FileManager.default.removeItem(at: Self.link)
    installed = Self.isInstalled
    message = nil
  }
}
