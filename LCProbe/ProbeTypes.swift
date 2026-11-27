import Foundation

/// 单项探针的结论。成功 = 测准了（有确定的 yes/no + 日志），不是功能通了。
enum ProbeOutcome {
    case notRun
    case passed
    case failed
    case notTestable(String)
}

/// 诊断页上的一行探针状态。
struct ProbeState: Identifiable {
    let id: String
    let title: String
    let detail: String
    var outcome: ProbeOutcome = .notRun
    var summary = ""
    var lastRun: Date? = nil
}

/// 探针自身版本号：只从 Bundle 读，绝不写死。
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (build \(build))"
    }
}
