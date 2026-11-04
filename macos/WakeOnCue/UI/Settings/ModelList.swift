import SwiftUI

/// The transcription model list: Apple speech, and models downloaded from their official
/// release. One click downloads, verifies and turns a model on.
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
    let inUse = entry.isBuiltIn ? models.activeID == nil : models.activeID == entry.id
    LabeledContent {
      HStack(spacing: 8) {
        switch state {
        case .notDownloaded where entry.isRemote:
          Text("在下方填写并开启").foregroundStyle(.secondary)
        case .notDownloaded:
          Button("下载") { models.download(entry) }
        case .downloading(let fraction):
          ProgressView(value: fraction).frame(width: 90)
          Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
          Button("暂停") { models.pause(entry) }
        case .paused(let fraction):
          Text("已暂停 \(Int(fraction * 100))%").foregroundStyle(.secondary)
          Button("继续") { models.download(entry) }
          Button("删除") { models.delete(entry) }
        case .verifying:
          ProgressView().controlSize(.small)
          Text("正在校验和解压…").foregroundStyle(.secondary)
        case .failed(let reason):
          Text(reason).foregroundStyle(Color.recording).lineLimit(2)
          Button("重试") { models.download(entry) }
        case .installed:
          if inUse {
            Text("使用中").foregroundStyle(.green)
          } else {
            Button("使用") { models.activate(entry.isBuiltIn ? nil : entry) }
          }
          if entry.package != nil {
            Button("删除") { models.delete(entry) }
          }
        }
      }
      .font(.callout)
    } label: {
      Text(entry.name)
      Text(entry.package == nil ? entry.detail : "\(entry.detail) · \(entry.size) · \(entry.source)")
      if !entry.isBuiltIn, inUse {
        RefinerStatusText()
      }
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
