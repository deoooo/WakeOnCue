import CoreImage.CIFilterBuiltins
import SwiftUI

/// "设备与回传": the phones paired with this Mac and the QR code that adds one.
struct DevicesSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var preferences = model.preferences
    let sync = model.sync
    Form {
      Section {
        Toggle(isOn: $preferences.autoSync) {
          Text("自动回传 iPhone 和手表的录音")
          Text("只走本地网络，用配对时的密钥加密。iPhone 连上这台 Mac 后才会转发。")
        }
        Toggle(isOn: $preferences.mergeSameContent) {
          Text("内容相同时自动合并")
          Text("保留 Mac 的音频，并补上 Mac 没录到的时段。内容不同则都保留。")
        }
        if let issue = sync.issue {
          Text(issue).font(.caption).foregroundStyle(Color.recording)
        }
      }

      Section("已配对的设备") {
        if sync.devices.isEmpty {
          Text("还没有配对的设备。").foregroundStyle(.secondary)
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
        HStack(alignment: .top, spacing: 20) {
          QRCode(text: sync.invitation?.url.absoluteString)
            .frame(width: 168, height: 168)
          VStack(alignment: .leading, spacing: 8) {
            Text("添加 iPhone 和手表").font(.headline)
            Text("1. 在 iPhone 上打开 WakeOnCue，进入“设置 › 连接 Mac”")
            Text("2. 扫描这个二维码")
            Text("3. iPhone 配对成功后，手表会自动关联")
            HStack {
              Button(sync.invitation == nil ? "显示二维码" : "刷新二维码") { sync.newInvitation() }
              if let invitation = sync.invitation {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                  let left = Int(invitation.expires.timeIntervalSince(context.date))
                  Text(left > 0 ? "\(left / 60):\(String(format: "%02d", left % 60)) 内有效，只能使用一次" : "已过期，请刷新")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
          .font(.callout)
        }
      } footer: {
        Text("二维码里有这台 Mac 的地址和一把只给这台 iPhone 用的密钥。之后的回传都用这把密钥加密；取消配对后它就失效。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func status(_ device: PairedDevice, counts: (total: Int, waiting: Int, latest: Date?)?) -> String {
    var parts: [String] = []
    if case .some(let transfer) = model.sync.connected[device.id] {
      parts.append(transfer.map { "已连接 · 正在接收 \(TimeText.bytes($0.received)) / \(TimeText.bytes($0.total))" } ?? "已连接")
    } else if let lastSeen = device.lastSeen {
      parts.append("上次连接 \(TimeText.relativeDay(lastSeen)) \(TimeText.clock(lastSeen))")
    } else {
      parts.append("已配对，还没有连接过")
    }
    if let counts, counts.total > 0 {
      parts.append("共收到 \(counts.total) 段" + (counts.waiting > 0 ? "，\(counts.waiting) 段等待合并" : ""))
    }
    return parts.joined(separator: " · ")
  }
}

/// A QR code for a string, or a placeholder.
private struct QRCode: View {
  let text: String?

  var body: some View {
    if let text, let image = Self.image(text) {
      Image(decorative: image, scale: 1)
        .interpolation(.none)
        .resizable()
        .accessibilityLabel("配对二维码")
    } else {
      RoundedRectangle(cornerRadius: 8).fill(Color.soft)
        .overlay { Text("点“显示二维码”").font(.caption).foregroundStyle(.secondary) }
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
