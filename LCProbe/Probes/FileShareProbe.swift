import Foundation

/// T4 文件共享：Guest 与宿主的文件路径是否打通（FINDINGS §7 T4、§4.5）。
///
/// 做法：
/// - 打印 NSHomeDirectory()、Documents 绝对路径、环境变量 LC_HOME_PATH；
/// - 从 LC_HOME_PATH 或 bundle 路径里推断 Team ID，拼宿主的 SideStore
///   App Group ID（group.com.SideStore.SideStore.<TeamID>），拼不出就记
///   notTestable 并写明原因——绝不硬编码某个 Team ID；
/// - 写一个带时间戳的 JSON 快照到 Documents/LCProbeSnapshot.json
///   （写临时文件再原子重命名），立即读回比对内容一致；
/// - 再尝试在 LC_HOME_PATH 下的 Documents/ 写同名快照并读回
///   （写失败只记录，不算失败）。
/// - v0.1.2 一键跨 Guest：每实例一个稳定 UUID（见 CrossGuest），
///   每次运行把快照写到共享目录（LC_HOME_PATH/Documents）下
///   LCProbeSnapshot-<instanceID>.json，再枚举该目录下全部
///   LCProbeSnapshot-*.json，逐个记实例 ID 与时间戳，并给一条明确的
///   跨实例 verdict：看到另一实例的快照，还是只看到自己的。
/// 判定（通过＝测准了）：
/// - 任一位置写后读回一致 → passed；
/// - 全部读不到 → failed（summary 写清双方实际路径）；
/// - 连 Documents 都写不了 → notTestable。
final class FileShareProbe {

    static let id = "T4"
    static let title = "T4 文件通道"

    private static let snapshotFileName = "LCProbeSnapshot.json"
    private static let snapshotPrefix = "LCProbeSnapshot-"

    static func run(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        log.log("[T4] 开始文件共享探针")

        let instanceID = CrossGuest.instanceID
        log.log("[T4] 本实例 ID = \(instanceID)（每安装一份一个 UUID，存 UserDefaults）")

        let home = NSHomeDirectory()
        log.log("[T4] NSHomeDirectory() = \(home)")

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            let summary = "拿不到 Documents 目录 URL，无法写快照"
            log.log("[T4] \(summary)")
            completion(.notTestable(summary), summary)
            return
        }
        log.log("[T4] Documents = \(documentsURL.path)")

        let lcHomePath = ProcessInfo.processInfo.environment["LC_HOME_PATH"]
        if let lcHomePath {
            log.log("[T4] LC_HOME_PATH = \(lcHomePath)")
        } else {
            log.log("[T4] LC_HOME_PATH = 无")
        }

        // App Group：只用从环境/路径推断出的 Team ID 拼宿主的 group ID。
        let bundlePath = Bundle.main.bundlePath
        let teamID = extractTeamID(from: lcHomePath) ?? extractTeamID(from: bundlePath)
        if let teamID {
            let groupID = "group.com.SideStore.SideStore.\(teamID)"
            log.log("[T4] 推断 Team ID = \(teamID)，group ID = \(groupID)")
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
                log.log("[T4] containerURL(\(groupID)) = \(containerURL.path)")
            } else {
                log.log("[T4] containerURL(\(groupID)) = nil（该 group 容器不可达）")
            }
        } else {
            log.log("[T4] 无法从 LC_HOME_PATH 或 bundle 路径推断 Team ID，跳过 App Group 容器探测（原因：路径中没有可识别的 Team ID 片段）")
        }

        // 带时间戳的快照内容（含本实例 ID，供另一实例认出是谁写的）。
        let stamp = ISO8601DateFormatter().string(from: Date())
        let snapshot: [String: Any] = [
            "probe": "LCProbe",
            "test": "T4",
            "time": stamp,
            "instanceID": instanceID,
            "home": home,
            "documents": documentsURL.path,
            "lcHomePath": lcHomePath ?? "",
            "nonce": UUID().uuidString,
        ]
        guard let snapshotData = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else {
            let summary = "快照 JSON 序列化失败，无法写文件"
            log.log("[T4] \(summary)")
            completion(.notTestable(summary), summary)
            return
        }

        // (1) 自家 Documents：写临时文件再原子重命名，立即读回比对。
        let ownSnapshotURL = documentsURL.appendingPathComponent(snapshotFileName)
        let ownWriteOK = writeAtomically(data: snapshotData, to: ownSnapshotURL, log: log)
        var ownReadOK = false
        if ownWriteOK {
            ownReadOK = readBackMatches(data: snapshotData, at: ownSnapshotURL, log: log, label: "自家 Documents")
        } else {
            log.log("[T4] 自家 Documents 写快照失败：\(ownSnapshotURL.path)")
        }

        // (2) LC_HOME_PATH 下的 Documents/：写失败只记录，不算失败。
        var hostPathDescription = "无 LC_HOME_PATH，未尝试宿主侧"
        var hostReadOK = false
        if let lcHomePath {
            let hostDocumentsURL = URL(fileURLWithPath: lcHomePath)
                .appendingPathComponent("Documents")
                .appendingPathComponent(snapshotFileName)
            hostPathDescription = hostDocumentsURL.path
            if writeAtomically(data: snapshotData, to: hostDocumentsURL, log: log) {
                hostReadOK = readBackMatches(data: snapshotData, at: hostDocumentsURL, log: log, label: "LC_HOME_PATH/Documents")
            } else {
                log.log("[T4] LC_HOME_PATH/Documents 写快照失败（只记录，不算失败）：\(hostDocumentsURL.path)")
            }
        }

        // (3) v0.1.2 一键跨 Guest：写本实例的快照到共享目录，再枚举全部实例快照。
        let sharedDir = CrossGuest.sharedDocumentsURL()
        let ownInstanceURL = sharedDir.appendingPathComponent("\(snapshotPrefix)\(instanceID).json")
        if writeAtomically(data: snapshotData, to: ownInstanceURL, log: log) {
            log.log("[T4] 已写本实例快照到共享目录：\(ownInstanceURL.path)")
        } else {
            log.log("[T4] 共享目录写本实例快照失败（只记录，不算失败）：\(ownInstanceURL.path)")
        }
        let (snapshotCount, otherVisible) = enumerateSnapshots(in: sharedDir, ownID: instanceID, log: log)
        let crossVerdict: String
        if otherVisible {
            crossVerdict = "跨实例可见：是——共享目录下看到另一实例的快照（共 \(snapshotCount) 个），文件通道跨 Guest 通"
        } else {
            crossVerdict = "跨实例可见：否——共享目录下只看到自己的快照（共 \(snapshotCount) 个），另一实例可能未运行 T4 或共享目录不互通"
        }
        log.log("[T4] \(crossVerdict)")

        if ownReadOK || hostReadOK {
            let whereOK = [ownReadOK ? "自家 Documents" : nil, hostReadOK ? "LC_HOME_PATH/Documents" : nil]
                .compactMap { $0 }.joined(separator: "、")
            let summary = "快照写后读回一致（\(whereOK)）；自家 Documents=\(documentsURL.path)，宿主侧=\(hostPathDescription)；\(crossVerdict)"
            log.log("[T4] \(summary)")
            completion(.passed, summary)
            return
        }

        if !ownWriteOK {
            // 连自家 Documents 都写不了：环境本身不可写，无法判断通道。
            let summary = "连自家 Documents 都写不了快照（\(ownSnapshotURL.path)），无法判断文件通道；\(crossVerdict)"
            log.log("[T4] \(summary)")
            completion(.notTestable(summary), summary)
            return
        }

        let summary = "全部读不到：自家 Documents=\(documentsURL.path)（写后读回不一致或读失败），宿主侧=\(hostPathDescription)；\(crossVerdict)"
        log.log("[T4] \(summary)")
        completion(.failed, summary)
    }

    /// 枚举共享目录下全部 LCProbeSnapshot-<instanceID>.json，
    /// 逐个记实例 ID 与时间戳。返回（快照个数，是否看到另一实例）。
    private static func enumerateSnapshots(in dir: URL, ownID: String, log: LogStore) -> (count: Int, otherVisible: Bool) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            log.log("[T4] 共享目录列不出：\(dir.path)")
            return (0, false)
        }
        let snapshots = files
            .filter { $0.lastPathComponent.hasPrefix(snapshotPrefix) && $0.lastPathComponent.hasSuffix(".json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var otherVisible = false
        for file in snapshots {
            var parsedID: String?
            var parsedTime = "（解析不出）"
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parsedID = obj["instanceID"] as? String
                parsedTime = obj["time"] as? String ?? parsedTime
            }
            if let parsedID {
                let whose = (parsedID == ownID) ? "本实例" : "另一实例"
                if parsedID != ownID { otherVisible = true }
                log.log("[T4] 快照 \(file.lastPathComponent)：instanceID=\(parsedID) time=\(parsedTime)（\(whose)）")
            } else {
                log.log("[T4] 快照 \(file.lastPathComponent)：instanceID 解析不出 time=\(parsedTime)（无法认出是谁的，不计入另一实例）")
            }
        }
        log.log("[T4] 共享目录 \(dir.path) 下共 \(snapshots.count) 个实例快照")
        return (snapshots.count, otherVisible)
    }

    /// 写临时文件再原子重命名到目标路径。返回是否成功。
    /// 临时文件名按目标文件名派生（含实例 ID 的目标各有各的临时文件，
    /// 双实例同时写共享目录也不会互相覆盖对方的临时文件）。
    private static func writeAtomically(data: Data, to destination: URL, log: LogStore) -> Bool {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            // 目标已存在时先删掉，再把临时文件移过去（原子重命名，避免读到半截文件）。
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            log.log("[T4] 已写快照：\(destination.path)")
            return true
        } catch {
            log.log("[T4] 写快照失败 \(destination.path)：\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }

    /// 读回文件并与写入内容逐字节比对。返回是否一致。
    private static func readBackMatches(data: Data, at url: URL, log: LogStore, label: String) -> Bool {
        do {
            let read = try Data(contentsOf: url)
            if read == data {
                log.log("[T4] \(label)读回一致：\(url.path)")
                return true
            }
            log.log("[T4] \(label)读回内容不一致：\(url.path)（读到 \(read.count) 字节，写入 \(data.count) 字节）")
            return false
        } catch {
            log.log("[T4] \(label)读回失败 \(url.path)：\(error.localizedDescription)")
            return false
        }
    }

    /// 从一条路径里推断 Team ID：取路径片段中符合 10 位大写字母/数字
    /// 形态的一段。找不到返回 nil（调用方据此记 notTestable/跳过）。
    /// 注意：这只是启发式推断，Team ID 的真实形态以签名账号为准。
    private static func extractTeamID(from path: String?) -> String? {
        guard let path else { return nil }
        let components = (path as NSString).pathComponents
        let pattern = "^[A-Z0-9]{10}$"
        for component in components {
            if component.range(of: pattern, options: .regularExpression) != nil {
                return component
            }
        }
        return nil
    }
}
