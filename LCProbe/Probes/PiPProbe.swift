// PiPProbe.swift
// LCProbe v0.1 — T9
//
// 目标：独立验证 AVPictureInPictureController 在 LC 环境下的实际能力。
// 报告 §9 第 14 项说“系统 PiP 只支持视频内容”未证实——T9 就是验证它的实验，
// 不许先假定结论，只记录实测。
//
// 做法：用 AVAssetWriter 把 5 行歌词文字渲染为视频帧（640x360、纯色底、
// 每行文字一帧、每帧 1 秒、共 5 秒，无声音轨），写到 tmp 目录的 probe-lyrics.mp4；
// 用 AVPlayer + AVPlayerLayer 播放该视频，创建 AVPictureInPictureController(playerLayer:)，
// 检查 isPictureInPicturePossible，尝试 startPictureInPicture；
// 记录：isPictureInPicturePossible 的值、start 是否抛错/回调。
// “切到别的 App 时 PiP 窗口是否还在”需要用户手动切 App 观察：run 只做启动并记录
// 启动结果，completion 带 summary“已启动，待手动观察”，不为等用户而阻塞 completion；
// 跨 App 存活留给 TESTING.md 的手动步骤和日志补记。
//
// 约定：LogStore.shared / log(_:)；ProbeOutcome；completion 只调一次；
// 绝不用 C block 约定包装任何回调。
// 注意：启动成功后，player / playerLayer / controller 必须被静态持有，
// 否则 PiP 窗口会随对象释放而消失；用户手动观察完再跑别的探针。

import AVFoundation
import AVKit
import CoreGraphics
import Foundation
import UIKit

final class PiPProbe {

    static let id = "T9"
    static let title = "AVPictureInPictureController 在 LC 下的实际能力"

    /// 渲染进视频的 5 行歌词文字（探针自带示例文字，不是实测歌词）。
    private static let lyricLines = [
        "第一行歌词 · 探针示例",
        "第二行歌词 · 探针示例",
        "第三行歌词 · 探针示例",
        "第四行歌词 · 探针示例",
        "第五行歌词 · 探针示例",
    ]

    private static let videoWidth = 640
    private static let videoHeight = 360

    /// 等待 PiP 启动回调的最长秒数；超时则按未回调记录，不阻塞 completion。
    private static let startTimeoutSeconds: TimeInterval = 8

    // 静态持有：PiP 窗口的存活依赖这些对象不被释放。
    private static var activePlayer: AVPlayer?
    private static var activePlayerLayer: AVPlayerLayer?
    private static var activeController: AVPictureInPictureController?
    private static var activeDelegate: PiPDelegate?

    static func run(log: LogStore, completion: @escaping (ProbeOutcome, String) -> Void) {
        log.log("[T9] 开始：AVPictureInPictureController 在 LC 下的实际能力验证")
        log.log("[T9] 注意：本实验只记录实测，不预设“系统 PiP 只支持视频”成立或不成立")

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            let summary = "isPictureInPictureSupported() 为 false：本设备/环境不支持系统 PiP"
            log.log("[T9] 结论：failed（\(summary)）")
            completion(.failed, summary)
            return
        }
        log.log("[T9] isPictureInPictureSupported() = true")

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-lyrics.mp4")
        // 旧文件先删，避免 AVAssetWriter 因文件已存在而失败。
        try? FileManager.default.removeItem(at: outputURL)

        writeLyricsVideo(to: outputURL, log: log) { writeError in
            if let writeError = writeError {
                let summary = "AVAssetWriter 写视频失败：\(writeError.localizedDescription)"
                log.log("[T9] 结论：notTestable（\(summary)）")
                completion(.notTestable(summary), summary)
                return
            }
            log.log("[T9] 视频已写出：\(outputURL.path)（640x360、5 行歌词各 1 秒、共 5 秒、无声音轨）")
            startPiP(videoURL: outputURL, log: log, completion: completion)
        }
    }

    // MARK: - 视频生成

    /// 用 AVAssetWriter 把 5 行歌词文字渲染为视频帧；每行一帧，每帧 1 秒。
    /// 失败时经回调返回 Error；成功返回 nil。回调只调一次。
    private static func writeLyricsVideo(
        to outputURL: URL,
        log: LogStore,
        completion: @escaping (Error?) -> Void
    ) {
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            completion(NSError(domain: "LCProbe.T9", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 初始化失败"]))
            return
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
            ])
        guard writer.canAdd(input) else {
            completion(NSError(domain: "LCProbe.T9", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 拒绝添加视频输入"]))
            return
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            completion(NSError(domain: "LCProbe.T9", code: 3,
                               userInfo: [NSLocalizedDescriptionKey: "拿不到 pixelBufferPool"]))
            return
        }

        let frameDuration = CMTime(value: 1, timescale: 1)
        // 5 帧很小，在串行队列上同步追加；等 input 就绪再写，避免丢帧。
        // 不用 requestMediaDataWhenReady：它的回调可能多次触发，会重复追加同一帧。
        let writerQueue = DispatchQueue(label: "LCProbe.T9.writer")
        writerQueue.async {
            for frameIndex in 0..<lyricLines.count {
                var waited = 0
                while !input.isReadyForMoreMediaData && waited < 100 {
                    Thread.sleep(forTimeInterval: 0.05)
                    waited += 1
                }
                guard input.isReadyForMoreMediaData else {
                    DispatchQueue.main.async {
                        completion(NSError(domain: "LCProbe.T9", code: 5,
                                           userInfo: [NSLocalizedDescriptionKey: "视频输入在 5 秒内一直未就绪（第 \(frameIndex + 1) 帧）"]))
                    }
                    return
                }
                let line = lyricLines[frameIndex]
                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                    DispatchQueue.main.async {
                        completion(NSError(domain: "LCProbe.T9", code: 6,
                                           userInfo: [NSLocalizedDescriptionKey: "创建 pixel buffer 失败（第 \(frameIndex + 1) 帧）"]))
                    }
                    return
                }
                renderLyricLine(line, into: buffer)
                adaptor.append(buffer, withPresentationTime: presentationTime)
            }
            input.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async {
                    if writer.status == .completed {
                        completion(nil)
                    } else {
                        completion(writer.error ?? NSError(domain: "LCProbe.T9", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "finishWriting 未完成，status=\(writer.status.rawValue)"]))
                    }
                }
            }
        }
    }

    /// 把一行歌词文字画进 pixel buffer：纯色底 + 居中白字。
    private static func renderLyricLine(_ line: String, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }
        // 纯色底（深色）。
        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 居中白字。UIGraphics 坐标与 CGContext 方向不同，用 NSString.draw 翻转处理。
        UIGraphicsPushContext(context)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 36),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
        let textSize = (line as NSString).size(withAttributes: attributes)
        let textRect = CGRect(
            x: (CGFloat(width) - textSize.width) / 2,
            y: (CGFloat(height) - textSize.height) / 2,
            width: textSize.width, height: textSize.height)
        (line as NSString).draw(in: textRect, withAttributes: attributes)
        UIGraphicsPopContext()
    }

    // MARK: - PiP 启动

    private static func startPiP(
        videoURL: URL,
        log: LogStore,
        completion: @escaping (ProbeOutcome, String) -> Void
    ) {
        let player = AVPlayer(url: videoURL)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight)

        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            let summary = "AVPictureInPictureController(playerLayer:) 返回 nil：无法创建 PiP 控制器"
            log.log("[T9] 结论：failed（\(summary)）")
            completion(.failed, summary)
            return
        }
        // 静态持有，PiP 窗口存活依赖它们。
        activePlayer = player
        activePlayerLayer = playerLayer
        activeController = controller

        let possible = controller.isPictureInPicturePossible
        log.log("[T9] isPictureInPicturePossible = \(possible)")
        if !possible {
            let summary = "isPictureInPicturePossible 为 false：当前环境下 PiP 不可启动"
            log.log("[T9] 结论：failed（\(summary)）")
            completion(.failed, summary)
            return
        }

        // 设 delegate 收启动回调；startPictureInPicture 本身不抛错，成败看回调。
        var completed = false
        func finishOnce(_ outcome: ProbeOutcome, _ summary: String) {
            guard !completed else { return }
            completed = true
            log.log("[T9] 结论：\(summary)")
            completion(outcome, summary)
        }
        let delegate = PiPDelegate(log: log, onStart: {
            let summary = "isPictureInPicturePossible=true，startPictureInPicture 回调成功：PiP 已启动，可启动；跨 App 存活待手动观察（见 TESTING.md T9）"
            finishOnce(.passed, summary)
        }, onFail: { error in
            let summary = "isPictureInPicturePossible=true，但 startPictureInPicture 回调失败：\(error?.localizedDescription ?? "未知错误")"
            finishOnce(.failed, summary)
        })
        activeDelegate = delegate
        controller.delegate = delegate

        player.play()
        controller.startPictureInPicture()
        log.log("[T9] 已调用 startPictureInPicture，等待 delegate 回调（最多 \(Int(startTimeoutSeconds)) 秒）")

        DispatchQueue.main.asyncAfter(deadline: .now() + startTimeoutSeconds) {
            finishOnce(.failed, "isPictureInPicturePossible=true，但 startPictureInPicture 在 \(Int(startTimeoutSeconds)) 秒内无任何 delegate 回调")
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

/// 只做回调转发，不包装任何 block。由 PiPProbe 静态持有，随 PiP 窗口同生死。
private final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {

    private let log: LogStore
    private let onStart: () -> Void
    private let onFail: (Error?) -> Void

    init(log: LogStore, onStart: @escaping () -> Void, onFail: @escaping (Error?) -> Void) {
        self.log = log
        self.onStart = onStart
        self.onFail = onFail
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        log.log("[T9] delegate：pictureInPictureControllerDidStartPictureInPicture（PiP 已启动）")
        onStart()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        log.log("[T9] delegate：failedToStartPictureInPictureWithError：\(error.localizedDescription)")
        onFail(error)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        log.log("[T9] delegate：pictureInPictureControllerDidStopPictureInPicture（PiP 已停止，记录时间点）")
    }
}
