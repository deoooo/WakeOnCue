import SwiftUI
import WakeOnCueCore

/// Three tabs: Review (what was said, day by day), Record, and Search. Settings opens from
/// Review's top-left corner.
struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    TabView(selection: $model.selectedTab) {
      Tab("Review tab", systemImage: "clock.arrow.circlepath", value: AppTab.review) {
        ReviewView()
      }
      .accessibilityIdentifier("tab-review")

      Tab(isCapturing ? "Recording" : "Record", systemImage: "mic", value: AppTab.record) {
        RecordView()
      }
      .accessibilityIdentifier("tab-record")

      Tab(value: AppTab.search, role: .search) {
        NavigationStack {
          RecordingLibraryView()
        }
      }
      .accessibilityIdentifier("tab-search")
    }
    .sheet(isPresented: $model.settingsPresented) {
      SettingsView()
        .environment(model)
        .environment(\.locale, model.settings.language.locale)
    }
    .sheet(item: $model.shareItem) { item in
      RecordingShareSheet(fileURL: item.url)
    }
    .alert(
      "WakeOnCue",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .environment(\.locale, model.settings.language.locale)
  }

  private var isCapturing: Bool {
    guard let status = model.currentRecording?.status else { return false }
    return status == .recording || status == .paused
  }
}
