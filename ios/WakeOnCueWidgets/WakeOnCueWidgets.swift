import SwiftUI
import WidgetKit

@main
struct WakeOnCueWidgetBundle: WidgetBundle {
  var body: some Widget {
    RecordingLiveActivityWidget()
    RecordingControlWidget()
  }
}
