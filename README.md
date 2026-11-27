# LCProbe

LCProbe 是一个独立的诊断探针工程，不是歌词 App，也不是功能 App。

它只回答一句话：**在普通签名环境下，LiveContainer 里的 Guest 到底能拿到什么、传得了什么。**

探针只测不治：每一项只产出确定的 yes/no 结论 + 带时间戳的日志证据。某项“通过”的意思是“测准了”，不是“功能通了”；某项“不通过”同样是有效结论——它直接决定对应路线做还是不做。

## 安装方式

- 用普通开发者签名编译出 IPA（见 `.github/workflows/build.yml`，不签名导出）。
- 以 LiveContainer Guest 方式安装到主测机（iPhone 13 Pro / iOS 27.0.1 / LiveContainer 3.8.12）。
- 不改 LiveContainer，不改任何正式工程，不带任何私有 entitlement。

## 九项测试一览

| # | 探针 | 测什么 | 通过标准 |
|---|---|---|---|
| T1 | EntitlementProbe | Guest 进程实际拥有的 entitlements 清单（逐项读，打印 true/false/nil） | 产出确定的清单；预期两个读取权限为 nil/false，与之一致即算通过 |
| T2 | SystemPlayerProbe（Apple Music） | 公开接口 `systemMusicPlayer` 在 Guest 内能否读到 Apple Music 的歌名、歌手、进度 | 三次采样中至少一次读到非 nil 的歌名，且进度随播放推进而变 |
| T3 | SystemPlayerProbe（QQ 音乐） | 同一公开接口对 QQ 音乐是否恒为 nil | QQ 音乐播放时为 nil，且切回 Apple Music 后恢复非 nil（边界测准即通过） |
| T4 | FileShareProbe | Guest 与宿主的文件路径是否打通（打印双方实际路径，约定位置读写带时间戳的 JSON） | Guest 能读到对方写的文件且内容一致 |
| T5 | DarwinNotifyProbe | Darwin 通知宿主→Guest 是否送达（连发 5 次，记录收到时间） | 5 次中至少 4 次在 1 秒内收到 |
| T6 | ShazamProbe | ShazamKit 在 Guest 内能否识别扬声器播放的歌曲（麦克风采样，记录耗时与是否打断播放；另测戴耳机场景） | 扬声器场景 3 次中有 2 次识别出正确歌名 |
| T7 | LoopbackProbe | 多任务模式下双 Guest 间 `127.0.0.1` 是否通（一个 Guest 起 HTTP 服务，另一个请求快照 JSON；标准单 Guest 模式复测一次） | 多任务模式下一次请求成功 |
| T8 | GuestMusicProbe | LC 内的 QQ 音乐 / 网易云音乐是否有任何获准的播放信息接口（区分系统音乐 App 与 LC 内音乐 App） | 产出确定的有 / 无结论 + 日志证据 |
| T9 | PiPProbe | 系统画中画（`AVPictureInPictureController`）在 LC 内是否可用——歌词渲染为视频帧走系统 PiP | 产出确定的可用 / 不可用结论 + 日志证据 |

跑法（按可行性报告 §7.3）：Apple Music 播一首歌 → 跑 T2；QQ 音乐播一首歌 → 跑 T3；两个 Guest 同进多任务窗口 → 跑 T4/T5/T7；扬声器放 QQ 音乐 → 跑 T6；T8/T9 单独跑。每步只做一件事，日志带时间戳。

## 日志导出方法

1. 在诊断页上跑完要测的项。
2. 点诊断页上的导出 / 分享按钮（或在文件 App 里找到 LCProbe 的 Documents 目录）。
3. 把 `LCProbe.log` 发回。日志每行带 `HH:mm:ss.SSS` 时间戳，包含每项测试的结论与原始采样。

版本号显示在诊断页上，从 Bundle 动态读取，不写死。

## 工程结构

```
LCProbe/
├── LCProbeApp.swift        # 入口；只显示诊断页
├── DiagnosticsView.swift   # 诊断页：九项各一行结果 + 原始日志滚动区
├── Probes/                 # T1–T9 八个探针文件
├── LogStore.swift          # 日志：内存行 + 落盘 Documents/LCProbe.log
├── ProbeTypes.swift        # ProbeOutcome / ProbeState / AppVersion
└── Info.plist              # 只含公开权限说明，不含任何私有 entitlement 键
```

## 红线

- 仓库里不许有 `*.entitlements` 文件（CI 自检会失败）。
- Swift 源码里不许写死版本号（CI 自检会失败）。
- 探针不承诺任何一项“通过”，只承诺“测准”。
