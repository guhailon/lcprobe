import AVFoundation
import Foundation
import MediaPlayer
import ShazamKit

/// T6 ShazamKit：扬声器播放时能否识别出歌（FINDINGS §7 T6、§5.4）。
///
/// 手动触发单次识别：run 被点一次只识别一次，不自动轮询。
/// 做法：
/// - AVAudioSession 设 .playAndRecord、requestRecordPermission；
/// - AVAudioEngine + inputNode 采麦克风，用 SHSession +
///   SHSignatureGenerator 做流式匹配（ShazamKit），最长等 30 秒；
/// - 记录识别前后的 AVAudioSession.currentRoute（扬声器还是耳机）、
///   systemMusicPlayer.playbackState 是否变化（是否打断播放）、
///   识别结果（title/artist 或无结果）、耗时秒数。
/// 判定（通过＝测准了）：
/// - 识别出歌名 → passed；
/// - 30 秒无结果 → failed（summary 写明路由是扬声器还是耳机）；
/// - 麦克风权限被拒 → notTestable（写明原因）；
/// - ShazamKit 服务不可用（如抛错）→ notTestable（写明错误）。
final class ShazamProbe {

    static let id = "T6"
    static let title = "T6 ShazamKit 识别"

    private static let timeout: TimeInterval = 30.0
    private static let matchAttemptInterval: TimeInterval = 3.0

    static func run(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        log.log("[T6] 请用扬声器播放 QQ 音乐再点运行，耳机场景预期失败")
        log.log("[T6] 开始 ShazamKit 单次识别（最长等 \(Int(timeout)) 秒）")

        let state = ShazamRunState(log: log, completion: completion)
        state.start()
    }
}

/// T6 的一次识别全过程：持有 engine / session / generator / delegate，
/// 直到出结果或 30 秒超时才释放。completion 只调一次。
private final class ShazamRunState: NSObject, SHSessionDelegate {

    private let log: LogStore
    private let completion: (ProbeOutcome, String) -> Void
    private let startTime = Date()

    private let session = SHSession()
    private let generator = SHSignatureGenerator()
    private let engine = AVAudioEngine()

    private var finished = false
    private var matchInFlight = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var matchTimer: DispatchSourceTimer?

    private var routeBefore = ""
    private var playbackStateBefore = ""

    init(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        self.log = log
        self.completion = completion
    }

    func start() {
        let audioSession = AVAudioSession.sharedInstance()
        routeBefore = Self.routeDescription(audioSession)
        playbackStateBefore = Self.playbackStateDescription()
        log.log("[T6] 识别前路由：\(routeBefore)；系统音乐播放状态：\(playbackStateBefore)")

        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [])
            try audioSession.setActive(true)
        } catch {
            finish(.notTestable("AVAudioSession 设 .playAndRecord 失败：\(error.localizedDescription)"),
                   summary: "AVAudioSession 设 .playAndRecord 失败：\(error.localizedDescription)")
            return
        }

        audioSession.requestRecordPermission { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
                if !granted {
                    self.finish(.notTestable("麦克风权限被拒，无法采音识别"),
                                summary: "麦克风权限被拒，无法采音识别")
                    return
                }
                self.beginCapture()
            }
        }
    }

    private func beginCapture() {
        session.delegate = self
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        log.log("[T6] 麦克风输入格式：\(format)")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.generator.append(buffer, at: time)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            finish(.notTestable("AVAudioEngine 启动失败：\(error.localizedDescription)"),
                   summary: "AVAudioEngine 启动失败：\(error.localizedDescription)")
            return
        }
        log.log("[T6] 已开始采麦克风，等待识别…")

        // 每隔几秒用当前签名尝试一次匹配；30 秒超时未出结果即失败。
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.matchAttemptInterval, repeating: Self.matchAttemptInterval)
        timer.setEventHandler { [weak self] in
            self?.attemptMatch()
        }
        timer.resume()
        matchTimer = timer

        let workItem = DispatchWorkItem { [weak self] in
            self?.finishWithTimeout()
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: workItem)
    }

    /// 用当前累积的签名向 ShazamKit 发起一次匹配（同一时间只发一次）。
    private func attemptMatch() {
        guard !finished, !matchInFlight else { return }
        let signature: SHSignature
        do {
            signature = try generator.signature()
        } catch {
            log.log("[T6] 生成签名失败：\(error.localizedDescription)")
            return
        }
        matchInFlight = true
        session.match(signature)
    }

    // MARK: - SHSessionDelegate

    func session(_ session: SHSession, didFind match: SHMatch) {
        guard !finished else { return }
        matchInFlight = false
        let item = match.mediaItems.first
        let title = item?.title ?? "（无标题）"
        let artist = item?.artist ?? "（无歌手）"
        let elapsed = Date().timeIntervalSince(startTime)
        let routeAfter = Self.routeDescription(AVAudioSession.sharedInstance())
        let playbackAfter = Self.playbackStateDescription()
        let summary = "识别出「\(title)」— \(artist)，耗时 \(String(format: "%.1f", elapsed)) 秒；路由：识别前 \(routeBefore) / 识别后 \(routeAfter)；系统音乐播放状态：识别前 \(playbackStateBefore) / 识别后 \(playbackAfter)"
        log.log("[T6] \(summary)")
        finish(.passed, summary: summary)
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        matchInFlight = false
        if let error {
            log.log("[T6] 一次匹配无结果（带错误）：\(error.localizedDescription)")
        } else {
            log.log("[T6] 一次匹配无结果，继续等（总限 \(Int(Self.timeout)) 秒）")
        }
        // 不在这里结束：等下一次尝试或 30 秒超时再定论。
    }

    // MARK: - 结束

    private func finishWithTimeout() {
        guard !finished else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let routeAfter = Self.routeDescription(AVAudioSession.sharedInstance())
        let playbackAfter = Self.playbackStateDescription()
        let summary = "30 秒无结果（耗时 \(String(format: "%.1f", elapsed)) 秒）；路由是\(routeAfter)；系统音乐播放状态：识别前 \(playbackStateBefore) / 超时后 \(playbackAfter)"
        log.log("[T6] \(summary)")
        finish(.failed, summary: summary)
    }

    private func finish(_ outcome: ProbeOutcome, summary: String) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        matchTimer?.cancel()
        matchTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        log.log("[T6] 结束：\(summary)")
        completion(outcome, summary)
    }

    // MARK: - 路由与播放状态

    /// 当前音频路由：扬声器 / 耳机 / 其他（列出输出端口类型）。
    private static func routeDescription(_ audioSession: AVAudioSession) -> String {
        let outputs = audioSession.currentRoute.outputs.map { $0.portType.rawValue }
        if outputs.contains(AVAudioSession.Port.builtInSpeaker.rawValue) {
            return "扬声器（\(outputs.joined(separator: "、"))）"
        }
        if outputs.contains(AVAudioSession.Port.headphones.rawValue)
            || outputs.contains(AVAudioSession.Port.bluetoothA2DP.rawValue)
            || outputs.contains(AVAudioSession.Port.bluetoothHFP.rawValue) {
            return "耳机（\(outputs.joined(separator: "、"))）"
        }
        return outputs.isEmpty ? "无输出" : outputs.joined(separator: "、")
    }

    /// 系统音乐播放器的播放状态（只读公开接口，用于判断识别是否打断播放）。
    private static func playbackStateDescription() -> String {
        switch MPMusicPlayerController.systemMusicPlayer.playbackState {
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .interrupted: return "interrupted"
        case .seekingForward: return "seekingForward"
        case .seekingBackward: return "seekingBackward"
        @unknown default: return "unknown"
        }
    }
}
