import SwiftUI

/// "提问": ask about the recordings; answers cite the original words, and a citation jumps there.
struct AskPanel: View {
  @Environment(AppModel.self) private var model
  @State private var question = ""
  @FocusState private var focused: Bool

  var body: some View {
    let asking = model.asking
    VStack(spacing: 0) {
      HStack {
        Text("提问").font(.system(size: 13, weight: .semibold))
        if let engine = model.summaries.engineName {
          Text(engine).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if !asking.exchanges.isEmpty {
          Button("清空") { asking.clear() }.buttonStyle(.link).font(.caption)
        }
        Button { model.ui.asking = false } label: { Image(systemName: "xmark") }
          .buttonStyle(.borderless)
          .accessibilityLabel("关闭提问")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if asking.exchanges.isEmpty {
              Text("问问你的录音，比如“告警谁负责？”“昨天和客户谈了什么？”回答会注明出处，点时间可以跳到原话。")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            ForEach(asking.exchanges) { exchange in
              exchangeView(exchange).id(exchange.id)
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: asking.exchanges.count) {
          if let last = asking.exchanges.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
        }
      }
      Divider()
      VStack(alignment: .leading, spacing: 6) {
        Text(footnote).font(.caption).foregroundStyle(.secondary)
        HStack {
          TextField("问问你的录音", text: $question)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(send)
            .disabled(asking.isWorking)
          Button("问", action: send).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking.isWorking)
        }
      }
      .padding(14)
    }
    .background(.bar)
    .onAppear { focused = true }
  }

  private var footnote: String {
    var text = "不会搜索标为私人或已删除的时段。"
    if let destination = model.summaries.destination { text += "问题和找到的原话会发送到 \(destination)。" }
    return text
  }

  private func send() {
    model.asking.ask(question)
    question = ""
  }

  @ViewBuilder private func exchangeView(_ exchange: Asking.Exchange) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(exchange.question)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.highlight))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .textSelection(.enabled)
      if exchange.working {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("正在查找和整理…").foregroundStyle(.secondary)
        }
        .font(.callout)
      } else if let error = exchange.error {
        Text(error).font(.callout).foregroundStyle(Color.recording)
      } else {
        ForEach(Array(exchange.answer.enumerated()), id: \.offset) { _, paragraph in
          VStack(alignment: .leading, spacing: 4) {
            Text(paragraph.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
            FlowLayout(spacing: 6) {
              ForEach(paragraph.cites.compactMap { exchange.sources[$0] }) { sentence in
                Button("引用 · \(TimeText.relativeDay(sentence.start)) \(TimeText.seconds(sentence.start))") {
                  model.cite(sentence.id)
                }
                .controlSize(.small)
                .help("\(sentence.speaker.label)：\(sentence.text)")
              }
            }
          }
        }
      }
    }
  }
}
