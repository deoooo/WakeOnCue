import SwiftUI

/// The transcription model list, one choice: clicking a model uses it, downloading it first if it
/// is not on this Mac yet (the model in use keeps working until the download is done). The model
/// that suits this Mac's memory is marked; Apple speech stays in use until the user picks another.
struct ModelList: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ForEach(ASRModel.catalog) { entry in
      ModelRow(entry: entry)
    }
  }
}

struct ModelRow: View {
  @Environment(AppModel.self) private var model
  let entry: ASRModel

  var body: some View {
    let models = model.models
    let state = models.state(of: entry)
    let selected = models.selectedID == entry.id
    let inUse = entry.isBuiltIn ? models.activeID == nil : models.activeID == entry.id
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: selected ? "largecircle.fill.circle" : "circle")
        .font(.title3)
        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(entry.name)
          if entry == ASRModel.recommended() {
            Text("推荐")
              .font(.caption2.weight(.medium))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.tint.opacity(0.15), in: Capsule())
              .foregroundStyle(.tint)
          }
        }
        Text(entry.isDownloadable ? "\(entry.detail) · \(entry.size)" : entry.detail)
          .font(.caption).foregroundStyle(.secondary)
        status(state, selected: selected, inUse: inUse)
      }
      Spacer(minLength: 8)
      trailing(state, inUse: inUse)
        .font(.callout)
    }
    .contentShape(Rectangle())
    .onTapGesture { models.choose(entry) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .contextMenu {
      if entry.isDownloadable, state != .notDownloaded {
        Button("删除已下载的文件", role: .destructive) { models.delete(entry) }
      }
    }
  }

  /// One line under the description: what is happening with this model.
  @ViewBuilder
  private func status(_ state: ASRModels.State, selected: Bool, inUse: Bool) -> some View {
    let models = model.models
    switch state {
    case .notDownloaded where entry.isRemote:
      Text("在下方填写转录服务后可选").font(.caption).foregroundStyle(.secondary)
    case .downloading(let fraction):
      HStack(spacing: 6) {
        ProgressView(value: fraction).frame(width: 120)
        Text("下载中 \(Int(fraction * 100))%\(selected ? "，完成后自动使用" : "")")
          .monospacedDigit()
      }
      .font(.caption).foregroundStyle(.secondary)
    case .verifying:
      Text("正在校验…").font(.caption).foregroundStyle(.secondary)
    case .paused(let fraction):
      Text("已暂停 \(Int(fraction * 100))%，再次选中会接着下载").font(.caption).foregroundStyle(.secondary)
    case .failed(let reason):
      Text(reason).font(.caption).foregroundStyle(Color.recording).lineLimit(2)
    case .installed where inUse && !entry.isBuiltIn:
      RefinerStatusText().font(.caption).foregroundStyle(.secondary)
    case .notDownloaded where selected && models.downloadingID != nil:
      Text("等当前下载暂停后开始下载").font(.caption).foregroundStyle(.secondary)
    case .installed, .notDownloaded:
      EmptyView()
    }
  }

  @ViewBuilder
  private func trailing(_ state: ASRModels.State, inUse: Bool) -> some View {
    let models = model.models
    switch state {
    case .downloading:
      Button("暂停") { models.pause(entry) }
    case .failed:
      Button("重试") { models.choose(entry) }
    case .installed where inUse:
      Text("使用中").foregroundStyle(.green)
    case .notDownloaded where entry.isDownloadable:
      Text("选中后下载").foregroundStyle(.secondary)
    default:
      EmptyView()
    }
  }
}

/// Whether the model is loaded and how fast it works through the audio.
struct RefinerStatusText: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let refiner = model.refiner
    switch refiner.status {
    case .off: EmptyView()
    case .loading(let name): Text("正在载入 \(name)…")
    case .failed(let reason): Text(reason).foregroundStyle(Color.recording)
    case .ready where refiner.lastError != nil:
      Text("最近一句失败：\(refiner.lastError ?? "")").foregroundStyle(Color.recording)
    case .ready:
      if let perMinute = refiner.secondsPerMinute {
        Text("每分钟音频约用 \(perMinute.formatted(.number.precision(.fractionLength(1)))) 秒\(refiner.pending > 0 ? "，还有 \(refiner.pending) 句排队" : "")")
      } else {
        Text("已就绪，Apple 语音的每句话会在几秒后重新转录")
      }
    }
  }
}
