import Foundation
import MediaPlayer

/// T2/T3：用公开接口 MPMusicPlayerController.systemMusicPlayer 三次采样。
///
/// - T2 (.appleMusic)：Apple Music 播放时读 nowPlayingItem / currentPlaybackTime / playbackState
/// - T3 (.qqMusic)：QQ 音乐播放时同法采样，确认 nowPlayingItem 是否恒为 nil（边界确认）
/// 绝不调用任何私有 MediaRemote 接口。
/// 判定：
/// - Apple Music：三次中至少一次 title 非 nil 且 currentPlaybackTime 在推进 → passed，否则 failed
/// - QQ 音乐：三次 title 全为 nil → passed；任一次非 nil → notTestable，
///   只逐条报告采样结果，不下“边界被推翻”的结论——实测证明
///   systemMusicPlayer 返回的是系统级正在播放信息（可能是 Apple Music
///   的歌名，即使已暂停/过期），无法据此认定读到的是 QQ 音乐；
///   要归因到 QQ 音乐必须单独测试：只放 QQ 音乐、Apple Music 停掉、
///   且放一首与 Apple Music 不同的歌，再单独跑 T3。
/// - systemMusicPlayer 拿不到实例 → notTestable
final class SystemPlayerProbe {

    enum PlayerProbeContext {
        case appleMusic
        case qqMusic
    }

    static func run(context: PlayerProbeContext, log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        let id: String
        let prompt: String
        switch context {
        case .appleMusic:
            id = "T2"
            prompt = "请先在 Apple Music 里播放一首歌再点运行"
        case .qqMusic:
            id = "T3"
            prompt = "请先在 QQ 音乐里播放一首歌再点运行"
        }
        log.log("[\(id)] \(prompt)")

        // systemMusicPlayer 在当前 SDK 下返回非可选实例；
        // 用可选绑定保留“拿不到实例 → notTestable”的分支。
        let player: MPMusicPlayerController? = MPMusicPlayerController.systemMusicPlayer
        guard let player = player else {
            let summary = "systemMusicPlayer 拿不到实例，无法采样"
            log.log("[\(id)] \(summary)")
            completion(.notTestable(summary), summary)
            return
        }

        var titles: [String?] = []
        var times: [TimeInterval] = []
        var states: [MPMusicPlaybackState] = []

        func sample(index: Int) {
            let item = player.nowPlayingItem
            let title = item?.title
            let artist = item?.artist
            let album = item?.albumTitle
            let duration = item?.playbackDuration ?? 0
            let time = player.currentPlaybackTime
            let state = player.playbackState
            titles.append(title)
            times.append(time)
            states.append(state)
            log.log("[\(id)] 采样 \(index + 1)/3：title=\(title ?? "nil") artist=\(artist ?? "nil") album=\(album ?? "nil") duration=\(duration) time=\(time) state=\(state.rawValue)")

            if index < 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    sample(index: index + 1)
                }
                return
            }

            finish()
        }

        func finish() {
            switch context {
            case .appleMusic:
                let hasTitle = titles.contains { $0 != nil }
                let timeAdvanced = (times.max() ?? 0) > (times.min() ?? 0)
                if hasTitle && timeAdvanced {
                    let song = titles.compactMap { $0 }.first ?? ""
                    let summary = "读到 Apple Music：\(song)，进度在推进（\(times.map { String(format: "%.1f", $0) }.joined(separator: " → "))）"
                    log.log("[T2] \(summary)")
                    completion(.passed, summary)
                } else {
                    let summary = "Apple Music 未读到有效播放信息（title 非 nil：\(hasTitle)，进度推进：\(timeAdvanced)，state=\(states.map { "\($0.rawValue)" }.joined(separator: ","))）"
                    log.log("[T2] \(summary)")
                    completion(.failed, summary)
                }
            case .qqMusic:
                let nonNilTitles = titles.compactMap { $0 }
                if nonNilTitles.isEmpty {
                    let summary = "QQ 音乐播放时三次采样 title 全为 nil（边界测准：无公开接口可读）"
                    log.log("[T3] \(summary)")
                    completion(.passed, summary)
                } else {
                    // 不下推翻边界的结论：systemMusicPlayer 返回的是
                    // 系统级正在播放信息，读到的歌名可能是 Apple Music 的
                    // （即使已暂停/过期），无法归因到 QQ 音乐。只逐条报告
                    // 采样结果（见上方三条采样日志），归因需单独测试。
                    log.log("[T3] 注意：systemMusicPlayer 返回系统级正在播放信息，读到的歌名可能是 Apple Music 的（即使已暂停/过期），无法据此认定是 QQ 音乐；要归因到 QQ 音乐需单独测试：只放 QQ 音乐、Apple Music 停掉、且放一首与 Apple Music 不同的歌，再单独跑 T3")
                    let summary = "三次采样读到非 nil 歌名「\(nonNilTitles.joined(separator: "、"))」，state=\(states.map { "\($0.rawValue)" }.joined(separator: ","))，但无法归因到 QQ 音乐（可能是 Apple Music 的系统级信息，见日志）；归因需单独测试：只放 QQ 音乐、Apple Music 停掉、放一首与 Apple Music 不同的歌，再单独跑 T3"
                    log.log("[T3] \(summary)")
                    completion(.notTestable(summary), summary)
                }
            }
        }

        sample(index: 0)
    }
}
