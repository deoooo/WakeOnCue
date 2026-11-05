import SwiftUI

/// "这是谁…": names the speaker of a sentence. For 说话人 N the whole day is renamed; with
/// 记住声音 on, the voice is also remembered for later recordings.
struct NameSpeakerSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let sentence: Sentence
  @State private var name = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("这是谁？").font(.headline)
      Text("「\(sentence.text.prefix(60))」").font(.callout).foregroundStyle(.secondary).lineLimit(3)
      TextField("名字", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
      if !model.voices.people.isEmpty {
        FlowLayout(spacing: 6) {
          ForEach(model.voices.people) { person in
            Button(person.name) { name = person.name }.controlSize(.small)
          }
        }
      }
      Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("确定", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 380)
    .onAppear { name = sentence.speakerName?.hasPrefix("说话人 ") == true ? "" : sentence.speakerName ?? "" }
  }

  private var note: String {
    var text = sentence.speakerName?.hasPrefix("说话人 ") == true ? "当天所有「\(sentence.speakerName ?? "")」都会改成这个名字。" : "只改这一句。"
    text += model.preferences.rememberVoices ? "会记住这个声音，之后自动认出。" : "没有打开「记住声音」，不会保存声纹。"
    return text
  }

  private func save() {
    let value = name
    Task { await model.voices.name(sentence, as: value) }
    dismiss()
  }
}
