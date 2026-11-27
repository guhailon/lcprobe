import Foundation
import Security

/// T1 权限自读：Guest 内用公开 Security 框架 API 自读 entitlements 清单。
///
/// 只用 SecTaskCreateFromSelf() + SecTaskCopyValueForEntitlement，
/// 不调用任何私有 MediaRemote 接口。
/// 判定（通过＝测准了，不是测通了）：
/// - 两个 MediaRemote 读权限都为 nil/false → passed
/// - 任一读到 true → failed（summary 写明哪个为 true）
/// - SecTask 本身建不出来 → notTestable
final class EntitlementProbe {

    static let id = "T1"
    static let title = "T1 权限自读"

    /// 逐项读取的 entitlement 键。
    private static let keys = [
        "com.apple.mediaremote.now-playing-read-access",
        "com.apple.mediaremote.full-now-playing-read-access",
        "get-task-allow",
        "application-identifier",
        "com.apple.security.application-groups",
    ]

    /// 两个 MediaRemote 读权限键。
    private static let mediaRemoteKeys = [
        "com.apple.mediaremote.now-playing-read-access",
        "com.apple.mediaremote.full-now-playing-read-access",
    ]

    static func run(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        log.log("[T1] 开始自读 entitlements")

        guard let task = SecTaskCreateFromSelf() else {
            let summary = "SecTaskCreateFromSelf() 返回 nil，无法自读 entitlements"
            log.log("[T1] \(summary)")
            completion(.notTestable(summary), summary)
            return
        }

        var results: [String: String] = [:]
        for key in keys {
            let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
            let text: String
            if let number = value as? NSNumber {
                text = number.boolValue ? "true" : "false"
            } else if let string = value as? String {
                text = string
            } else if let array = value as? [Any] {
                text = array.map { "\($0)" }.joined(separator: ",")
            } else if value != nil {
                text = "\(value!)"
            } else {
                text = "nil"
            }
            results[key] = text
            log.log("[T1] \(key) = \(text)")
        }

        let trueKeys = mediaRemoteKeys.filter { results[$0] == "true" }
        if !trueKeys.isEmpty {
            let summary = "读到 MediaRemote 读权限为 true：\(trueKeys.joined(separator: "、"))"
            log.log("[T1] \(summary)")
            completion(.failed, summary)
            return
        }

        let summary = "两个读歌权限均不可读（预期内）"
        log.log("[T1] \(summary)")
        completion(.passed, summary)
    }
}
