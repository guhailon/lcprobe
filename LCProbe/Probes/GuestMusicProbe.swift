// GuestMusicProbe.swift
// LCProbe v0.1 — T8
//
// 目标：研究 LC 内部 QQ 音乐及网易云音乐是否存在可用且获准的播放信息接口，
// 区分系统原生音乐 App 与 LC 内部音乐 App。
//
// 三件做法，全部只读、不写、不切前台：
//   (a) systemMusicPlayer 采样（与 T3 系统级 QQ 音乐对照）；
//   (b) 只读检查这两个 App 作为 Guest 时容器内是否有可读的播放状态文件或偏好；
//   (c) 只用 canOpenURL 探测公开 URL scheme 是否可查询，绝不实际 openURL。
//
// 约定：LogStore.shared / log(_:)；ProbeOutcome；completion 只调一次；
// 绝不用 C block 约定包装任何回调。
//
// 用法说明：本探针一次 run() 只采“当前正在播”的那一个音乐 App。
// 操作人先在 LC 内放 QQ 音乐 → 跑一次；再在 LC 内放网易云音乐 → 再跑一次；
// 两次日志对照 T3（系统级 QQ 音乐）的结果，看 LC 内外是否一致。

import Foundation
import MediaPlayer
import UIKit

final class GuestMusicProbe {

    static let id = "T8"
    static let title = "LC 内 QQ 音乐 / 网易云音乐播放信息接口"

    /// bundle ID 特征：用于在容器目录里认出这两个 App。
    private static let targetBundleHints = ["qqmusic", "netease", "cloudmusic"]

    /// 公开 scheme（公开文档里的常见值），只做 canOpenURL 查询，绝不 openURL。
    private static let probeSchemes = ["qqmusic", "orpheus"]

    /// 文件名特征：只记文件名，不读内容。
    private static let playbackFileHints = ["play", "nowplaying", "player", "state", "recent", "history"]

    static func run(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        log.log("[T8] 开始：LC 内 QQ 音乐 / 网易云音乐播放信息接口探针")
        log.log("[T8] 注意：一次 run 只采当前正在播的一个 App；QQ 音乐与网易云音乐各跑一次，再与 T3 对照")

        // ---------- (a) systemMusicPlayer 采样：3 次 ----------
        var sampleLines: [String] = []
        let player = MPMusicPlayerController.systemMusicPlayer
        let sampleGroup = DispatchGroup()
        for i in 1...3 {
            sampleGroup.enter()
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i - 1) * 1.5) {
                let item = player.nowPlayingItem
                let title = item?.title ?? "nil"
                let artist = item?.artist ?? "nil"
                let time = player.currentPlaybackTime
                let state = player.playbackState.rawValue
                let line = "采样\(i)：title=\(title) artist=\(artist) time=\(time) playbackState=\(state)"
                sampleLines.append(line)
                log.log("[T8] (a) systemMusicPlayer \(line)")
                sampleGroup.leave()
            }
        }

        sampleGroup.notify(queue: .main) {
            let sampleSummary: String
            if sampleLines.contains(where: { !$0.contains("title=nil") }) {
                sampleSummary = "(a) systemMusicPlayer 采样 3 次：读到非 nil 歌名（见日志），与 T3 对照看 LC 内外是否一致"
            } else {
                sampleSummary = "(a) systemMusicPlayer 采样 3 次：nowPlayingItem 全为 nil（见日志），与 T3 对照看 LC 内外是否一致"
            }
            log.log("[T8] \(sampleSummary)")

            // ---------- (b) 只读检查容器内播放状态文件 ----------
            let (containerRoot, containerNote) = resolveContainerRoot(log: log)
            var containerSummary: String
            var containerUsable = false
            if let root = containerRoot {
                containerUsable = true
                containerSummary = inspectGuestContainers(root: root, log: log)
            } else {
                containerSummary = "(b) 容器根目录推断不出来，做不了：\(containerNote)"
                log.log("[T8] \(containerSummary)")
            }

            // ---------- (c) URL scheme 探测：只 canOpenURL ----------
            var schemeLines: [String] = []
            for scheme in probeSchemes {
                guard let url = URL(string: scheme + "://") else {
                    schemeLines.append("\(scheme):// 构造 URL 失败")
                    continue
                }
                let canOpen = UIApplication.shared.canOpenURL(url)
                let line = "\(scheme):// canOpenURL=\(canOpen)"
                schemeLines.append(line)
                log.log("[T8] (c) \(line)（只查询，未 openURL）")
            }
            log.log("[T8] (c) 备注：未在 LSApplicationQueriesSchemes 声明的 scheme，canOpenURL 可能恒为 false，此结果只记实测值")
            let schemeSummary = "(c) scheme 查询：" + schemeLines.joined(separator: "；")

            // ---------- 判定 ----------
            let summary = [sampleSummary, containerSummary, schemeSummary].joined(separator: "\n")
            if !containerUsable {
                log.log("[T8] 结论：notTestable（容器根目录推断不出来，(b) 做不了；(a)(c) 结果照常记录）")
                completion(.notTestable("容器根目录推断不出来：\(containerNote)；(a)(c) 结果见日志"), summary)
            } else {
                log.log("[T8] 结论：passed（三件做完，每件都有明确记录；有什么写什么，不推测）")
                completion(.passed, summary)
            }
        }
    }

    // MARK: - (b) 容器根目录推断

    /// 按报告 §3.4：数据容器在 Documents/Data/Application/<UUID>/，
    /// 或 App Group 下 LiveContainer/Data/Application/<UUID>/；
    /// 原 HOME 保存在 LC_HOME_PATH 环境变量（LiveContainerMain L1070）。
    /// 返回值：(容器根目录 URL, 推断失败时的原因)。
    private static func resolveContainerRoot(log: LogStore) -> (URL?, String) {
        // 优先用 LC_HOME_PATH（宿主原 HOME）。
        if let lcHome = ProcessInfo.processInfo.environment["LC_HOME_PATH"], !lcHome.isEmpty {
            let dataRoot = URL(fileURLWithPath: lcHome)
                .appendingPathComponent("Documents")
                .appendingPathComponent("Data")
                .appendingPathComponent("Application")
            if FileManager.default.fileExists(atPath: dataRoot.path) {
                log.log("[T8] (b) 容器根目录：\(dataRoot.path)（由 LC_HOME_PATH 推断）")
                return (dataRoot, "")
            }
            log.log("[T8] (b) LC_HOME_PATH=\(lcHome)，但其下 Documents/Data/Application/ 不存在")
        } else {
            log.log("[T8] (b) 环境变量 LC_HOME_PATH 不存在或为空")
        }

        // 备用：App Group 下 LiveContainer/Data/Application/。
        // Group ID 随 Team ID 变、不能硬编码，故枚举 Library/Group Containers/ 下的目录找 LiveContainer。
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let groupContainers = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Group Containers")
        if let subdirs = try? FileManager.default.contentsOfDirectory(
            at: groupContainers, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for dir in subdirs where dir.lastPathComponent.contains("LiveContainer") {
                let dataRoot = dir
                    .appendingPathComponent("LiveContainer")
                    .appendingPathComponent("Data")
                    .appendingPathComponent("Application")
                if FileManager.default.fileExists(atPath: dataRoot.path) {
                    log.log("[T8] (b) 容器根目录：\(dataRoot.path)（由 App Group 枚举推断）")
                    return (dataRoot, "")
                }
            }
            log.log("[T8] (b) Group Containers 下未找到可用的 LiveContainer/Data/Application/")
        } else {
            log.log("[T8] (b) 读不到 Library/Group Containers/ 目录")
        }

        return (nil, "LC_HOME_PATH 无对应目录，且 App Group 下未找到 LiveContainer/Data/Application/")
    }

    // MARK: - (b) 只读枚举容器

    /// 只读列出目标 App 容器下可能含播放状态的文件名；不读内容里的账号、token 等敏感字段。
    /// 读不到目录或无权限 → 记“无”，这是有效结果，不是失败。
    private static func inspectGuestContainers(root: URL, log: LogStore) -> String {
        let fm = FileManager.default
        guard let containerDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            let line = "(b) 容器根目录存在但列不出子目录：\(root.path)"
            log.log("[T8] \(line)")
            return line
        }

        var foundApps: [String] = []
        var foundFiles: [String] = []
        for dir in containerDirs {
            // 容器目录名是 UUID，靠 LCContainerInfo.plist 里的 bundle ID 认 App；
            // 目录名本身含特征串时也认。只读 bundle ID 一个字段。
            var bundleID = ""
            let infoPlist = dir.appendingPathComponent("LCContainerInfo.plist")
            if let dict = NSDictionary(contentsOf: infoPlist),
               let bid = dict["CFBundleIdentifier"] as? String {
                bundleID = bid
            }
            let lowerName = dir.lastPathComponent.lowercased()
            let lowerBid = bundleID.lowercased()
            let isTarget = targetBundleHints.contains { lowerName.contains($0) || lowerBid.contains($0) }
            guard isTarget else { continue }

            let label = bundleID.isEmpty ? dir.lastPathComponent : bundleID
            foundApps.append(label)
            log.log("[T8] (b) 找到目标 App 容器：\(label)（目录 \(dir.lastPathComponent)）")

            // 只读列出 Documents/ 与 Library/Preferences/ 下的文件名。
            for sub in ["Documents", "Library/Preferences"] {
                let subURL = dir.appendingPathComponent(sub)
                guard let files = try? fm.contentsOfDirectory(
                    at: subURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    log.log("[T8] (b) \(label)/\(sub)：读不到目录或无权限，记“无”")
                    continue
                }
                let names = files.map { $0.lastPathComponent }
                log.log("[T8] (b) \(label)/\(sub)：文件名：\(names.joined(separator: ", "))")
                for name in names where playbackFileHints.contains(where: { name.lowercased().contains($0) }) {
                    foundFiles.append("\(label)/\(sub)/\(name)")
                }
            }
        }

        if foundApps.isEmpty {
            let line = "(b) 容器根目录可枚举，但未找到 QQ 音乐 / 网易云音乐的容器（按 bundle ID 特征匹配无命中），记“无”"
            log.log("[T8] \(line)")
            return line
        }
        if foundFiles.isEmpty {
            let line = "(b) 找到容器：\(foundApps.joined(separator: "、"))；其 Documents/ 与 Library/Preferences/ 下未见含播放状态特征的文件名，记“无”（只记文件名，未读内容）"
            log.log("[T8] \(line)")
            return line
        }
        let line = "(b) 找到容器：\(foundApps.joined(separator: "、"))；可能含播放状态的文件名：\(foundFiles.joined(separator: "、"))（只记文件名，未读内容）"
        log.log("[T8] \(line)")
        return line
    }
}
