import BottariCore
import SwiftUI

/// Two panes side by side. Each pane can browse any provider; for now both show the Mac.
struct MainWindow: View {
    @State private var left = PaneModel(provider: LocalFileProvider())
    @State private var right = PaneModel(
        provider: LocalFileProvider(),
        start: RemotePath(NSHomeDirectory()).appending("Downloads")
    )
    @State private var activeSide: PaneSide = .left

    var body: some View {
        HSplitView {
            PaneView(model: left, isActive: activeSide == .left) { activeSide = .left }
            PaneView(model: right, isActive: activeSide == .right) { activeSide = .right }
        }
        .frame(minWidth: 820, minHeight: 480)
    }
}

enum PaneSide {
    case left, right
}
