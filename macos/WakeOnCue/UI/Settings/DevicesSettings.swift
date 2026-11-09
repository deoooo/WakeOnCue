import CoreImage.CIFilterBuiltins
import SwiftUI

/// "设备与回传": the phones paired with this Mac and how more are added.
struct DevicesSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var preferences = model.preferences
    let sync = model.sync
    Form {
      Section("已配对") {
        if sync.devices.isEmpty {
          Text("还没有配对的 iPhone。").foregroundStyle(.secondary)
        }
        let counts = model.store.remoteSegmentCounts()
        ForEach(sync.devices) { device in
          LabeledContent {
            Button("取消配对") { sync.unpair(device) }
          } label: {
            Text(device.name)
            Text(status(device, counts: counts[device.id]))
            if case .some(.some(let transfer)) = sync.connected[device.id], transfer.total > 0 {
              ProgressView(value: Double(transfer.received), total: Double(transfer.total)).frame(maxWidth: 220)
            }
          }
        }
      }

      Section {
        Toggle("自动回传录音", isOn: $preferences.autoSync)
        Toggle("内容相同时自动合并", isOn: $preferences.mergeSameContent)
        Toggle("允许附近的 iPhone 请求配对码", isOn: $preferences.allowPairRequests)
          .onChange(of: preferences.allowPairRequests) { sync.updatePairListener() }
        LabeledContent("用二维码配对") {
          Button(sync.invitation == nil ? "显示二维码" : "刷新二维码") { sync.newInvitation() }
        }
        if let invitation = sync.invitation {
          HStack(alignment: .center, spacing: 16) {
            QRCode(text: invitation.url.absoluteString)
              .frame(width: 148, height: 148)
            TimelineView(.periodic(from: .now, by: 1)) { context in
              let left = Int(invitation.expires.timeIntervalSince(context.date))
              Text(left > 0 ? "\(left / 60):\(String(format: "%02d", left % 60)) 内有效" : "已过期，请刷新")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if let issue = sync.issue {
          Text(issue).font(.caption).foregroundStyle(Color.recording)
        }
      } header: {
        Text("连接")
      } footer: {
        Text("在 iPhone 上打开 WakeOnCue › 设置 › Mac › 连接 Mac。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func status(_ device: PairedDevice, counts: (total: Int, waiting: Int, latest: Date?)?) -> String {
    var parts: [String] = []
    if case .some(let transfer) = model.sync.connected[device.id] {
      parts.append(transfer.map { "正在接收 \(TimeText.bytes($0.received)) / \(TimeText.bytes($0.total))" } ?? "已连接")
    } else if let lastSeen = device.lastSeen {
      parts.append("\(TimeText.relativeDay(lastSeen)) \(TimeText.clock(lastSeen))")
    } else {
      parts.append("还没有连接过")
    }
    if let counts, counts.waiting > 0 {
      parts.append("\(counts.waiting) 段等待合并")
    }
    return parts.joined(separator: " · ")
  }
}

/// A QR code for a string.
private struct QRCode: View {
  let text: String

  var body: some View {
    if let image = Self.image(text) {
      Image(decorative: image, scale: 1)
        .interpolation(.none)
        .resizable()
        .accessibilityLabel("配对二维码")
    }
  }

  private static func image(_ text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    return CIContext().createCGImage(output, from: output.extent)
  }
}
