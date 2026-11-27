import Foundation
import Darwin

/// T1 权限自读：Guest 内用公开 Security 框架 API 自读 entitlements 清单。
///
/// 只用 SecTaskCreateFromSelf() + SecTaskCopyValueForEntitlement，
/// 不调用任何私有 MediaRemote 接口。
/// 注意：这两个符号在 iOS SDK 的 Swift 接口里不可见（import Security 也
/// 找不到），所以沿用 TrollLyricsDesk 正式工程已验证的做法：dlsym 从
/// Security.framework 里拿函数指针再调，不链接、不依赖头文件；
/// 符号不存在就返回 notTestable，不崩。
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

    private static let securityHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/Security.framework/Security",
        RTLD_NOW
    )

    private static func secTaskSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = securityHandle else { return nil }
        return dlsym(handle, name)
    }

    static func run(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        log.log("[T1] 开始自读 entitlements")

        guard let createSym = secTaskSymbol("SecTaskCreateFromSelf"),
              let copySym = secTaskSymbol("SecTaskCopyValueForEntitlement") else {
            let summary = "SecTask 符号解析不到，无法自读 entitlements"
            log.log("[T1] \(summary)")
            completion(.notTestable(summary), summary)
            return
        }
        typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        // SecTaskCopyValueForEntitlement 正确要 3 个参数（task、key、CFErrorRef *error）；
        // 第三个参数传 nil（不要错误对象）。
        typealias CopyFn = @convention(c) (UnsafeMutableRawPointer, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFTypeRef>?
        let createFn = unsafeBitCast(createSym, to: CreateFn.self)
        let copyFn = unsafeBitCast(copySym, to: CopyFn.self)

        guard let task = createFn(nil) else {
            let summary = "SecTaskCreateFromSelf() 返回 nil，无法自读 entitlements"
            log.log("[T1] \(summary)")
            completion(.notTestable(summary), summary)
            return
        }
        // SecTaskCreateFromSelf 是 Create 规则（＋1），用完放掉，不留引用。
        defer { Unmanaged<CFTypeRef>.fromOpaque(task).release() }

        var results: [String: String] = [:]
        for key in keys {
            guard let unmanaged = copyFn(task, key as CFString, nil) else {
                results[key] = "nil"
                log.log("[T1] \(key) = nil")
                continue
            }
            // SecTaskCopyValueForEntitlement 是 Copy 规则（＋1），takeRetainedValue 接管。
            let value: CFTypeRef = unmanaged.takeRetainedValue()
            let text: String
            if let number = value as? NSNumber {
                text = number.boolValue ? "true" : "false"
            } else if let string = value as? String {
                text = string
            } else if let array = value as? [Any] {
                text = array.map { "\($0)" }.joined(separator: ",")
            } else {
                text = "\(value)"
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
