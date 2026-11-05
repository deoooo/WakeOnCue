import AppKit
import UniformTypeIdentifiers

/// "导出…": the standard save panel with a format menu under it. Markdown is the default; the
/// file name's extension follows the format chosen.
@MainActor
final class ExportPanel: NSObject {
  private let source: ExportSource
  private let panel = NSSavePanel()
  private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
  private static var open: ExportPanel?

  static func run(_ source: ExportSource) {
    let export = ExportPanel(source: source)
    open = export
    export.begin()
  }

  private init(source: ExportSource) {
    self.source = source
    super.init()
  }

  private var format: ExportFormat { ExportFormat.allCases[max(0, popup.indexOfSelectedItem)] }

  private func begin() {
    panel.title = "导出"
    panel.prompt = "导出"
    panel.message = "标为私人或已删除的时段不会导出。"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = Exporter.fileName(source, as: .markdown)
    popup.addItems(withTitles: ExportFormat.allCases.map(\.label))
    popup.target = self
    popup.action = #selector(formatChanged)
    let label = NSTextField(labelWithString: "格式：")
    let row = NSStackView(views: [label, popup])
    row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    panel.accessoryView = row
    updateType()
    let finish = { (response: NSApplication.ModalResponse) in
      defer { ExportPanel.open = nil }
      guard response == .OK, let url = self.panel.url else { return }
      let text = Exporter.render(self.source, as: self.format)
      do {
        try Data(text.utf8).write(to: url, options: .atomic)
      } catch {
        NSAlert(error: error).runModal()
      }
    }
    // A sheet on the main window, even when the app is not frontmost (the menu bar or ⌘E).
    let main = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
    if let window = main ?? NSApp.keyWindow ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      finish(panel.runModal())
    }
  }

  @objc private func formatChanged() {
    updateType()
    let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
    panel.nameFieldStringValue = base + "." + format.rawValue
  }

  private func updateType() {
    panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
  }
}

extension AppModel {
  /// The day shown in the main window.
  func exportDay() { ExportPanel.run(.day(ui.day, store: store)) }

  func exportHour(_ start: Date) { ExportPanel.run(.hour(start, store: store)) }

  func exportMeeting(_ id: Int64) {
    guard let meeting = store.meeting(id: id) else { return }
    ExportPanel.run(.meeting(meeting, store: store))
  }
}
