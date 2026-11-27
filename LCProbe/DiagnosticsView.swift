import SwiftUI
import UIKit

/// LCProbe 诊断页：T1–T9 每项一行结果 + 原始日志滚动区 + 一键导出。
///
/// 约定（由骨架文件提供，本文件不重定义）：
/// - LogStore: ObservableObject，LogStore.shared，log(_:)，lines，exportURL()
/// - ProbeOutcome: notRun / passed / failed / notTestable(String)
/// - ProbeState: Identifiable，字段 id / title / detail / outcome / summary / lastRun
/// - AppVersion.display：从 Info.plist 读，绝不写死
/// - 每个探针：final class，static let id / title，
///   static func run(log:completion:)；SystemPlayerProbe 为 run(context:log:completion:)
/// 注意：全文件不使用 C 风格 block 包装任何回调（build 22 闪退的病根）。
struct DiagnosticsView: View {

    @ObservedObject private var logStore = LogStore.shared

    @State private var probes: [ProbeState] = DiagnosticsView.initialStates()
    @State private var isExporting = false
    @State private var runningIDs: Set<String> = []

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                headerView

                List {
                    Section(header: Text("探针 T1–T9")) {
                        ForEach($probes) { $state in
                            probeRow(state: $state)
                        }
                    }

                    Section(header: Text("原始日志")) {
                        ScrollView {
                            Text(logStore.lines.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 180)
                    }
                }
                .listStyle(.insetGrouped)

                exportButton
            }
            .navigationTitle("LCProbe 诊断")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isExporting) {
                ActivityView(activityItems: [logStore.exportURL()])
            }
        }
    }

    // MARK: - 页头

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LCProbe \(AppVersion.display)")
                .font(.headline)
            Text("iOS \(UIDevice.current.systemVersion) · \(Bundle.main.bundleIdentifier ?? "bundle id 未知")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - 探针行

    private func probeRow(state: Binding<ProbeState>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(state.wrappedValue.title)
                    .font(.headline)
                Spacer()
                statusBadge(for: state.wrappedValue.outcome)
            }

            if !state.wrappedValue.summary.isEmpty {
                Text(state.wrappedValue.summary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack {
                if let lastRun = state.wrappedValue.lastRun {
                    Text("最后运行：\(lastRun, style: .date) \(lastRun, style: .time)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("尚未运行")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(runningIDs.contains(state.wrappedValue.id) ? "运行中…" : "运行") {
                    runProbe(id: state.wrappedValue.id)
                }
                .disabled(runningIDs.contains(state.wrappedValue.id))
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(for outcome: ProbeOutcome) -> some View {
        let text: String
        let color: Color
        switch outcome {
        case .notRun:
            text = "未运行"
            color = .gray
        case .passed:
            text = "成功"
            color = .green
        case .failed:
            text = "失败"
            color = .red
        case .notTestable(let reason):
            text = "未能测试：\(reason)"
            color = .orange
        }
        return Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(8)
    }

    // MARK: - 底部导出

    private var exportButton: some View {
        Button("导出日志") {
            isExporting = true
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - 运行分发

    private func runProbe(id: String) {
        runningIDs.insert(id)
        let completion: (ProbeOutcome, String) -> Void = { outcome, summary in
            DispatchQueue.main.async {
                runningIDs.remove(id)
                if let index = probes.firstIndex(where: { $0.id == id }) {
                    probes[index].outcome = outcome
                    probes[index].summary = summary
                    probes[index].lastRun = Date()
                }
            }
        }
        switch id {
        case EntitlementProbe.id:
            EntitlementProbe.run(log: logStore, completion: completion)
        case "T2":
            SystemPlayerProbe.run(context: .appleMusic, log: logStore, completion: completion)
        case "T3":
            SystemPlayerProbe.run(context: .qqMusic, log: logStore, completion: completion)
        case FileShareProbe.id:
            FileShareProbe.run(log: logStore, completion: completion)
        case DarwinNotifyProbe.id:
            DarwinNotifyProbe.run(log: logStore, completion: completion)
        case ShazamProbe.id:
            ShazamProbe.run(log: logStore, completion: completion)
        case LoopbackProbe.id:
            LoopbackProbe.run(log: logStore, completion: completion)
        case GuestMusicProbe.id:
            GuestMusicProbe.run(log: logStore, completion: completion)
        case PiPProbe.id:
            PiPProbe.run(log: logStore, completion: completion)
        default:
            DispatchQueue.main.async {
                runningIDs.remove(id)
                logStore.log("[\(id)] 未知探针 id，未运行")
            }
        }
    }

    // MARK: - 初始状态

    private static func initialStates() -> [ProbeState] {
        [
            ProbeState(id: EntitlementProbe.id, title: EntitlementProbe.title, detail: "T1 权限自读", outcome: .notRun, summary: "", lastRun: nil),
            ProbeState(id: "T2", title: "T2 Apple Music 读歌", detail: "systemMusicPlayer 采样 Apple Music", outcome: .notRun, summary: "", lastRun: nil),
            ProbeState(id: "T3", title: "T3 QQ 音乐对照", detail: "systemMusicPlayer 采样 QQ 音乐", outcome: .notRun, summary: "", lastRun: nil),
            ProbeState(id: FileShareProbe.id, title: FileShareProbe.title, detail: "T4 文件通道", outcome: .notRun, summary: "", lastRun: nil),
            ProbeState(id: DarwinNotifyProbe.id, title: DarwinNotifyProbe.title, detail: "T5 Darwin 通知", outcome: .notRun, summary: "", lastRun: nil),
            ProbeState(id: ShazamProbe.id, title: ShazamProbe.title, detail: "T6 ShazamKit 识别", outcome: .notRun, summary: "", lastRun: nil),
            ProbeState(id: LoopbackProbe.id, title: LoopbackProbe.title, detail: "T7 Loopback 双 Guest", outcome: .notRun, summary: "", lastRun: nil),
            ProbeState(id: GuestMusicProbe.id, title: GuestMusicProbe.title, detail: "T8 LC 内 QQ/网易云", outcome: .notRun, summary: "", lastRun: nil),
            ProbeState(id: PiPProbe.id, title: PiPProbe.title, detail: "T9 系统 PiP", outcome: .notRun, summary: "", lastRun: nil),
        ]
    }
}

/// UIActivityViewController 的 SwiftUI 包装：分享 LogStore.shared.exportURL()。
private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
