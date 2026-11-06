import AppKit
import SwiftUI

/// "声音": telling speakers apart, remembering named voices, and the user's own voiceprint.
struct VoicesSettings: View {
  @Environment(AppModel.self) private var model
  private static let passage = "今天我们讨论的是下周的上线计划，请大家先看一下这份文档，然后说说自己的想法。告警这块谁来跟进，周五之前要有一个结果。"

  var body: some View {
    let voices = model.voices
    let preferences = model.preferences
    Form {
      Section {
        Toggle(isOn: Binding(get: { preferences.splitSpeakers }, set: { on in
          preferences.splitSpeakers = on
          if on { Task { await voices.prepareModel() } }
        })) {
          Text("区分说话人")
          Text("把身边其他人标成说话人 2、3…，可以在录音里给他们命名。不保存声纹。")
        }
        Toggle(isOn: Binding(get: { preferences.rememberVoices }, set: setRemembering)) {
          Text("记住声音")
          Text("在之后的录音里自动认出已命名的人。声纹属于生物识别信息，开启前会再次说明。")
        }
        modelStatus(voices.modelState)
      }

      Section("我的声音") {
        LabeledContent {
          HStack {
            switch voices.enrollment {
            case .listening:
              Button("取消") { voices.cancelEnrollment() }
              Button("完成") { voices.finishEnrollment() }.buttonStyle(.borderedProminent)
            default:
              if voices.myVoice != nil { Button("删除") { voices.forgetMyVoice() } }
              Button(voices.myVoice == nil ? "开始录入" : "重新录入") { Task { await voices.startEnrollment() } }
            }
          }
        } label: {
          Text(voices.myVoice == nil ? "还没有录入" : "已录入")
          Text("Mac 麦克风里你的声音默认就是“我”。录入后改为按声音区分“我”和“他人”，也用于以后手表和 iPhone 的录音。")
        }
        if case .listening(let since) = voices.enrollment {
          VStack(alignment: .leading, spacing: 8) {
            Text("请用平常的语速读出下面这段话，读完点「完成」：").font(.callout)
            Text(Self.passage).font(.system(size: 15)).padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.soft))
            TimelineView(.periodic(from: since, by: 1)) { context in
              Text("已录 \(Int(context.date.timeIntervalSince(since))) 秒，读满 10 秒以上即可").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if voices.myVoice == nil {
          learnedStatus(voices)
        }
        if voices.isRecheckingPast {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("正在按你的声音重新检查最近 7 天的说话人，改动的小时会重新总结…")
          }
          .font(.caption).foregroundStyle(.secondary)
        }
        if let calibration = voices.calibration, voices.myVoice != nil {
          Text(calibration).font(.caption).foregroundStyle(.secondary)
        }
        if case .failed(let reason) = voices.enrollment {
          Text(reason).font(.caption).foregroundStyle(Color.recording)
        }
        Text("朗读的音频只在内存里用来计算声纹，用完即丢，只保存声纹。").font(.caption).foregroundStyle(.secondary)
      }

      Section {
        if voices.people.isEmpty {
          Text("还没有记住的声音。打开“记住声音”后，在录音里右键一句话选“这是谁…”给说话人命名，之后就会自动认出这个人。")
            .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(voices.people) { person in
          LabeledContent {
            Button("删除") { voices.forget(person) }
          } label: {
            Text(person.name)
            Text("上次听到：\(TimeText.relativeDay(person.lastHeard)) · 样本 \(person.samples) 句")
          }
        }
      } header: {
        Text("已记住的声音")
      } footer: {
        Text("声纹只保存在这台 Mac 的钥匙串里，不上传。一年没再听到的声音会自动删除。关闭“记住声音”会删除全部声纹，录音里已有的名字会保留。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private func modelStatus(_ state: Voices.ModelState) -> some View {
    switch state {
    case .missing:
      Text("首次使用会从 sherpa-onnx 官方发布下载声纹模型（约 28 MB）。").font(.caption).foregroundStyle(.secondary)
    case .downloading:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("正在下载声纹模型…").font(.caption).foregroundStyle(.secondary)
      }
    case .ready:
      EmptyView()
    case .failed(let reason):
      Text(reason).font(.caption).foregroundStyle(Color.recording)
    }
  }

  private func setRemembering(_ on: Bool) {
    let alert = NSAlert()
    if on {
      alert.messageText = "记住别人的声音？"
      alert.informativeText = """
        开启后，你在录音里给说话人命名时，WakeOnCue 会保存这个人的声纹，之后的录音里自动认出他。

        声纹属于生物识别信息，很多地区要求先征得本人同意。声纹只保存在这台 Mac 的钥匙串里，不上传；\
        一年没再听到会自动删除；关闭后会删除全部声纹。
        """
      alert.addButton(withTitle: "取消")
      alert.addButton(withTitle: "开启")
    } else {
      alert.messageText = "关闭并删除全部声纹？"
      alert.informativeText = "已记住的 \(model.voices.people.count) 个声音会从钥匙串删除。录音里已有的名字会保留。"
      alert.addButton(withTitle: "取消")
      alert.addButton(withTitle: "关闭并删除")
    }
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    model.voices.setRemembering(on)
    if on { Task { await model.voices.prepareModel() } }
  }

  /// Without enrolling, the voice is learned from what the microphone hears in online meetings.
  @ViewBuilder private func learnedStatus(_ voices: Voices) -> some View {
    if let learned = voices.learnedVoice {
      HStack {
        Text(learned.isUsable
          ? (voices.learnedVoiceReady
            ? "已从线上会议里学到你的声音（\(learned.sentences) 句），用来区分“我”和“他人”。录入后改用录入的声音。"
            : "已从线上会议里学到声音（\(learned.sentences) 句），正在用最近的录音确认它是不是你…")
          : "正在从线上会议里学你的声音：\(learned.sentences)/\(LearnedVoice.minimumSentences) 句。")
        Spacer()
        Button("忘掉") { voices.forgetLearnedVoice() }
      }
      .font(.caption).foregroundStyle(.secondary)
    } else {
      Text("还没有录入时，麦克风录到的话都算“我”，总结里写成“现场”，不当成你说的。开线上会议时会自动学你的声音（需要先下载声纹模型）。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

}
