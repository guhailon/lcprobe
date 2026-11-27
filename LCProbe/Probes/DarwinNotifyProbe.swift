import Foundation

/// T5 Darwin 通知：宿主→Guest 的 Darwin 通知是否送达（FINDINGS §7 T5、§4.6a）。
///
/// 做法：
/// - 用 CFNotificationCenterGetDarwinNotifyCenter 注册监听
///   "com.guhailong.lcprobe.ping"，回调里记录收到时间并 log；
/// - 然后连发 5 次（每次间隔 0.5 秒，CFNotificationCenterPostNotification），
///   最后一次发出后再等 3 秒汇总。
/// 判定（通过＝测准了）：
/// - 5 次中至少 4 次在 1 秒内收到 → passed；
/// - 0 次收到 → failed（summary 注明“发不出还是收不到无法区分”）；
/// - 收到 1–3 次 → failed（写明次数）。
///
/// 局限（写进 summary 与日志，不假装能区分）：
/// 同进程内自发自收，无法区分“发不出”还是“收不到”；
/// Darwin 通知只能传名字、无 payload；接收方必须在运行，
/// 通知不排队、不补发；通知名避开 com.apple.private.restrict-post. 前缀。
final class DarwinNotifyProbe {

    static let id = "T5"
    static let title = "T5 Darwin 通知"

    private static let notificationName = "com.guhailong.lcprobe.ping"
    private static let postCount = 5
    private static let postInterval: TimeInterval = 0.5
    private static let settleDelay: TimeInterval = 3.0
    private static let onTimeWindow: TimeInterval = 1.0

    static func run(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        log.log("[T5] 开始 Darwin 通知探针（监听 \(notificationName)，连发 \(postCount) 次）")

        let state = DarwinNotifyState(log: log)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(state).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            darwinNotifyCallback,
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
        log.log("[T5] 已注册监听 \(notificationName)")

        var finished = false
        let finishOnce: (ProbeOutcome, String) -> Void = { outcome, summary in
            guard !finished else { return }
            finished = true
            CFNotificationCenterRemoveObserver(center, observer, notificationName as CFString, nil)
            log.log("[T5] 已取消监听")
            completion(outcome, summary)
        }

        // 连发 5 次，每次间隔 0.5 秒。
        for index in 0..<postCount {
            let delay = postInterval * Double(index)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                state.recordPost()
                CFNotificationCenterPostNotification(
                    center,
                    notificationName as CFString,
                    nil,
                    nil,
                    true
                )
                log.log("[T5] 已发出第 \(index + 1)/\(postCount) 次通知")
            }
        }

        // 最后一次发出后再等 3 秒汇总。
        let totalDelay = postInterval * Double(postCount - 1) + settleDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
            let (onTime, total) = state.onTimeCount(window: onTimeWindow)
            let summary: String
            let outcome: ProbeOutcome
            if onTime >= 4 {
                summary = "Darwin 通知 \(postCount) 发 \(total) 收，其中 \(onTime) 次在 1 秒内收到"
                outcome = .passed
            } else if total == 0 {
                summary = "Darwin 通知 \(postCount) 发 0 收（发不出还是收不到无法区分——同进程收发无法区分此二者）"
                outcome = .failed
            } else {
                summary = "Darwin 通知 \(postCount) 发 \(total) 收，其中 \(onTime) 次在 1 秒内收到（收到 1–3 次，未达 4 次标准）"
                outcome = .failed
            }
            log.log("[T5] \(summary)")
            finishOnce(outcome, summary)
        }
    }
}

/// T5 的收发记录：发出的时间与收到的时间各记一份，用锁保护。
/// 由 Darwin 通知的 C 回调经 observer 指针取回（不捕获任何闭包）。
private final class DarwinNotifyState {

    private let log: LogStore
    private let lock = NSLock()
    private var postTimes: [Date] = []
    private var receiveTimes: [Date] = []

    init(log: LogStore) {
        self.log = log
    }

    func recordPost() {
        lock.lock()
        defer { lock.unlock() }
        postTimes.append(Date())
    }

    func recordReceive() {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        receiveTimes.append(now)
        log.log("[T5] 收到通知（第 \(receiveTimes.count) 次）")
    }

    /// 返回（1 秒内收到的次数，总收到次数）。
    /// 每次收到按时间顺序匹配最早一个尚未匹配、且在 1 秒内的发出时间。
    func onTimeCount(window: TimeInterval) -> (onTime: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        var onTime = 0
        var postIndex = 0
        for receive in receiveTimes {
            while postIndex < postTimes.count, receive.timeIntervalSince(postTimes[postIndex]) > window {
                postIndex += 1
            }
            if postIndex < postTimes.count, receive.timeIntervalSince(postTimes[postIndex]) >= 0 {
                onTime += 1
                postIndex += 1
            }
        }
        return (onTime, receiveTimes.count)
    }
}

/// Darwin 通知的 C 回调：顶层函数，不捕获任何状态。
/// observer 指针即 DarwinNotifyState 实例（调用方用 passUnretained 传入）。
private func darwinNotifyCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard let observer else { return }
    let state = Unmanaged<DarwinNotifyState>.fromOpaque(observer).takeUnretainedValue()
    state.recordReceive()
}
