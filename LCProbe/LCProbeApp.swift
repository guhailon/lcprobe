import SwiftUI

/// LCProbe 入口：只显示诊断页，无其他功能。
@main
struct LCProbeApp: App {
    var body: some Scene {
        WindowGroup {
            DiagnosticsView()
        }
    }
}
