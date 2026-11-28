import Foundation
import Darwin
import MachO

/// T10 TweakLoader 注入诊断：KuwoBridge dylib 从不加载，查链子断在哪。
///
/// (a) _dyld 枚举本进程已加载镜像，找 "tweakloader"（不区分大小写）；
///     再读主可执行文件的 Mach-O load command，找 LC_LOAD_DYLIB 指向
///     TweakLoader 的条目——区分“装的时候就没打补丁”和“打了补丁但加载器
///     没进进程”。Mach-O 解析全程只读文件、带边界检查，读不到只记原因，
///     绝不崩。
/// (b) 读本客体的 LCAppInfo.plist（在 bundle 内，FINDINGS L536）：
///     dontInjectTweakLoader、LCTweakFolder。三个候选路径都试，找不到
///     只记“未找到”，绝不崩。
/// (c) 列全局 Tweaks 文件夹（LC_HOME_PATH/Documents/Tweaks）里的
///     .dylib 与大小，报 KuwoBridge.dylib 在不在；LCTweakFolder 若有值，
///     也列那个专属文件夹。
/// (d) LC_HOME_PATH 有无（T4 已证实有，列出求完整）。
/// 判定（通过＝测准了）：TweakLoader 镜像已加载 → passed；没加载 →
/// failed（这就是要诊的病）；枚举本身跑不起来 → notTestable。
final class TweakLoaderProbe {

    static let id = "T10"
    static let title = "T10 TweakLoader 注入诊断"

    static func run(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        log.log("[T10] 开始 TweakLoader 注入诊断")

        // (d) LC_HOME_PATH
        let lcHome = ProcessInfo.processInfo.environment["LC_HOME_PATH"]
        if let lcHome, !lcHome.isEmpty {
            log.log("[T10] LC_HOME_PATH = \(lcHome)")
        } else {
            log.log("[T10] LC_HOME_PATH = 无")
        }
        // TweakLoader 读完就 unset LC_GLOBAL_TWEAKS_FOLDER，跑到这里时
        // 大概率已无；有就记下来，没有也不算异常。
        if let globalFolder = ProcessInfo.processInfo.environment["LC_GLOBAL_TWEAKS_FOLDER"],
           !globalFolder.isEmpty {
            log.log("[T10] LC_GLOBAL_TWEAKS_FOLDER = \(globalFolder)")
        } else {
            log.log("[T10] LC_GLOBAL_TWEAKS_FOLDER = 无（TweakLoader 读完会 unset，没有不算异常）")
        }

        // (a1) 已加载镜像枚举
        var loadedImages: [String] = []
        let imageCount = _dyld_image_count()
        for i in 0..<imageCount {
            guard let cName = _dyld_get_image_name(i) else { continue }
            loadedImages.append(String(cString: cName))
        }
        log.log("[T10] 本进程已加载镜像共 \(loadedImages.count) 个")
        let loaderImage = loadedImages.first { $0.lowercased().contains("tweakloader") }
        if let loaderImage {
            log.log("[T10] TweakLoader 已加载：\(loaderImage)")
        } else {
            log.log("[T10] TweakLoader 未加载：\(loadedImages.count) 个镜像里没有含 tweakloader 的")
        }

        // (a2) 主可执行文件 Mach-O 里的 LC_LOAD_DYLIB
        let execPath = _dyld_get_image_name(0).map { String(cString: $0) } ?? ""
        log.log("[T10] 主可执行文件 = \(execPath.isEmpty ? "（读不到）" : execPath)")
        let loadCheck = checkLoadDylibs(execPath: execPath)
        if let error = loadCheck.error {
            log.log("[T10] 主可执行文件 LC_LOAD_DYLIB 检查失败：\(error)")
        } else {
            if loadCheck.names.isEmpty {
                log.log("[T10] 主可执行文件里没有任何 LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB 条目")
            } else {
                for name in loadCheck.names {
                    log.log("[T10] 主可执行文件 LC_LOAD_DYLIB：\(name)")
                }
            }
            log.log("[T10] 主可执行文件里 LC_LOAD_DYLIB 指向 TweakLoader：\(loadCheck.foundTweakLoader ? "有" : "无")")
        }

        // (b) LCAppInfo.plist
        let appInfo = readLCAppInfo(execPath: execPath, lcHome: lcHome)
        if appInfo.found {
            log.log("[T10] LCAppInfo.plist = \(appInfo.path)")
            log.log("[T10] dontInjectTweakLoader = \(appInfo.dontInject)")
            log.log("[T10] LCTweakFolder = \(appInfo.tweakFolder ?? "absent（无此键）")")
        } else {
            log.log("[T10] LCAppInfo.plist 未找到（试了 bundle 内与 LC_HOME_PATH 下共 \(appInfo.triedCount) 个候选路径）")
        }

        // (c) 全局 Tweaks 文件夹
        let globalTweaksDir: URL
        if let lcHome, !lcHome.isEmpty {
            globalTweaksDir = URL(fileURLWithPath: lcHome)
                .appendingPathComponent("Documents")
                .appendingPathComponent("Tweaks")
        } else {
            globalTweaksDir = CrossGuest.sharedDocumentsURL().appendingPathComponent("Tweaks")
        }
        log.log("[T10] 全局 Tweaks 文件夹 = \(globalTweaksDir.path)")
        let globalDylibs = listDylibs(in: globalTweaksDir, log: log, label: "全局 Tweaks")
        let kuwoPresent = globalDylibs.contains("KuwoBridge.dylib")
        log.log("[T10] 全局 Tweaks 里 KuwoBridge.dylib：\(kuwoPresent ? "有" : "无")")

        // (c) 专属文件夹（LCTweakFolder 有值时）
        var perAppDylibs: [String] = []
        var perAppLabel = ""
        if let folder = appInfo.tweakFolder, !folder.isEmpty, folder != "空字符串" {
            perAppLabel = "专属文件夹 \(folder)"
            let perAppDir = globalTweaksDir.appendingPathComponent(folder)
            log.log("[T10] 专属文件夹 = \(perAppDir.path)")
            perAppDylibs = listDylibs(in: perAppDir, log: log, label: perAppLabel)
            log.log("[T10] 专属文件夹里 KuwoBridge.dylib：\(perAppDylibs.contains("KuwoBridge.dylib") ? "有" : "无")")
        } else {
            log.log("[T10] LCTweakFolder 无值，不列专属文件夹")
        }

        // 结论
        let patchText: String
        if let error = loadCheck.error {
            patchText = "查不到（\(error)）"
        } else if loadCheck.foundTweakLoader {
            patchText = "有"
        } else {
            patchText = "无"
        }
        let folderText = appInfo.tweakFolder ?? "absent"
        if let loaderImage {
            let summary = "TweakLoader 已加载：\(loaderImage)；LC_LOAD_DYLIB 补丁：\(patchText)；dontInjectTweakLoader=\(appInfo.dontInject)；LCTweakFolder=\(folderText)；全局 Tweaks 里 KuwoBridge.dylib：\(kuwoPresent ? "有" : "无")"
            log.log("[T10] \(summary)")
            completion(.passed, summary)
        } else {
            let summary = "TweakLoader 未加载——注入没发生；LC_LOAD_DYLIB 补丁：\(patchText)；dontInjectTweakLoader=\(appInfo.dontInject)；LCTweakFolder=\(folderText)；全局 Tweaks 里 KuwoBridge.dylib：\(kuwoPresent ? "有" : "无")"
            log.log("[T10] \(summary)")
            completion(.failed, summary)
        }
    }

    // MARK: - (c) 列文件夹里的 .dylib

    /// 列出 dir 下的 .dylib（文件名 + 大小），返回文件名列表。
    /// 目录不存在 / 列不出时只记日志，返回空列表。
    private static func listDylibs(in dir: URL, log: LogStore, label: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            log.log("[T10] \(label)列不出：\(dir.path)（目录不存在或无权读取）")
            return []
        }
        let dylibs = files
            .filter { $0.pathExtension.lowercased() == "dylib" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if dylibs.isEmpty {
            log.log("[T10] \(label)里没有 .dylib（共 \(files.count) 个项目）")
        } else {
            for file in dylibs {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                log.log("[T10] \(label)/\(file.lastPathComponent)：\(size >= 0 ? "\(size) byte" : "大小读不到")")
            }
        }
        return dylibs.map { $0.lastPathComponent }
    }

    // MARK: - (b) LCAppInfo.plist

    /// 读本客体的 LCAppInfo.plist。返回是否找到、实际路径、两个键的文本。
    private struct AppInfo {
        let found: Bool
        let path: String
        let triedCount: Int
        let dontInject: String
        let tweakFolder: String?
    }

    private static func readLCAppInfo(execPath: String, lcHome: String?) -> AppInfo {
        var candidates: [String] = []
        if !execPath.isEmpty {
            let dir = (execPath as NSString).deletingLastPathComponent
            candidates.append((dir as NSString).appendingPathComponent("LCAppInfo.plist"))
        }
        candidates.append((Bundle.main.bundlePath as NSString).appendingPathComponent("LCAppInfo.plist"))
        if let lcHome, !lcHome.isEmpty, !execPath.isEmpty {
            let execName = (execPath as NSString).lastPathComponent
            let url = URL(fileURLWithPath: lcHome)
                .appendingPathComponent("Documents")
                .appendingPathComponent("Applications")
                .appendingPathComponent(execName + ".app")
                .appendingPathComponent("LCAppInfo.plist")
            candidates.append(url.path)
        }
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let dict = NSDictionary(contentsOf: URL(fileURLWithPath: path)) as? [String: Any] else {
                return AppInfo(found: true, path: path, triedCount: candidates.count,
                              dontInject: "plist 存在但不是字典", tweakFolder: nil)
            }
            let dont: String
            if let value = dict["dontInjectTweakLoader"] as? NSNumber {
                dont = value.boolValue ? "true" : "false"
            } else if dict["dontInjectTweakLoader"] == nil {
                dont = "absent（无此键）"
            } else {
                dont = "非布尔值：\(dict["dontInjectTweakLoader"]!)"
            }
            let folder: String?
            if let value = dict["LCTweakFolder"] as? String {
                folder = value.isEmpty ? "空字符串" : value
            } else if dict["LCTweakFolder"] == nil {
                folder = nil
            } else {
                folder = "非字符串：\(dict["LCTweakFolder"]!)"
            }
            return AppInfo(found: true, path: path, triedCount: candidates.count,
                          dontInject: dont, tweakFolder: folder)
        }
        return AppInfo(found: false, path: "", triedCount: candidates.count,
                      dontInject: "未找到 LCAppInfo.plist", tweakFolder: nil)
    }

    // MARK: - (a2) 主可执行文件 Mach-O 里的 LC_LOAD_DYLIB

    /// 只读解析：读主可执行文件，找指向 TweakLoader 的 LC_LOAD_DYLIB。
    /// 任何一步读不到都返回 error，不抛、不崩。
    private struct LoadCheck {
        let foundTweakLoader: Bool
        let names: [String]
        let error: String?
    }

    private static func checkLoadDylibs(execPath: String) -> LoadCheck {
        guard !execPath.isEmpty else {
            return LoadCheck(foundTweakLoader: false, names: [], error: "主可执行文件路径为空")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: execPath)) else {
            return LoadCheck(foundTweakLoader: false, names: [], error: "读不到主可执行文件：\(execPath)")
        }
        let reader = MachOReader(data: data)
        guard let magic = reader.u32le(0) else {
            return LoadCheck(foundTweakLoader: false, names: [], error: "文件太小，读不到 magic")
        }
        var base = 0
        var ncmds: UInt32?
        if magic == 0xfeedfacf {
            // 64 位 thin Mach-O：ncmds 在偏移 16，load command 从偏移 32 起。
            ncmds = reader.u32le(16)
        } else if magic == 0xbebafeca {
            // fat 二进制（磁盘上 magic 字节为 CA FE BA BE）：头字段大端序，
            // 选 arm64 slice（cputype 0x0100000C）。
            guard let nfat = reader.u32be(4) else {
                return LoadCheck(foundTweakLoader: false, names: [], error: "fat 头读不到 nfat_arch")
            }
            var sliceOffset: Int?
            var off = 8
            for _ in 0..<nfat {
                guard let cputype = reader.u32be(off),
                      let sliceOff = reader.u32be(off + 8),
                      reader.u32be(off + 12) != nil else { break }
                if cputype == 0x0100000C {
                    sliceOffset = Int(sliceOff)
                    break
                }
                off += 20
            }
            guard let sliceOffset else {
                return LoadCheck(foundTweakLoader: false, names: [], error: "fat 二进制里没有 arm64 slice")
            }
            base = sliceOffset
            guard let sliceMagic = reader.u32le(base), sliceMagic == 0xfeedfacf else {
                return LoadCheck(foundTweakLoader: false, names: [], error: "arm64 slice 不是 64 位 Mach-O")
            }
            ncmds = reader.u32le(base + 16)
        } else {
            return LoadCheck(foundTweakLoader: false, names: [],
                             error: String(format: "未知 magic：0x%08x", magic))
        }
        guard let ncmds else {
            return LoadCheck(foundTweakLoader: false, names: [], error: "读不到 ncmds")
        }
        var names: [String] = []
        var cmdOff = base + 32
        for _ in 0..<ncmds {
            guard let cmd = reader.u32le(cmdOff),
                  let cmdsize = reader.u32le(cmdOff + 4), cmdsize >= 8 else { break }
            // LC_LOAD_DYLIB 0xC、LC_LOAD_WEAK_DYLIB 0x80000018、
            // LC_REEXPORT_DYLIB 0x8000001F；dylib_command 的 name 偏移在命令 +8。
            if cmd == 0xC || cmd == 0x80000018 || cmd == 0x8000001F {
                if let nameOff = reader.u32le(cmdOff + 8),
                   let name = reader.cString(at: cmdOff + Int(nameOff)) {
                    names.append(name)
                }
            }
            cmdOff += Int(cmdsize)
            guard cmdOff < data.count else { break }
        }
        let found = names.contains { $0.lowercased().contains("tweakloader") }
        return LoadCheck(foundTweakLoader: found, names: names, error: nil)
    }

    /// 带边界检查的 Mach-O 字节读取器（只读，不抛）。
    private struct MachOReader {
        let data: Data

        func u32le(_ off: Int) -> UInt32? {
            guard off >= 0, off + 4 <= data.count else { return nil }
            var value: UInt32 = 0
            for i in 0..<4 {
                value |= UInt32(data[off + i]) << (8 * i)
            }
            return value
        }

        func u32be(_ off: Int) -> UInt32? {
            guard off >= 0, off + 4 <= data.count else { return nil }
            var value: UInt32 = 0
            for i in 0..<4 {
                value = (value << 8) | UInt32(data[off + i])
            }
            return value
        }

        func cString(at off: Int, maxLen: Int = 512) -> String? {
            guard off >= 0, off < data.count else { return nil }
            var end = off
            while end < data.count && end - off < maxLen && data[end] != 0 {
                end += 1
            }
            guard end > off else { return nil }
            return String(bytes: data[off..<end], encoding: .utf8)
        }
    }
}
