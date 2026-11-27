import Foundation
import Network

/// T7 Loopback：多任务模式下双 Guest 间 127.0.0.1 是否通（FINDINGS §7 T7、§4.4）。
///
/// 两档能力：
/// (a) startServer：用 Network 框架 NWListener（tcp，127.0.0.1，端口 0 随机）
///     起一个 HTTP 服务，收到 GET /snapshot 返回
///     {"probe":"LCProbe","time":<时间戳>} 的 JSON，并在界面上显示实际端口；
/// (b) fetchSnapshot(port:)：NWConnection 连 127.0.0.1:port 请求一次，
///     5 秒超时，记录是否拿到 JSON。
///
/// run 的做法：先尝试本机自环（起服务再自己连自己一次，验证 loopback
/// 本机通），再 log 提示“多任务模式请在另一实例输入本机端口点请求”，
/// completion 按自环结果判定：
/// - 自环成功 → passed（summary 写明端口与“多任务双实例待手动验证”）；
/// - 自环失败 → failed。
///
/// 注意：单 Guest 标准模式下宿主是否存活未证实，run 里不作假定，只记录。
/// 服务在 run 结束后保持运行，供另一实例手动请求；端口见 currentPort。
final class LoopbackProbe {

    static let id = "T7"
    static let title = "T7 Loopback 双 Guest"

    /// 当前运行中的服务端口（nil 表示服务未起）。诊断页可直接显示。
    static var currentPort: Int?

    private static var listener: NWListener?
    private static var listenerQueue: DispatchQueue?

    private static let fetchTimeout: TimeInterval = 5.0

    static func run(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        log.log("[T7] 开始 loopback 探针：先起服务再自己连自己（本机自环）")

        startServer(log: log) { port in
            guard let port else {
                let summary = "本机服务起不来（NWListener 未就绪），自环失败；单 Guest 标准模式下宿主是否存活未证实，不作假定"
                log.log("[T7] \(summary)")
                completion(.failed, summary)
                return
            }
            log.log("[T7] 服务已起，端口 \(port)；现在自己连自己一次")
            fetchSnapshot(port: port, log: log) { ok, detail in
                if ok {
                    let summary = "本机自环成功（端口 \(port)，拿到快照 JSON：\(detail)）；多任务双实例待手动验证——多任务模式请在另一实例输入本机端口点请求"
                    log.log("[T7] \(summary)")
                    log.log("[T7] 多任务模式请在另一实例输入本机端口点请求（本机端口 \(port)，服务保持运行）")
                    completion(.passed, summary)
                } else {
                    let summary = "本机自环失败（端口 \(port)：\(detail)）；单 Guest 标准模式下宿主是否存活未证实，不作假定"
                    log.log("[T7] \(summary)")
                    completion(.failed, summary)
                }
            }
        }
    }

    /// (a) 起 HTTP 服务：NWListener（tcp，127.0.0.1，端口 0 随机）。
    /// 就绪后回调实际端口；服务保持运行，直到调用 stopServer。
    /// 收到 GET /snapshot 返回 {"probe":"LCProbe","time":<时间戳>} 的 JSON。
    static func startServer(log: LogStore, completion: @escaping (Int?) -> Void) {
        // 已有服务在跑就直接复用，不另起一个。
        if let port = currentPort, listener != nil {
            log.log("[T7] 服务已在运行，端口 \(port)")
            completion(port)
            return
        }

        let parameters = NWParameters.tcp
        let listener: NWListener
        do {
            // 端口 0 = 系统随机分配；随后从 listener.port 读实际端口。
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 0)!)
        } catch {
            log.log("[T7] NWListener 创建失败：\(error.localizedDescription)")
            completion(nil)
            return
        }

        let queue = DispatchQueue(label: "com.guhailong.lcprobe.loopback")
        Self.listener = listener
        Self.listenerQueue = queue
        var completed = false

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let port = Int(listener.port?.rawValue ?? 0)
                guard port != 0 else {
                    log.log("[T7] NWListener 就绪但读不到实际端口")
                    if !completed {
                        completed = true
                        completion(nil)
                    }
                    return
                }
                currentPort = port
                log.log("[T7] 服务就绪，实际端口 \(port)")
                if !completed {
                    completed = true
                    completion(port)
                }
            case .failed(let error):
                log.log("[T7] NWListener 失败：\(error.localizedDescription)")
                if !completed {
                    completed = true
                    completion(nil)
                }
            case .cancelled:
                log.log("[T7] NWListener 已取消")
                if !completed {
                    completed = true
                    completion(nil)
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            handleConnection(connection, log: log)
        }

        listener.start(queue: queue)
    }

    /// 停掉服务（诊断页手动调用；run 本身不停，供另一实例手动请求）。
    static func stopServer(log: LogStore) {
        listener?.cancel()
        listener = nil
        listenerQueue = nil
        currentPort = nil
        log.log("[T7] 服务已停")
    }

    /// (b) 请求一次快照：NWConnection 连 127.0.0.1:port，5 秒超时。
    /// 回调（是否拿到含 probe 字段的 JSON，详情文本）。
    static func fetchSnapshot(port: Int, log: LogStore, completion: @escaping (Bool, String) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            completion(false, "端口 \(port) 非法，建不出 NWEndpoint.Port")
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "com.guhailong.lcprobe.loopback-client")
        var finished = false
        let finishOnce: (Bool, String) -> Void = { ok, detail in
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(ok, detail)
        }

        let timeout = DispatchWorkItem {
            log.log("[T7] 请求 127.0.0.1:\(port) 5 秒超时")
            finishOnce(false, "5 秒超时未收到响应")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fetchTimeout, execute: timeout)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET /snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                connection.send(content: request.data(using: .utf8), completion: .contentProcessed { error in
                    if let error {
                        timeout.cancel()
                        log.log("[T7] 发送请求失败：\(error.localizedDescription)")
                        finishOnce(false, "发送请求失败：\(error.localizedDescription)")
                    }
                })
            case .failed(let error):
                timeout.cancel()
                log.log("[T7] 连接 127.0.0.1:\(port) 失败：\(error.localizedDescription)")
                finishOnce(false, "连接失败：\(error.localizedDescription)")
            case .cancelled:
                timeout.cancel()
                finishOnce(false, "连接被取消")
            default:
                break
            }
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            timeout.cancel()
            if let error {
                log.log("[T7] 接收响应失败：\(error.localizedDescription)")
                finishOnce(false, "接收失败：\(error.localizedDescription)")
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                finishOnce(false, "收到空响应或非 UTF-8 响应")
                return
            }
            log.log("[T7] 收到响应：\(text)")
            // 响应体在空行之后；只要体里有 probe 字段即算拿到快照 JSON。
            let body = text.components(separatedBy: "\r\n\r\n").last ?? text
            if body.contains("\"probe\"") && body.contains("LCProbe") {
                finishOnce(true, body.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                finishOnce(false, "响应不是快照 JSON：\(text)")
            }
        }

        connection.start(queue: queue)
    }

    /// 服务端收到一个连接：读请求，GET /snapshot 即回 JSON，其余回 404。
    private static func handleConnection(_ connection: NWConnection, log: LogStore) {
        let queue = DispatchQueue(label: "com.guhailong.lcprobe.loopback-conn")
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let error {
                log.log("[T7] 服务端读请求失败：\(error.localizedDescription)")
                connection.cancel()
                return
            }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            log.log("[T7] 服务端收到请求：\(request.components(separatedBy: "\r\n").first ?? "")")
            let response: String
            if request.hasPrefix("GET /snapshot") {
                let stamp = ISO8601DateFormatter().string(from: Date())
                let json = "{\"probe\":\"LCProbe\",\"time\":\"\(stamp)\"}"
                response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
            } else {
                response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
