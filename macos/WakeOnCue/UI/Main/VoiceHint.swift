import SwiftUI

/// Until the user's voice is known, everyone the microphone hears is "我". Says so on a day with
/// recordings, with a way to fix it.
struct VoiceHint: View {
  @Environment(AppModel.self) private var model
  let data: DayData

  var body: some View {
    if !model.voices.knowsMyVoice, !model.preferences.voiceHintDismissed, !data.rows.isEmpty {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: "person.wave.2").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text("说话人还分不出你和别人").fontWeight(.semibold)
          Text("Mac 麦克风录到的话现在都算“我”，总结里写成“现场”。录 20 秒你的声音，就能把身边其他人分出来，最近 7 天的录音也会重新区分。")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        Button("录入我的声音") { model.showSettings(.voices) }
          .buttonStyle(.borderedProminent)
        Button {
          model.preferences.voiceHintDismissed = true
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("不再提示")
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.soft))
      .padding(.bottom, 18)
    }
  }
}
