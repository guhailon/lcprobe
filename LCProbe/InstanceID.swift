import Foundation

/// 跨实例身份与共享目录：v0.1.2 一键跨 Guest 探针（T4/T7）共用。
///
/// - instanceID：每安装一份一个 UUID，存 UserDefaults，卸载重装才变。
///   LCProbe 与 LCProbeB 的 bundle ID 不同，各自一份 UserDefaults，
///   天然就是两个不同的实例 ID，正好用来区分双实例。
/// - sharedDocumentsURL：两个 Guest 实例都能看到的那份 Documents。
///   有 LC_HOME_PATH 就用 LC_HOME_PATH/Documents，否则退回自家 Documents
///  （此时只能看到自己，跨实例 verdict 会如实记“只看到自己”）。
enum CrossGuest {

    private static let instanceIDKey = "com.guhailong.lcprobe.instanceID"

    static var instanceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: instanceIDKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: instanceIDKey)
        return fresh
    }

    static func sharedDocumentsURL() -> URL {
        if let lcHome = ProcessInfo.processInfo.environment["LC_HOME_PATH"], !lcHome.isEmpty {
            return URL(fileURLWithPath: lcHome).appendingPathComponent("Documents")
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}
