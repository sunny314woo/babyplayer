# BabyPlayer Samba 后续优化接力说明

> 更新：2026-09-05
> 用户现场确认：Apple TV 显示光猫 U 盘媒体库，可从 BabyPlayer 首页正常起播。

## 当前可用基线

- 媒体链路：`Apple TV 192.168.1.20 → 光猫 192.168.1.1:445 → usb-0781-060116_1/sss73`。
- 媒体文件由 Apple TV 直接读取，不依赖 Mac/Jennifer/Jellyfin 开机。
- 目录含 78 个真实 MP4 和 78 个 `._*.mp4` AppleDouble 侧边文件；App 只显示 78 个真实视频。
- 实体 Apple TV 自动探针：`count=78 bytes=196608 playable=true playback_seconds=4.36`。
- Samba 已进入正常 BabyPlayer 首页，使用原有全屏 `SystemPlayerView`；退出播放回 Samba 首页，不回设置页。
- 家长设置中手工选中 Samba 或 Jennifer 后，最后选择持久为下次启动默认源。已有旧 SMB 成功配置而无 active-source key 的设备会一次性迁移到 Samba。
- 当前 Debug 包已安装到“客厅” Apple TV 并正常启动；正常 App 路径日志已确认 `BABYPLAYER_SMB_HOME_RESULT ready count=78`。
- Samba 卡片已恢复 Apple TV 本机的五帧抽取、质量评分和持久缓存；实体机日志已确认 `BABYPLAYER_SMB_COVER_RESULT ready=78 total=78`。
- 旧 Jellyfin 媒体 ID 下保存的普通/DeepSeek/双语字幕，可在同一 Apple TV 上按唯一文件名迁移到新的 Samba 媒体 ID；重名时拒绝猜测。

## 主要实现位置

- `BabyPlayer/SMBSpikeModels.swift`：当前光猫默认配置、媒体源选择持久化、文件过滤和 range 规则。
- `BabyPlayer/SMBSpikeClient.swift`：AMSMB2 只读会话、遍历、stat、range read、重连和凭据/配置保存。
- `BabyPlayer/SMBAssetResourceLoader.swift`：AVFoundation resource loader 与延迟 `SMBPlaybackResource`。
- `BabyPlayer/SMBSpikeView.swift`：`SMBHomeViewModel`、自动真机探针和保留的诊断页。
- `BabyPlayer/SpikeRootView.swift`：双轨根路由、Samba 正常首页、家长媒体源切换和返回路径。
- `BabyPlayer/SpikeViewModel.swift` / `BabyPlayer/SystemPlayerView.swift`：播放队列增加延迟 Samba asset，播放器按当前条目创建并保持 loader。
- `BabyPlayer/MediaCoverLoader.swift`：HTTP/本地/SMB 共用封面入口，五帧评分、本地缓存和串行去重预热。
- `BabyPlayer/LyricsRepository.swift`：Jellyfin → Samba 的本地字幕兼容迁移；DeepSeek 与中文翻译一并保留。
- `BabyPlayerTests/SMBSpikeTests.swift`：过滤、路径、range、默认源迁移和可选实时共享测试。

## 本轮已完成的后续修复

1. Samba 封面接入原五帧抽取与评分算法；封面写入 Apple TV 的 Application Support，不依赖 Jennifer。预热串行执行，并与播放使用不同 SMB 会话，避免封面读取阻塞起播。
2. 新增原子冷启动索引。索引只保存媒体元数据和来源摘要，不保存密码；连接刷新失败时仍可先显示缓存卡片。
3. 家长设置新增正式“编辑 Samba 连接”入口；儿童首页继续只显示内容。
4. 切换 Jellyfin/Samba 后，本机已生成字幕使用保守的唯一文件名迁移键恢复；已有 DeepSeek/双语结果优先于普通在线歌词，不再被后到的普通候选覆盖。
5. 两个 D3 reconciler 测试改为显式注入 mock analysis-service，不再依赖运行时配置，`notConfigured` 失败已消除。
6. 默认配置不再携带明文 Samba 密码；实体机继续从 Keychain 读取已保存凭据。

## 仍需继续验证/实现

1. 现有 Mac ASR 音频提取仍假设 HTTP/本地 URL；Samba 播放不受影响，但对 Samba 文件手工生成全新字幕需增加 SMB asset 提取或云端适配。
2. 目前是 Samba/Jennifer 两轨手工选择；多个 Samba 住宅 profile、可达性探测和自动切换尚未实现。
3. 需继续执行冷/热起播、seek、暂停/恢复、切歌、睡眠、断网、拔盘、文件替换和内存矩阵。
4. 公开发行前需完成 AMSMB2/libsmb2 许可证结论。
5. 字幕与共享状态迁移已有自动化及实体容器回归，但仍需用户在“客厅” Apple TV 切换一次两个来源，并打开此前已有双语字幕的影片，完成最终 UI/真实播放验收；若文件名已变化或 Apple TV 缓存曾被清除，迁移不会猜测命中。

## 测试状态

- `SMBSpikeTests`：新增冷启动索引、来源隔离、损坏/危险条目拒绝用例并通过；实时共享用例在未注入测试凭据时正确 skip。
- 注入一次性模拟器凭据时，实时光猫用例已通过：78 个视频、分段读取、AVAsset 可播放性和时长成功。
- 字幕跨源迁移、重名拒绝和两个 D3 reconciler fixture 用例均已通过。
- 2026-09-05 本轮全量 tvOS 模拟器测试通过；实体“客厅” Apple TV 已重新安装并验证 78 个媒体索引及 78/78 个本机封面。
- 只读导出实体机 App 私有字幕目录核验：旧数据仍含 62 份 DeepSeek 结果和 59 份中文翻译；本轮已生成 2 份 `smb:` 迁移记录，两份均保留 DeepSeek、中文翻译及一致的英文内容哈希。字幕数据迁移已通过真实容器验证，屏幕呈现仍请用户肉眼确认。

## 跨来源共享状态补充（2026-09-05）

- Jellyfin 和 Samba 的来源 ID 只用于定位/播放；评分、喜欢/不喜欢、屏蔽、续播、普通歌词绑定、DeepSeek/双语字幕、人工校时及智能片头片尾，统一按 Apple TV 本地 `contentID` 保存。
- 当前已知的同一套 78 个文件使用“目录内唯一文件名”兼容键；同一来源内重名时退回来源 ID，拒绝错误串数据。未来接入任意不同媒体库时，仍应按技术设计升级为完整文件 SHA-256 强身份。
- 升级不要求 Jennifer 在线：App 会从已有字幕/绑定恢复旧 Jellyfin ID 别名；Jellyfin 目录可用时再补全其余别名，并持久在 Apple TV。
- 全局定时、手工片头、手工片尾和字幕显示模式仍只有一份 UserDefaults；另修复了重启后“中文/中英双语”被错误重置成英文的问题。
- 实体机迁移结果：两个 78 项来源共 `aliases=156`；旧的 11 条来源级评分归并为 10 个内容偏好，`shared_ratings=10 legacy_ratings=0`。两条屏蔽仍对应 `12. I Am The Music Man`、`69. Trick Or Treat`；续播点已是共享 ID。`lyrics=英文 intro=0 outro=5 timer=30 source=samba` 原样保留。

## 智能跳过全局开关补充（2026-09-05）

- 原实现把开关保存在每个视频的分析 bundle 中，并且只有当前视频已有可信边界时才在“AI 功能”菜单显示，容易造成无法找到取消入口。
- 现改为 Apple TV 本机唯一的 `BabyPlayer.SmartSkipEnabledV1` 全局偏好，Jellyfin、Samba 和后续媒体源共用；默认开启，切源和重启后保持。
- 开关固定放在播放器“倍速”菜单顶部。“AI 功能”只负责生成/重跑片头片尾分析，不再承担是否采用结果的设置。
- 关闭只停止采用 AI 分析边界，不删除分析结果，也不影响 Jellyfin chapter marker 或家长设置中的固定片头/片尾秒数；重新开启即可恢复。若刚执行智能片头跳转，30 秒内关闭会立即回到禁用 AI 后应采用的位置；若正在执行智能片尾渐弱，则取消切歌并恢复音量。
- 全量 tvOS 26.5 模拟器测试通过。Debug 包已重新构建、签名、安装并启动到实体“客厅” Apple TV；启动日志确认 `BABYPLAYER_SMART_SKIP_SETTING enabled=true`、Samba 首页 `count=78`，且 Jennifer/Mac 不是播放依赖。菜单遥控器交互仍需用户现场肉眼确认一次。

## 后续工作方式

- 先读取 `SMB_DIRECT_MEDIA_SOURCE_TECHNICAL_DESIGN.md` 和 `SMB_DIRECT_MEDIA_SOURCE_PHASE_A_REPORT.md`，再核对实际代码；文档是现状/目标边界，不能代替验证。
- 保留当前工作树的所有未提交更改，不做破坏性重置。
- 用户反馈新细节 bug 时，先在实体 Apple TV 复现，再修复并按风险补测试。
- 每次真机部署使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/deploy-to-apple-tv.command --debug`。
