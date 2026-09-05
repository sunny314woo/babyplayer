# BabyPlayer — SMB 双轨媒体源详细技术设计

> 状态：Phase A 实体 Apple TV 功能链路已通，正常首页与默认源持久化已接入；歌词、封面、进度/续播、喜欢/屏蔽和跳过已完成 Debug 功能验证；完整性能/故障矩阵和许可证评审待完成  
> 日期：2026-09-05  
> 适用版本：BabyPlayer 0.5 及后续版本  
> 需求优先级：用户最新明确指令，高于现有 V1 中“Jellyfin 是唯一媒体源”的限制

## 1. 决策摘要

BabyPlayer 新增“局域网 U 盘（SMB/Samba）”媒体源，让 Apple TV 直接浏览和播放插在家庭路由器上的 U 盘。日常播放链路中不再要求 Mac 或 Jellyfin 开机。

目标架构保留两条媒体轨道：

```text
BabyPlayer
├── SMB 媒体源：Apple TV → 路由器 Samba → U 盘视频
└── Jellyfin 媒体源：Apple TV → Jellyfin HTTP API（兼容现有用户）

可选字幕分析
└── Apple TV → Mac 8011（当前）→ 云端服务（未来）
```

核心决策如下：

1. SMB 是新的一级媒体源，不是 Jellyfin 的文件夹配置，也不是由 Mac 代挂载的网络磁盘。
2. 播放、媒体扫描、封面缓存和本地偏好全部在 Apple TV 端完成；Mac 关机不影响这些能力。
3. 保留 Jellyfin provider，现有用户升级后继续使用原配置，不被强制迁移。
4. 当前已实现 Samba/Jennifer 手动双轨切换；最后选定项作为下次启动的默认源。多住宅多个 Samba profile 的自动探测保留为后续阶段。
5. SMB 第一版只读，不提供上传、移动、重命名或删除 U 盘文件的能力。
6. 当前 Mac ASR/DeepSeek 作为可选分析服务保留，但其地址从 Jellyfin 地址中解耦。Mac 不在线时只禁用新分析，不阻断播放、普通在线歌词或已有字幕。

当前功能完成度和后续对话的事实优先级见 `DEVELOPMENT_STATUS_2026-09-05.md`。

## 2. 已验证的真实环境

2026-09-05 已在当前住宅的光猫共享上完成真实网络、文件和实体 Apple TV 播放验证：

| 项目 | 验证结果 |
|---|---|
| 光猫地址 | `192.168.1.1` |
| 设备型号 | `HN8546X6N-20` |
| SMB 共享名 | `usb-0781-060116_1` |
| 媒体根目录 | `/sss73` |
| SMB 端口 | TCP `445` 开放；App 只使用 `445` |
| 真实视频数 | 78 个 MP4 |
| 视频编码 | 全部 H.264 |
| 音频编码 | 全部 AAC（LC 为主，1 个 HE-AAC） |
| 最高规格 | 1920×1080，约 30 fps |
| 必须忽略的文件 | `.DS_Store`、隐藏目录、78 个 `._*.mp4` AppleDouble 文件 |
| 实体 Apple TV 探针 | 78 个视频，192 KiB 分段读取，播放推进 4.36 秒 |

上述 H.264/AAC 规格属于 Apple TV 系统播放器的直接解码范围，不需要 Jellyfin 或路由器转码。实体 Apple TV 已完成一次真实起播；完整 seek、冷/热起播和故障恢复矩阵仍需继续执行。

当前默认真实配置为：

```text
显示名称：光猫 U 盘
类型：SMB
主机：192.168.1.1
端口：445
共享名：usb-0781-060116_1
根目录：/sss73
用户名：admin
密码：仅保存到 Apple TV Keychain，不写入本文档或普通配置
```

### 2.1 2026-09-05 Apple TV 真机结果

“客厅” Apple TV 位于 `192.168.1.20`，光猫 Samba 位于 `192.168.1.1`。已签名安装的 Debug App 在 tvOS 上扫描到 78 个视频，随机读取 192 KiB，AVAsset 可播放并实际推进 4.36 秒。原 `192.168.5.1` 中兴路由器的跨网段超时作为历史记录保留，不再是当前阻断。详细证据见 `SMB_DIRECT_MEDIA_SOURCE_PHASE_A_REPORT.md`。

## 3. 产品目标与非目标

### 3.1 本期目标

- 路由器和 U 盘在线、Mac 关机时，Apple TV 可以冷启动 BabyPlayer、进入首页并播放视频。
- 首次由家长添加 SMB 媒体源，之后儿童不接触服务器、目录或账号概念。
- 支持保存多套住宅配置，并根据当前局域网自动选择在线媒体源。
- 保留现有首页、封面、播放队列、循环/顺序/随机、定时关闭、评分、续播和歌词体验。
- 网络中断、U 盘拔出、账号失效时不崩溃，并提供家长可理解的恢复入口。
- 扫描和播放仅执行 SMB 读取操作，不改变 U 盘内容。

### 3.2 本期非目标

- 不实现 SMB 文件上传、删除、移动或重命名。
- 不把 BabyPlayer 变成 VLC 式文件管理器；儿童首页仍只显示内容卡片。
- 不在第一版实现路由器端转码。
- 不在第一版加入纯 MP3/AAC 音频库；当前范围仍是儿童音乐视频。
- 不自动合并两个住宅同时在线的媒体库；一次只激活一个媒体源。
- 不要求第一版自动发现所有局域网设备。已保存的 IP/主机名探测更稳定，Bonjour/NetBIOS 发现可后续增加。
- 不在本期把 ASR/DeepSeek 迁移到云端，但必须先完成接口解耦，为迁移留出明确边界。
- 不在 SMB 第一版自动加载同目录 `.srt`、`.ass` 等外挂字幕；已有 BabyPlayer 歌词/字幕缓存继续可用，外挂字幕作为后续独立需求。

### 3.3 术语

| 术语 | 本文含义 |
|---|---|
| 媒体源 profile | 一套且仅一套 provider 配置，例如“光猫 U 盘 SMB”或“现有 Jellyfin” |
| provider | 对 Jellyfin 或 SMB 的具体访问实现 |
| 在线 | 已完成认证、共享打开且配置根目录可读；仅 TCP 445 可连接不算在线 |
| 活动源 | 当前首页、队列和播放唯一使用的 profile；任何时刻最多一个 |
| 候选文件 | 扩展名和大小通过初筛、尚未完成 AVAsset 可播放性验证的文件 |
| 可播放文件 | 已在 tvOS 上通过容器、轨道和解码能力验证的候选文件 |
| 冷态/热态 | 冷态指已关闭旧 SMB session、但可保留持久索引；热态指同一 App 进程已有会话。首次安装的无索引扫描另行测量 |

## 4. 用户体验设计

### 4.1 首次使用

无任何已保存媒体源时，欢迎页提供两个家长入口：

1. `连接局域网 U 盘`（推荐）
2. `连接 Jellyfin`

选择局域网 U 盘后进入 SMB 配置页：

```text
配置名称     [光猫 U 盘]
服务器地址   [192.168.1.1]
共享名称     [usb-0781-060116_1]
媒体目录     [/sss73]
用户名       [admin]
密码         [••••••••]

[测试连接]    [保存并扫描]
```

“服务器显示名”不是必填连接参数；当前以家长可理解的“光猫 U 盘”作为显示名称。

### 4.2 测试连接流程

“测试连接”按以下顺序执行，并把具体技术错误转换为家长可理解的状态：

1. 在 2 秒内连接主机 TCP 445。
2. 使用账号建立 SMB 会话。
3. 打开指定共享。
4. 确认根目录存在且可读。
5. 按正式扫描相同的递归、过滤与路径安全规则查找候选文件，但受 10 秒、深度 5 和 2,000 个媒体候选上限约束。
6. 对第一个候选视频读取少量首尾字节，并用 SMB-backed AVAsset 验证轨道和可播放性。

Apple 的 [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) 当前明确列出 tvOS 不支持 Local Network privacy gate，因此 BabyPlayer 不设计 iOS 式权限申请/拒绝流程；测试连接直接开始 TCP/SMB 操作。现有 `NSLocalNetworkUsageDescription` 可更新成准确文案，但不能把它当作 tvOS 连接前置条件。若未来 tvOS 政策改变，再按系统 API 增加条件分支。

成功文案示例：

```text
连接成功
找到 78 个视频候选，正在验证可播放性 · usb-0781-060116_1/sss73
```

如果预算耗尽但尚未遍历完目录，显示“连接成功，完整扫描将在保存后继续”，不能把未完成扫描误报为“没有视频”。只有遍历完整且没有候选文件时，才报告“没有支持的视频”。

失败文案需要区分：

- 找不到服务器：确认 Apple TV 已连接该住宅网络。
- 登录失败：请检查 Samba 用户名或密码。
- 找不到共享：请检查共享名称，当前为 `usb-0781-060116_1`。
- 找不到文件夹：请检查媒体目录，例如 `/sss73`。
- 没有视频候选：当前版本检查 MP4、M4V、MOV，并在保存后验证实际编码是否可播放。

### 4.3 家长设置中的媒体源

把现有“Jellyfin 连接”区域替换为“媒体源”：

```text
媒体源                  光猫 U 盘 · Samba · 已连接
切换媒体源              自动
扫描并刷新媒体库        78 个视频
管理媒体源              2 个配置
字幕分析服务            Mac · 当前离线/在线
```

“管理媒体源”页面展示：

- 当前光猫 U 盘 — SMB — `192.168.1.1/usb-0781-060116_1/sss73`
- 另一住宅 — SMB — 待取得当地真实路由器参数后配置
- 现有 Jellyfin — Jellyfin — 已配对
- 添加媒体源

每个 profile 只能是 SMB 或 Jellyfin 其中一种，不能同时装两种配置。每个配置支持：测试、编辑、设为优先、暂时停用和删除本地配置。删除配置不对服务器或 U 盘执行任何操作。

### 4.4 自动切换规则

启动时遵循以下确定性规则：

1. 固定模式只探测指定 profile；自动模式先并发探测 `preferredProfileID` 与 `lastSuccessfulProfileID`（若不同），单个超时 1.5 秒。
2. 若这组没有在线项，再并发探测其余已启用配置，单个配置超时 2 秒。
3. “在线”必须同时满足认证成功、共享可打开、根目录可读；只探通 IP/端口不算在线。
4. 只有一个在线时自动选择它。
5. 多个在线时按唯一顺序选择：`preferredProfileID` 若在线 → `lastSuccessfulProfileID` 若在线 → `lastSuccessfulConnectionAt` 最新者 → profile 创建顺序 → UUID 字典序。这样即使两个住宅通过 VPN 同时可见，结果也确定。
6. 全部离线时显示上次活动源的缓存媒体卡片和“媒体源未连接”状态，但点击时不假装可以播放。
7. 播放过程中绝不自动切换媒体源。当前播放失败后返回首页，再执行重新探测。
8. 家长手动切换采用事务式切换：旧源保持活动但卡片暂时不可点击；新源完成认证并生成完整首页快照后才一次性提交。新源失败时恢复旧源及旧首页，不留下混合队列或半个新库。

家长可把切换方式设为：

- `自动（推荐）`
- `固定使用光猫 U 盘`
- `固定使用另一住宅`
- `固定使用 Jellyfin`

固定模式下只探测指定 profile。它离线时显示离线状态和“切换媒体源”入口，绝不静默回退到其它 profile。

### 4.5 儿童首页

儿童首页不显示账号或密码。页脚显示低干扰来源标识“光猫 U 盘 · Samba · 播放不经过 Mac”，用于家长确认当前来源。

以下行为保持不变：

- 点击卡片播放。
- 顺序播放、随机播放、偏好优先。
- 默认单曲循环及播放中切换模式。
- 家长评分和屏蔽。
- 返回首页后恢复焦点。

### 4.6 离线与恢复

- App 有缓存目录时先显示封面和标题，同时在后台重连。
- 路由器重新上线后支持家长点击“重新连接”；也可每 10 秒有限重试，最多 3 次，之后停止后台轮询。显式点击重试、App 再次进入前台，或 `NWPathMonitor` 从不可用变为可用时重置这组重试预算。
- U 盘播放中被拔出时，停止当前播放并显示“存储设备已断开”，不自动跳到另一个住宅的视频。
- Samba 密码被修改后保留配置其它字段，家长只需重新输入密码。
- Apple TV 从睡眠唤醒时重建 SMB 会话，不复用失效 socket。
- 焦点恢复到失败前的媒体卡片或家长按钮；错误提示、连接状态和切换按钮必须提供 VoiceOver 标签，不能只靠颜色表达。

## 5. 目标代码架构

### 5.1 当前耦合

当前主链路为：

```text
JellyfinSpikeClient
  → JellyfinMediaItem
  → SpikeViewModel.mediaItems
  → Jellyfin HTTP URL
  → BabyPlayerQueueItem.url
  → AVPlayerItem(url:)
```

同时，`BabyPlayerServiceConfiguration` 从 Jellyfin 主机推导 Mac `:8011/v1`，`BabyPlayerQueueItem.localMediaPath` 也只适用于 Jellyfin 返回的 Mac 本机路径。这两处必须与媒体播放解耦。

### 5.2 目标分层

```text
SwiftUI 页面
    ↓
MediaSourceCoordinator
    ├── JellyfinMediaSourceProvider
    └── SMBMediaSourceProvider
            ↓
       SMBConnectionPool
       ├── playback session（高优先级）
       └── background session（扫描/封面/指纹，串行）
                 ↓
          SMBByteRangeReader

统一 BabyPlayerMediaItem
    ↓
PlaybackItemFactory
    ├── HTTP URL → AVPlayerItem
    └── SMB 文件 → AVURLAsset + ResourceLoader → AVPlayerItem
```

UI、排序、评分、歌词和播放模式只依赖统一模型，不再依赖 `JellyfinMediaItem`。

### 5.3 配置模型

配置用关联值枚举表达“二选一”，从类型层面排除 `kind == .smb` 但 SMB 配置为空等无效状态：

```swift
enum BabyPlayerMediaSourceConfiguration: Codable, Sendable {
    case jellyfin(JellyfinSourceConfiguration)
    case smb(SMBSourceConfiguration)
}

struct BabyPlayerMediaSourceProfile: Codable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var configuration: BabyPlayerMediaSourceConfiguration
    var credentialReference: UUID?
    var isEnabled: Bool
    var createdAt: Date
    var lastSuccessfulConnectionAt: Date?
}

struct SMBSourceConfiguration: Codable, Sendable {
    var host: String
    var port: Int
    var serverDisplayName: String?
    var share: String
    var rootPath: String
    var username: String
}
```

密码不进入 `SMBSourceConfiguration`，而是按 profile 的 `credentialReference` 单独写入 Keychain。`preferredProfileID` 保存在配置集合外层且最多一个，避免多个 profile 同时出现 `isPreferred = true`。

### 5.4 统一媒体模型

```swift
struct BabyPlayerMediaItem: Identifiable, Sendable {
    let id: String                    // 该来源实例内稳定 ID
    let sourceProfileID: UUID
    let contentIdentity: String?      // 跨住宅识别同一内容
    let title: String
    let relativePath: String?
    let durationSeconds: Double?
    let fileSize: Int64?
    let modifiedAt: Date?
    let compatibility: MediaCompatibility
    let playbackResource: BabyPlayerPlaybackResource
    let providerImageURL: URL?
    let chapterMarkers: [BabyPlayerChapterMarker]
}

enum BabyPlayerPlaybackResource: Sendable {
    case http(URL)
    case smb(SMBFileReference)
}

enum MediaCompatibility: Sendable {
    case candidate
    case playable
    case unsupported(reason: String)
}
```

`JellyfinMediaItem` 保留为网络 DTO，由 Jellyfin provider 转换为 `BabyPlayerMediaItem`。首页、`SpikeViewModel` 和 `SystemPlayerView` 逐步改为只消费统一模型。

### 5.5 两层身份

不能继续把 Jellyfin Item ID 当作所有来源的永久身份。建议区分：

1. `id`：来源实例身份，用于当前目录刷新和播放队列。
2. `contentIdentity`：内容身份，用于跨住宅复用评分、歌词、封面和智能跳过结果。

SMB 实例 ID 也使用无歧义二进制帧，合法文件名中的 `|` 等字符不会造成拼接碰撞：

```text
SHA256(
    ASCII "BabyPlayer.Instance.v1\0" +
    UUID raw 16 bytes +
    UInt32-BE shareUTF8.count + shareUTF8 +
    UInt32-BE normalizedPathUTF8.count + normalizedPathUTF8
)
```

最终 ID 一律为 SHA-256 小写十六进制字符串。跨住宅自动复用内容相关数据时使用强内容身份：

```text
contentIdentity = "sha256:" + lowercaseHex(SHA256(文件全部原始字节))
```

完整 hash 使用固定 1 MiB 块流式更新，在 Phase C 后台惰性计算、播放时暂停，并持久缓存；首屏不等待它。hash 开始前记录 `size/modifiedAt/serverFileID/quickChangeToken`，读完后重新 stat 并重算 quick token；前后任一字段变化则丢弃 digest、等待文件稳定后重试，绝不提交一个跨越两个文件版本的身份。当前共享约 1.3 GiB，因此首次强身份建立会在后台读取约 1.3 GiB，而不是用“首尾相同就视为同一内容”的弱假设。Jellyfin/Mac 已有的 `media_content_sha256` 只有经同一 fixture 证明是“原文件全部字节 SHA-256”时才可直接加 `sha256:` 前缀复用，否则 Jellyfin provider 也需流式计算。

另存一个只用于增量变更探测的 `quickChangeToken`：`fileSize + 首/中/尾各 4 KiB` 的长度帧 SHA-256。它是概率性变化提示，不能保证发现采样区外且保留 size/mtime/fileID 的原地覆盖；因此它不能建立强身份，也不能单独授权迁移 ASR、评分、续播或智能跳过。任何跨 profile 的内容数据首次绑定前，都重新计算双方完整 hash 并执行上述前后稳定性检查；日常同源缓存复用接受家庭只读媒体库中的这项非对抗性假设。若未来需要面对可并发写入或不可信共享，策略升级为每次完整刷新重算全量 hash。

文件变化时旧强身份立即失效，新身份确认后用单个存储事务完成 re-key：先写新 key 和 `oldKey → newKey` 别名，再切换引用，最后标记迁移完成。事务带 migration ID，可重复执行且不得重复复制；崩溃重启后从未完成步骤继续。两个路径若强 hash 完全相同，视为同一内容是预期行为；若 hash 不同，即使标题、大小和时长相同也不得复用内容相关结果。

现有 Jellyfin 数据迁移按以下优先级匹配：

1. 相同强 `contentIdentity`：允许跨 provider 复用评分、续播、封面、已有字幕和智能跳过。
2. 同一 Jellyfin profile 内相同旧 `mediaSourceID`：只做原 provider 的旧 key → 新实例 key 迁移。
3. 规范化标题相同、时长误差不超过 1 秒且候选唯一：仅作为普通歌词搜索词和家长确认提示。

弱标题/时长匹配永远不自动复制评分、续播、封面、ASR/DeepSeek 字幕或智能片头片尾；没有强身份时宁可重新搜索普通歌词，也不误绑内容结果。

SMB 路径在进入模型前统一规范化：分隔符统一为 `/`，去除重复分隔符和首尾空段，Unicode 转 NFC；保留大小写，不做 locale lowercasing。拒绝 NUL、`.`、`..`、绝对子路径及任何逃出配置根目录的组合；目录项若标记为 reparse point/symlink 则第一版不递归跟随。实际打开文件时仍使用服务器返回的原始名称，规范化字符串只用于比较和 ID。

## 6. SMB 访问层

### 6.1 推荐依赖

第一阶段采用 [AMSMB2](https://github.com/amosavian/AMSMB2) 做真实 tvOS Spike。它明确支持 iOS、macOS、tvOS 和 SMB2/3，并提供按 offset/range 读取文件内容的接口，适合 AVFoundation 的随机读取需求。

当前中兴路由器实际协商为 SMB 2.0.2，位于 AMSMB2 的目标范围内。

依赖引入前必须保留一个发布门槛：AMSMB2 静态链接 `libsmb2`，其 README 标明 LGPL 2.1 约束。当前家庭内开发测试可先完成技术 Spike；若未来上架 App Store，必须在发布前确认动态链接方案和完整许可证义务。不要等到上架阶段才处理。

不推荐第一版改用 TVVLCKit：当前 78 个视频已全部是系统可直接解码的 H.264/AAC，VLCKit 会显著增加包体和播放器替换范围，并破坏现有基于 `AVPlayerViewController` 的歌词与播放控制集成。

### 6.2 只读接口与连接池

provider 只依赖自有抽象，避免业务层绑定 AMSMB2 类型：

```swift
protocol SMBByteRangeReading: Sendable {
    func stat(_ file: SMBFileReference) async throws -> SMBFileStat
    func read(_ file: SMBFileReference, offset: UInt64, length: Int) async throws -> Data
}

protocol SMBDirectoryReading: Sendable {
    func list(_ directory: SMBDirectoryReference) async throws -> [SMBDirectoryEntry]
}
```

`SMBConnectionPool` 拥有最多两条 SMB 连接，而不是假设单个 actor 的 FIFO 就能提供播放优先级：

- `playback session`：专供当前 AVAsset 的 byte-range 请求；资源加载器内部串行调度实际读操作。
- `background session`：扫描、封面和内容指纹共用；严格串行。
- 播放开始时取消尚未发出的后台请求并暂停新后台工作；播放稳定 5 秒后才允许低优先级工作恢复。
- 下一个待播项目可以保留逻辑引用，但只有切歌准备窗口内才打开第二个播放文件句柄；总连接数仍不超过 2。
- profile 切换、进入后台或网络路径变化时，由 pool 统一关闭连接和文件句柄。

连接对象不得持有 UI、排序、歌词或播放器状态。取消从 `Task` 传播到底层读取；若第三方库不能取消正在进行的系统调用，则丢弃其迟到结果，不得回写已经取消的 AVFoundation 请求。

### 6.3 只读规则

应用层只暴露以下 SMB 操作：

- connect/disconnect
- listDirectory
- attributes/stat
- readRange

不把 write、remove、move、rename、mkdir 等能力暴露给媒体 provider，避免未来 UI 误调用。

App 仅连接 TCP 445 与 SMB2/3；即使实测路由器开放 139，也不回退 SMB1/NetBIOS。若协商不到 SMB2，则报告“不支持的 SMB 版本”。

## 7. 媒体扫描

### 7.1 扫描范围

第一版允许递归扫描配置根目录，默认最大深度 5、最多遍历 10,000 个目录项、收录 2,000 个媒体候选；全量前台扫描软预算 20 秒。达到时间或数量上限时提交带 `isPartial = true` 的完整内存快照并明确提示“仅显示部分内容”，后台可从 continuation cursor 继续，而不是将部分扫描当作完整库。

“扫描”包含两个明确阶段，UI 和缓存不得共用一个含糊的 completed 布尔值：

1. `traversal`：目录遍历与候选过滤，状态为 `partial/complete`。
2. `validation`：逐候选 AVAsset 轨道/解码验证，状态为 `pending(validated,total)/complete`。

遍历完成后首页可以先显示候选卡；只有已验证 `playable` 的卡片可点播和进入自动队列。“媒体库完整扫描完成”专指 traversal 与 validation 都为 complete，此时才允许宣称最终可播放数量和隐藏 unsupported 项。

以下扩展名仅代表“进入兼容性验证的候选”，不等于一定可播放：

- `.mp4`
- `.m4v`
- `.mov`

`.mkv`、`.webm` 等格式在完成真实系统播放器兼容验证前不加入候选列表。第一版保证当前媒体基线 H.264 视频 + AAC LC/HE-AAC 音频；候选文件还必须通过 SMB-backed AVAsset 的 `isPlayable`、时长和音视频轨道加载。未知或解码不兼容的文件标记为 `unsupported`，默认不进入儿童播放队列，家长页可查看原因。

### 7.2 过滤规则

忽略：

- 任何以 `.` 开头的文件或目录。
- 任何文件名以 `._` 开头的 AppleDouble 文件。
- `.DS_Store`、`.Spotlight-V100`、`.fseventsd`。
- `$RECYCLE.BIN`、`System Volume Information`、`@eaDir`。
- 扩展名不在允许列表中的文件。
- 大小为 0 的文件。
- reparse point/symlink，及任何规范化后逃出根目录的路径。

这会把当前共享中看到的 156 个 `.mp4` 名称正确收敛为 78 个真实视频。

### 7.3 增量扫描

本地缓存每项的 `relativePath + fileSize + modifiedAt + serverFileID? + quickChangeToken`。每次完整刷新都读取首/中/尾各 4 KiB 重算 quick token；当前 78 个文件约增加 1 MiB 读取。这样即使 FAT/SMB 时间戳精度较粗或文件被同大小覆盖，也不会只凭 path/size/mtime 复用旧内容。扫描逐项容错：单个目录或文件 stat 失败只记录脱敏错误并继续，只有根目录不可读才让整个 source 失败。刷新时：

- 上述字段均未变化：复用已有标题、时长、封面和强内容身份；`serverFileID` 不可用时必须以 quick token 补位。
- 新文件：加入待元数据队列。
- 文件变化：使旧内容指纹和封面失效。
- 文件暂时缺失：本次完整扫描结束后再从活动列表移除，避免扫描中间态闪烁。

扫描结果在内存中完成后原子替换首页数据。索引写入 `Caches` 时使用“临时文件 → 校验 → 原子 replace”，包含 `schemaVersion`、profile ID、扫描是否完整和 continuation。JSON 损坏时隔离损坏文件并重扫；缓存 schema 高于当前 App 时忽略而不覆盖，防止降级安装破坏新缓存。

### 7.4 元数据补全

目录扫描先用文件名生成标题，让首页尽快可见。时长和可播放性随后通过 SMB-backed AVAsset 异步补全；尚未验证的候选可以显示占位卡，但卡片在变为 `playable` 前不可进入自动播放队列。Phase C 将 Phase A 的原型 loader 提炼成生产最小内核，支持 content info、有界 range、取消和 EOF，专供元数据验证；Phase D 再完成 seek 优先级、预读、断线重连、播放器 lifetime 和封面等完整播放能力。

文件名 `52. After A While Crocodile.mp4` 继续复用现有 `LyricsTitleMetadata.parse`，展示标题可选择保留当前文件名或去掉数字前缀；歌词搜索使用去前缀后的 `searchTitle`。

## 8. SMB 直接播放

### 8.1 为什么不能直接传 smb:// URL

现有代码使用：

```swift
AVPlayerItem(url: queueItem.url)
```

系统 AVPlayer 不负责登录并浏览普通 Samba 共享。SMB provider 必须提供一个自定义 AVAsset 资源加载器，把 AVFoundation 的字节范围请求转换为 SMB `readRange`。

### 8.2 播放资源工厂

把 `BabyPlayerQueueItem.url` 改为 `playbackResource`，由工厂创建播放器项：

```swift
struct PreparedPlayerItem {
    let playerItem: AVPlayerItem
    let lifetime: AnyObject
}

protocol BabyPlayerPlaybackItemFactory {
    func makePlayerItem(
        for resource: BabyPlayerPlaybackResource,
        title: String
    ) async throws -> PreparedPlayerItem
}
```

- HTTP/Jellyfin：继续生成普通 `AVPlayerItem(url:)`。
- SMB：创建自定义 scheme 的 `AVURLAsset`，安装 `AVAssetResourceLoaderDelegate`，再生成 `AVPlayerItem(asset:)`。
- `lifetime` 保证 SMB session、文件句柄和 resource loader 在当前播放器项结束前不会释放。
- 自定义 URL 只包含不可逆的本地 asset UUID，例如 `babyplayer-smb://asset/<uuid>`；不得把用户名、密码、IP 或远端路径编码进 URL、日志或 AVPlayer error。

`BabyPlaylistPlayerViewController` 在切歌和 `cleanUp()` 时释放旧 lifetime。

### 8.3 字节范围加载器

`BabyPlayerSMBResourceLoader` 的 delegate 固定运行在专用串行队列。它维护 `AVAssetResourceLoadingRequest → Task/cancellation token` 映射，并遵循以下规则：

- `contentInformationRequest` 返回可信的文件长度、由扩展名和容器验证得到的 content type，并声明 byte-range access。
- 数据读取从 `currentOffset`（若未设置则 `requestedOffset`）开始；普通请求最多读取 `requestedLength`。
- `requestsAllDataToEndOfResource == true` 时不分配“剩余文件大小”的大缓冲，而是用 512 KiB～1 MiB 小块持续 `respond(with:)`，到 EOF 或取消为止。
- 同一文件的相邻/重叠请求可命中最多 8 MiB 的有界读缓存；不相邻 seek 立即丢弃旧预读。所有活动读取、缓存和响应块总内存硬上限 16 MiB。
- 底层 playback session 一次只执行一个 SMB read；新 seek 请求优先于未发出的顺序预读。每个 read 返回后检查取消，再向 AVFoundation 响应。
- 短读不是自动成功：有数据时推进 offset 并继续；只有 offset 达到已知文件长度时才以 EOF 正常结束。文件尾前返回 0 字节时重连一次，再次为 0 则 `readInterrupted`。
- `didCancel` 必须取消对应 task、停止继续响应并释放其缓存引用；迟到的网络结果只能丢弃。
- 网络瞬断允许重建一次会话和文件句柄，但恢复前重新 stat，并核对 `fileSize + modifiedAt + serverFileID（若可用）`。任何一项变化都返回 `fileChanged`，绝不从旧 offset 盲目续读新文件。
- 每个 loading request 最多重连一次；重试仍失败时用 `finishLoading(with:)` 把分类错误交给播放器 UI，不无限等待。
- 单次底层 read 软超时 5 秒，包含一次重连的 loading request 硬截止 10 秒；超时即结束该 request 并回到可操作错误界面。

多个 AVFoundation 请求可以同时处于等待状态，但只由调度器决定哪个先实际读，不能依赖 actor/FIFO 暗示优先级。第一版不把完整视频复制到 Apple TV，也不建立持久视频缓存。

### 8.4 播放行为兼容

以下现有能力必须在 SMB 下保持相同：

- 单曲循环重建播放器项。
- 顺序、随机和偏好优先队列。
- 暂停、恢复和倍速。
- 精确 seek 与续播。
- 定时关闭。
- 手工/智能片头片尾。
- 播放结束通知和下一首。
- 歌词叠加与遥控器菜单。

切歌时允许异步准备下一个 SMB 播放器项，但不能同时打开过多文件句柄。当前项和下一个预备项合计最多两个句柄。

## 9. 封面与本地缓存

现有 `BabyPlayerCoverSource` 已表达“来源封面优先、视频抽帧兜底”，但只接受 `videoURL`。将其改为接受 provider-neutral playback resource 或 asset factory。

SMB 没有 Jellyfin 封面时：

1. 首屏先显示稳定占位图。
2. 使用同一个 SMB resource loader 创建 AVAsset。
3. 在视频 12%、30%、50%、70%、88% 位置沿用现有评分算法选择封面。
4. 强 `contentIdentity` 已就绪时以它作为缓存 key；尚未就绪时暂用实例 `id`，强身份生成后通过 alias 迁移，不能阻塞首屏封面。
5. 每次只生成一张封面；播放开始后暂停后台生成。

可重建数据保存在 Caches：

- 媒体目录索引。
- 文件 stat 信息。
- 内容指纹。
- 本地封面。

不可依赖 Caches 永久存在。被 tvOS 清理后，应用能够重新扫描和生成。

## 10. 字幕和 AI 服务解耦

### 10.1 现状问题

当前 `BabyPlayerServiceConfiguration` 总是从 Jellyfin 地址提取 host，然后固定连接同一 host 的 `8011/v1`。切换到 SMB 后若继续沿用这一规则，会错误尝试访问：

```text
http://192.168.1.1:8011/v1
```

路由器不是 AI 服务，因此必须拆分配置。

### 10.2 目标模型

```swift
enum BabyPlayerAnalysisServiceMode: String, Codable {
    case disabled
    case macLocal
    case cloud
}

struct BabyPlayerAnalysisServiceProfile: Codable {
    var mode: BabyPlayerAnalysisServiceMode
    var baseURL: URL?
    var displayName: String
}
```

媒体源与分析服务是两个独立选择：

```text
媒体源：光猫 U 盘 SMB
分析服务：家中 Mac 8011（可选）
```

### 10.3 当前阶段行为

- 在启用 SMB 产品入口之前，先把 `BabyPlayerServiceConfiguration` 改为直接读取独立的 analysis profile，不再从 Jellyfin host 推导地址；这项最小解耦属于 Phase B。
- Mac 在线：允许发起 ASR/DeepSeek。
- Mac 离线：播放、已有字幕、本地歌本和 LRCLIB 普通歌词继续工作；新分析入口显示“电脑端字幕服务当前不可用”。
- App 启动不等待 AI 服务健康检查，AI 失败不改变媒体源状态。
- 家长页的批量 AI 页面在服务离线时显示暂停，不影响返回首页播放。

### 10.4 SMB 视频如何交给 Mac 分析

现有 Mac job 依赖 `BabyPlayerQueueItem.localMediaPath`，SMB 文件在 Apple TV 上没有 Mac 本机路径。推荐分两阶段：

1. SMB 首个可播放版本：复用已有字幕和普通歌词；暂不对 SMB 新视频发起本机 path job。
2. 字幕兼容阶段：Apple TV 通过 SMB asset 临时提取所需 M4A 音频片段，调用现有 `/analyze` 上传接口。Mac 只接收短命音频，不需要挂载路由器 U 盘。

沿用现有 `/v1/analyze` 合同：Bearer token；`multipart/form-data` 中包含 `operation_id`、`media_fingerprint`、`media_title`、`duration_seconds`、`voice_format=m4a`、`force_refresh` 和 `audio`；响应仍解码为 `BabyPlayerASRAnalysis`。客户端把每个上传单元限制为不超过 20 分钟且不超过 32 MiB，超出时按现有 segment policy 分段。Phase F 必须把当前 `Data(contentsOf:)` 拼装 multipart body 改为 file-backed/streamed upload，避免音频与请求体同时常驻内存。临时 M4A 和 multipart 文件在成功、失败或取消后立即删除；App 启动时清理残留超过 1 小时的 `BabyPlayer-ASR-Segments` 文件。服务端任务只保留结果缓存，不把上传音频当永久媒体库。

代码中已经保留 `BabyPlayerASRAudioSegmentPreparer` 和 `/analyze` 上传路径，可以复用；只需让 ASR coordinator 根据媒体的 `analysisInput` 选择“Mac 本机 path job”或“客户端提取并上传”。

未来迁移云端时，继续复用同一上传接口和 `BabyPlayerAnalysisServiceProfile`，不再修改媒体 provider。

## 11. 持久化与升级兼容

### 11.1 存储位置

- 媒体源非敏感配置：UserDefaults 中的版本化 JSON。
- SMB 密码：Keychain，由 source profile 的 `credentialReference` 指向。
- Jellyfin token：保留现有 Keychain，迁移后也按 `credentialReference` 管理。
- 活动配置、自动/固定切换模式：UserDefaults。
- 可重建媒体目录和封面：Caches。
- 评分、屏蔽、续播和歌词：继续使用现有本地机制，但 key 改为优先使用 `contentIdentity`。

配置与凭据用两阶段提交，避免崩溃后出现“配置已保存但密码不存在”：

1. 为新增/编辑事务生成 `credentialReference` 和 transaction ID，先写入新的 Keychain 项。
2. 把引用新凭据的整个版本化 JSON 作为单个 UserDefaults value 提交，并立即回读解码校验。
3. 提交成功后再删除旧 credential reference；配置提交失败则删除新项并保留旧 profile。
4. 删除 profile 时先提交不再引用它的新配置，再删除 Keychain 项；即使第二步中断也只会留下孤儿凭据，不会破坏活动配置。
5. 启动时清理超过 24 小时且未被任何 profile 引用的孤儿项。日志只记录 transaction ID，不记录 secret。

### 11.2 现有用户迁移

升级时若检测到旧 `JellyfinCredentialStore`：

1. 使用固定 migration ID 查找或创建名为“现有 Jellyfin”的 Jellyfin profile，重复启动不会创建第二份。
2. 保持它为当前活动源。
3. 先复制 token 到新 credential reference；新 profile 验证读取成功并写入 migration-complete marker 前，不删除旧 token。
4. 用户添加 SMB 后才出现自动切换选择。
5. Jellyfin 模式所有旧行为保持不变。

### 11.3 配置版本

配置外层增加 schema version：

```swift
struct StoredMediaSourceConfiguration: Codable {
    var schemaVersion: Int // 初始为 1
    var selectionMode: SourceSelectionMode
    var activeProfileID: UUID?
    var preferredProfileID: UUID?
    var lastSuccessfulProfileID: UUID?
    var lastSuccessfulNonSMBProfileID: UUID?
    var profiles: [BabyPlayerMediaSourceProfile]
}
```

旧版本升级通过带 migration ID 的纯函数逐级迁移并覆盖单元测试；每一步可重复执行。遇到损坏 JSON 时保留原始 Data 的诊断副本并进入安全的“需要重新配置”状态，不清空 Keychain。遇到高于当前 App 的 schema 时只读失败并提示“需要更新 BabyPlayer”，绝不按旧结构覆盖新配置。

## 12. 状态机与并发

`MediaSourceCoordinator` 的公开状态：

```swift
struct MediaLibraryProgress: Equatable {
    var traversalIsComplete: Bool
    var validationCompletedCount: Int
    var validationTotalCount: Int

    var validationIsComplete: Bool {
        traversalIsComplete && validationCompletedCount == validationTotalCount
    }
}

enum MediaSourceState: Equatable {
    case unconfigured
    case selecting
    case connecting(profileID: UUID)
    case scanning(profileID: UUID)
    case switching(from: UUID?, to: UUID)
    case ready(profileID: UUID, itemCount: Int, progress: MediaLibraryProgress)
    case offline(lastProfileID: UUID?)
    case failed(profileID: UUID?, reason: MediaSourceFailure)
}
```

并发约束：

- 同一时间只有一个活动扫描 task。
- source generation 每次切换递增；旧 task 完成时若 generation 过期，不得写回 UI。
- coordinator 拥有 provider 生命周期和首页快照；`PlaybackItemFactory` 拥有当前 item 的 loader lifetime；`SMBConnectionPool` 只拥有连接与句柄。
- SMB 连接由 connection pool 隔离；播放与后台工作使用不同 session，调度规则见 6.2。
- 手动切换只有 `ready(newProfile)` 可以提交；失败/取消回滚到切换前的 ready/offline 快照。
- 取消扫描必须关闭未使用文件句柄。
- SwiftUI 只在 MainActor 接收完整快照。
- AI 服务使用独立状态机；其 health check、超时或失败不得触发媒体 source generation，也不得把 `.ready` 改为 `.failed`。

这一 generation 模式可复用项目现有 `LyricsAutomationGenerationGuard` 的设计思想，但媒体源使用独立实现，避免两个领域共享状态。

## 13. 错误模型

内部错误至少区分：

```swift
enum MediaSourceFailure: Error, Equatable {
    case hostUnreachable
    case connectionTimedOut
    case authenticationFailed
    case shareNotFound
    case rootFolderNotFound
    case permissionDenied
    case noSupportedMedia
    case fileChanged
    case readInterrupted
    case unsupportedFormat
    case cancelled
}
```

儿童播放错误只显示简短文案和返回按钮；完整恢复动作放在家长设置：

| 内部错误 | 儿童界面 | 家长恢复动作 |
|---|---|---|
| hostUnreachable | 视频暂时不可用 | 检查当前住宅网络、重新连接 |
| authenticationFailed | 需要家长处理 | 重新输入 Samba 密码 |
| shareNotFound | 存储设备未准备好 | 修改共享名 |
| rootFolderNotFound | 没有找到视频目录 | 修改媒体目录 |
| readInterrupted | 播放连接中断 | 重试当前视频 |
| unsupportedFormat | 这个视频暂时不能播放 | 查看支持格式 |

日志不得记录 SMB 密码、Jellyfin token 或带凭据 URL。路径只在 Debug 的隐私保护日志中显示，Release 错误使用分类和哈希 ID。

家长页提供“复制诊断摘要”，只包含：App/tvOS 版本、Apple TV 型号、当前 profile 类型、脱敏主机哈希、SMB 协商版本、状态机状态、扫描数量/是否 partial、最近错误分类、启动/seek 时延和重试次数；不得包含用户名、密码、token、完整 IP、共享路径或媒体文件名。

## 14. 文件修改规划

### 14.1 新增文件

| 文件 | 职责 |
|---|---|
| `MediaSourceModels.swift` | profile、统一媒体模型、错误和状态 |
| `MediaSourceStore.swift` | 配置迁移、UserDefaults、Keychain 凭据 |
| `MediaSourceCoordinator.swift` | 自动探测、切换、扫描生命周期 |
| `JellyfinMediaSourceProvider.swift` | 把现有 Jellyfin 客户端包装成 provider |
| `SMBConnectionPool.swift` | AMSMB2 两会话连接池、只读 API 和优先级调度 |
| `SMBMediaSourceProvider.swift` | SMB 连接测试、目录扫描、过滤和增量索引 |
| `SMBAssetResourceLoader.swift` | AVFoundation byte-range → SMB range read |
| `PlaybackItemFactory.swift` | HTTP/SMB 创建统一 AVPlayerItem |
| `MediaSourceTests.swift` | 模型、迁移、切换和扫描策略测试 |
| `SMBResourceLoaderTests.swift` | range、取消、重连和 EOF 测试 |

### 14.2 修改文件

| 文件 | 修改目的 |
|---|---|
| `BabyPlayer.xcodeproj/project.pbxproj` | 加入新文件和 SMB Swift Package |
| `SpikeViewModel.swift` | 使用统一媒体模型和 coordinator |
| `SpikeRootView.swift` | 新首次配置和媒体源管理 UI |
| `SystemPlayerView.swift` | 使用 PlaybackItemFactory，管理 SMB loader 生命周期 |
| `MediaCoverLoader.swift` | 从 URL 输入升级为 provider-neutral asset 输入 |
| `BabyPlayerASR.swift` | 分离分析服务地址，按 analysisInput 选择 path job 或上传 |
| `LyricsRepository.swift` | 使用 contentIdentity，并迁移旧 Jellyfin 绑定 |
| `Info.plist` | 把现有本地网络说明改为准确的“路由器 U 盘/SMB”文案；tvOS 当前无权限 gate，若以后启用 Bonjour 再加 service 声明 |

不建议继续把所有 provider 分支堆进 `SpikeViewModel.swift`，否则会把网络会话、扫描、播放资源和页面状态重新耦合到一个大类中。

## 15. 分阶段实施计划

每个阶段结束时工程必须保持可构建、Jellyfin 可回退，并在真实 Apple TV 上验证。

### Phase A：真实 tvOS 端到端 SMB 播放与许可证 Spike

- 在隔离模块中引入 AMSMB2，真实 Apple TV 连接 `192.168.1.1/usb-0781-060116_1/sss73`。
- 先验证登录、递归列表以及同一 MP4 的开头、中间、尾部 range read。
- 完成最小 `AVURLAsset + AVAssetResourceLoaderDelegate`，必须真正进入 `AVPlayerItem` 播放，而不是止于读到 Data。
- 真机覆盖：首次起播、前后 seek、暂停/恢复、AVFoundation 取消请求、EOF、切歌释放、App 后台/前台、路由器短暂断线后重连，以及文件断线期间被替换时拒绝盲续读。
- 记录 Apple TV 型号、tvOS、网络接入方式、冷/热起播 P50/P95、seek P50/P95、峰值内存、平均/最低有效吞吐和错误率。
- 同步完成 AMSMB2/libsmb2 的 tvOS 链接方式、LGPL 义务、App Store 分发可行性书面结论。

技术硬门槛：真实 78 文件可完整列出；开头/中间/尾部读取与 Mac 参考字节 hash 完全一致；10 次冷起播 + 10 次热起播及各自 seek 均在 10 秒硬超时内成功；取消、EOF、后台恢复和断线重连没有错序响应、数据损坏、崩溃、死锁或无限 loading；resource loader 活动内存不超过 16 MiB。许可证硬门槛：拟采用的二进制链接与交付方式有书面结论可满足分发义务。任一硬门槛失败即 No-Go，停止进入 Phase B 并先验证替代 SMB 库或合规链接方案。

第 16.4 节的起播 P95 ≤ 3 秒、seek P95 ≤ 2 秒属于产品发布目标：Phase A 未达到时可继续做隔离架构工作，但必须登记性能风险，并在 Phase D 默认开启 feature flag 前达标。任何硬门槛或发布目标调整都必须修改本文档、保留测量依据并由产品所有者确认，实施者不能用一次较慢实测自行移动通过线。

### Phase B：统一媒体模型与 Jellyfin 适配

- 增加统一 `BabyPlayerMediaItem` 和 provider 边界。
- Jellyfin provider 包装现有行为。
- 首页和播放队列改用统一模型。
- 实现第 5.5 节内容身份的规范编码、legacy alias 和幂等迁移框架；Jellyfin 可先按现有 media source ID 建立映射。
- 把 analysis service 地址从 Jellyfin host 中拆出，AI 状态完全独立；此阶段保持现有 Mac path job 行为，不做 SMB 音频上传。
- 现有 Jellyfin 单元测试和真机播放全部保持通过。

通过条件：用户看不到行为变化，但 UI 不再依赖 `JellyfinMediaItem`，关闭 AI 服务不会改变 Jellyfin 媒体 ready 状态。

### Phase C：SMB 配置、扫描和缓存

- 实现 SMB 配置页、测试连接和 Keychain。
- 实现目录过滤、增量扫描、原子快照。
- 把 Phase A 原型资源加载器提炼成生产最小内核（content info、有界 range、取消、EOF），用于候选元数据/可播放性验证。
- 实现路径规范化、可播放性验证、partial scan 和缓存 schema 恢复。
- 在后台计算规范化 `contentIdentity`，以便 Phase D 封面直接使用；不能把身份依赖推迟到双住宅阶段。
- 首页展示 78 个条目和稳定占位封面。

通过条件：Mac/Jellyfin 是否运行都不影响 Apple TV 完成 SMB traversal；当前 manifest 的 validation 全部完成并得到 78 个 playable、0 个意外 unsupported；生产最小 loader 的 content info、取消、短读和 EOF 集成测试通过；强 hash 通过前后 stat/quick-token 稳定性 fixture；缓存删除、损坏和高版本 schema 均能按第 7/11 节恢复。未满足这些条件不得进入 Phase D。

### Phase D：SMB 播放与封面

- 在 Phase C 最小内核上完成 SMB resource loader 的 seek 调度、预读、断线一致性与播放器 lifetime，并接入播放资源工厂。
- 保持现有播放模式、续播、seek 和歌词菜单。
- 完成 SMB 视频抽帧封面和缓存。
- SMB 产品入口受运行时 feature flag 控制；真机回归通过后才默认开启。

通过条件：Mac 关机后，冻结清单中的全部文件都完成基本起播；代表性 10 个样本完成 seek、循环、下一首、睡眠恢复和断线场景。

### Phase E：双住宅自动切换

- 支持多个 profile、自动探测和手动固定。
- 完成离线缓存、路由器重启、U 盘拔插恢复。
- 完成 provider-neutral 强身份：SMB 使用 Phase C 的全文件 hash；Jellyfin 的 `media_content_sha256` 先用共同 fixture 证明语义相同，不相同或缺失时由 Jellyfin provider 对 direct-play HTTP 响应流式计算。两边强 hash 均通过稳定性确认后，才复用两处住宅的评分和字幕。
- 用两个可控测试 profile 验证冲突、回滚和确定性选择；另一住宅真实参数取得后再做现场验收。

通过条件：受控双 profile 测试全部通过；当前光猫住宅真机冷启动正确，另一住宅字段明确列为“待现场验证”而不是虚构已通过。

### Phase F：SMB 的 Mac 字幕上传与云端预留

- SMB 视频使用 Apple TV 临时音频提取 + `/analyze` 上传。
- 落实 20 分钟/32 MiB 单元上限、取消删除和启动残留清理。
- Mac 离线时降级但不阻断播放。
- 保持未来 cloud baseURL 替换能力。

通过条件：SMB 播放无 Mac；需要生成字幕时开启 Mac 即可处理，关闭 Mac 后已有字幕继续显示。

## 16. 测试计划

### 16.1 单元测试

- SMB 路径规范化和特殊字符。
- `..`、绝对子路径、Unicode NFC、reparse point 和根目录逃逸拒绝。
- 隐藏文件、`._*.mp4` 和系统目录过滤。
- 实例 ID 长度帧 fixture；强 contentIdentity 的空/短/长文件全量流式 hash、hash 中途变更的前后 stat 拒绝；quick token 首/中/尾采样；以及 re-key 崩溃恢复。
- 增量扫描 diff、时间/数量预算、partial continuation、单文件失败和原子 cache replace。
- 损坏缓存、高版本 schema、幂等配置/旧 Jellyfin 迁移和 Keychain 两阶段提交各崩溃点。
- 多 profile 自动选择优先级、固定模式离线、重试预算重置和手动切换失败回滚。
- source generation 防止旧任务回写。
- Keychain profile 隔离与孤儿清理。
- 评分、续播和歌词跨来源匹配。
- byte range 的 offset、`currentOffset`、重叠请求、`requestsAllDataToEndOfResource`、短读、EOF 和取消。
- 网络失败只重连一次；恢复时文件 stat 改变则失败，不会无限循环或错误续读。

### 16.2 集成测试

- 用 fake SMB provider 测试目录扫描和状态机。
- 用内存 byte reader 驱动 resource loader。
- 并发发出顺序读、seek 和取消，确认 seek 抢占未发出的预读，迟到响应被丢弃，内存不超过 16 MiB。
- 验证 AVPlayerItem 生命周期结束时释放 loader 和句柄。
- 验证播放期间暂停封面预热。
- 验证 AI 服务离线不改变媒体源 ready 状态。

### 16.3 真实 Apple TV 验收矩阵

1. 完成一次家长配置后，Mac 和 Jellyfin 全部关闭，路由器/U 盘在线，冷启动并播放。
2. 扫描结果与 Phase A 冻结的光猫 U 盘基线 manifest 一致（2026-09-05 当前为 78 个），无 `._` 重复项；日后 U 盘内容变化时以新 manifest 为准，不在代码中硬编码 78。
3. manifest 中所有文件逐一完成“建立播放器项并持续播放至少 10 秒”的基本起播检查。
4. 从样本中固定选 10 个代表文件，覆盖 1080p High、720p/SD Main、AAC LC、唯一 HE-AAC、最大/最小文件及不同文件名；逐一验证暂停、恢复、前后 seek、循环和下一首。
5. 播放中拔掉 U 盘，应用不崩溃并能返回首页。
6. 插回 U 盘并重新连接，目录恢复。
7. 重启路由器，Apple TV 保持配置并可恢复会话。
8. 修改 Samba 密码，确认只需更新凭据。
9. Apple TV 睡眠后唤醒，重新连接成功。
10. Mac 关闭时 AI 状态显示不可用，但已有字幕与普通歌词正常。
11. 用第二个可控测试 profile 验证自动选择、固定不回退、手动切换失败回滚；另一住宅拿到真实地址、共享和目录后补一次现场冷启动验收。

故障注入脚本固定为：用专用测试文件开始播放后让 SMB 根目录不可读 30 秒；loading request 在 10 秒硬截止附近结束、最迟 12 秒内出现可操作错误且不切源；恢复到 TCP 445 可连接、认证和根目录可读后点击“重新连接”，30 秒内回到 ready。路由器整机重启按“根目录重新可读”的时点开始计算同一 30 秒恢复窗口。文件替换测试只在专用 fixture 上执行，不改动 78 个正式媒体；同路径文件替换后必须返回 `fileChanged`。

### 16.4 性能目标

性能报告必须记录 Apple TV 型号、tvOS 版本、Apple TV 的有线/Wi-Fi 接入方式、路由器固件、共享和媒体 manifest 版本。每项分别执行 10 次冷态与 10 次热态，报告 P50、P95、最大值和成功率：冷态指关闭旧 SMB session 后首次操作，热态指同一 App 进程内已有索引/会话时再次操作。

在当前光猫 U 盘基线 manifest 下，产品目标为：

- 已有缓存时，首页首批卡片 P95 在 2 秒内出现。
- 首次目录扫描 P95 在 10 秒内给出可用且明确标识 partial/complete 的首页；封面允许后台逐步出现。
- 点击视频到首帧/声音的 P95 在 3 秒以内。
- 普通 seek 到恢复播放的 P95 在 2 秒以内。
- 不下载完整视频作为播放前置条件。
- resource loader 活动内存不超过 16 MiB；后台最多一个封面生成任务；播放资源句柄最多两个；测试期间无内存警告或系统终止。
- 20 次起播和 20 次 seek 性能运行均不得崩溃、卡死或无限 loading；超出时延目标可以记录为性能失败，但必须能返回可操作的错误界面。

这些是冻结的验收目标，不作为未经真机测量的既成事实。Phase A/D 必须记录真实 Apple TV 数据；如确需调整阈值，只能按第 15 节的文档修订与产品所有者确认流程执行。

## 17. 发布与回滚

- SMB provider 作为新增能力交付，不删除 Jellyfin 代码。
- 家长手工选择哪个媒体源，下次启动就默认继续使用该源；不得自动跳回 Jellyfin。
- 任何 SMB 阶段出现阻塞时，家长可以切回 Jellyfin。
- 每个 Phase 独立提交并保持可构建。
- `BabyPlayer.Features.SMBDirectPlayback.v1` 运行时 feature flag 在当前内部 Debug 版开启；真机功能链路通过后，已将 Samba 接入正常首页。关闭 flag 不删除 profile、Keychain 或缓存，因而可安全回滚到 Jellyfin。
- flag 关闭时，source coordinator 在探测前排除所有 SMB profile。若当前活动源或固定源是 SMB，则保留原 selection mode 但本次运行优先尝试 `lastSuccessfulNonSMBProfileID`；它不存在、停用或离线时显示“SMB 功能暂时停用”，不把任意其它源伪装成原固定源。重新开启 flag 后恢复原固定/自动选择，不改写家长配置。
- 当前私有真机版按家长最后选择决定默认源；若后续回归出现资源加载死锁、数据错读或许可证 No-Go，立即关闭 flag。
- 公开发行前完成 AMSMB2/libsmb2 许可证门槛评审。

## 18. 最终验收定义

以下 Given/When/Then 条件同时满足，才算完成本需求：

1. Given 家长已一次性保存并验证光猫 SMB profile，且 Mac/Jellyfin 完全关闭；When Apple TV 在可访问 `192.168.1.1` 的家庭网络中冷启动 App；Then 无需 Mac 即可重新认证共享；缓存存在时先显示缓存首页，缓存被 tvOS 清理时则重新扫描生成首页。
2. Given `usb-0781-060116_1/sss73` 与冻结 manifest 内容一致；When traversal 与 compatibility validation 都完成；Then 首页最终可播放数量与 manifest 一致（当前基线 78），没有 `._`、隐藏文件或不兼容条目。
3. Given manifest 内任一被标为 `playable` 的文件；When 执行基本起播检查；Then 全部文件均能至少稳定播放 10 秒；代表性 10 个样本另通过 seek、循环、下一首和睡眠恢复。
4. Given 凭据已保存；When 退出并重启 App；Then 无需重新输入账号或密码，且 UI/日志/诊断摘要均不泄露凭据。
5. Given 正在播放或扫描；When 路由器重启、U 盘拔插或网络短暂中断；Then App 不崩溃、不混入其它 source 队列，恢复后能显式重连，文件变化时拒绝盲续读。
6. Given Mac 字幕服务离线；When 浏览和播放 SMB 内容；Then 媒体源仍保持 ready，已有字幕和普通歌词正常；服务重新上线后可继续字幕任务。
7. Given 已保存至少两个测试 profile；When 自动选择、固定模式和手动切换分别执行；Then 选择结果确定，固定模式不暗中回退，失败切换恢复旧首页。另一住宅在获得真实参数后追加现场验收，不阻塞当前单住宅版本。
8. Given SMB feature flag 被关闭；When App 重启；Then 在线的 `lastSuccessfulNonSMBProfileID` 可继续工作；没有可用非 SMB 源时明确显示功能停用而不伪造回退，SMB 配置与凭据未被删除，重新开启后可恢复原选择。

达到上述状态后，BabyPlayer 的日常媒体链路才算真正摆脱 Jellyfin/Mac 服务器依赖。
