import Foundation

/// 诊断日志：内存行 + 落盘到 Documents/LCProbe.log（追加写）。
/// 所有探针共用同一实例。
final class LogStore: ObservableObject {

    static let shared = LogStore()

    @Published private(set) var lines: [String] = []

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.guhailong.lcprobe.log", qos: .utility)
    private let timestampFormatter: DateFormatter

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = documents.appendingPathComponent("LCProbe.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.timestampFormatter = formatter
    }

    /// 返回日志文件 URL（供导出 / 分享用）。
    func exportURL() -> URL {
        fileURL
    }

    /// 写一行日志：加时间戳前缀，同时写内存行与磁盘文件。
    func log(_ message: String) {
        let stamped = "\(timestampFormatter.string(from: Date())) \(message)"
        DispatchQueue.main.async { [weak self] in
            self?.lines.append(stamped)
        }
        queue.async { [weak self] in
            guard let self else { return }
            let data = (stamped + "\n").data(using: .utf8) ?? Data()
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }
}
