# BabyPlayer Samba 后续优化接力说明

> 更新：2026-09-05  
> 用户现场确认：Apple TV 显示光猫 U 盘媒体库，可从 BabyPlayer 首页正常起播。歌词、封面、进度/续播、喜欢/屏蔽和跳过已完成 Debug，当前测试可正常使用。
> 统一现状见 `DEVELOPMENT_STATUS_2026-09-05.md`。

## 当前可用基线

- 媒体链路：`Apple TV 192.168.1.20 → 光猫 192.168.1.1:445 → usb-0781-060116_1/sss73`。
- 媒体文件由 Apple TV 直接读取，不依赖 Mac/Jennifer/Jellyfin 开机。
- 目录含 78 个真实 MP4 和 78 个 `._*.mp4` AppleDouble 侧边文件；App 只显示 78 个真实视频。
- 实体 Apple TV 自动探针：`count=78 bytes=196608 playable=true playback_seconds=4.36`。
- Samba 已进入正常 BabyPlayer 首页，使用原有全屏 `SystemPlayerView`；退出播放回 Samba 首页，不回设置页。
- 家长设置中手工选中 Samba 或 Jennifer 后，最后选择持久为下次启动默认源。已有旧 SMB 成功配置而无 active-source key 的设备会一次性迁移到 Samba。
- 当前 Debug 包已安装到“客厅” Apple TV 并正常启动；正常 App 路径日志已确认 `BABYPLAYER_SMB_HOME_RESULT ready count=78`。
- 歌词/字幕、封面显示与回退、本地进度/续播、喜欢/不喜欢/屏蔽、手工/智能片头片尾跳过已完成 Debug 功能验证。

## 主要实现位置

- `BabyPlayer/SMBSpikeModels.swift`：当前光猫默认配置、媒体源选择持久化、文件过滤和 range 规则。
- `BabyPlayer/SMBSpikeClient.swift`：AMSMB2 只读会话、遍历、stat、range read、重连和凭据/配置保存。
- `BabyPlayer/SMBAssetResourceLoader.swift`：AVFoundation resource loader 与延迟 `SMBPlaybackResource`。
- `BabyPlayer/SMBSpikeView.swift`：`SMBHomeViewModel`、自动真机探针和保留的诊断页。
- `BabyPlayer/SpikeRootView.swift`：双轨根路由、Samba 正常首页、家长媒体源切换和返回路径。
- `BabyPlayer/SpikeViewModel.swift` / `BabyPlayer/SystemPlayerView.swift`：播放队列增加延迟 Samba asset，播放器按当前条目创建并保持 loader。
- `BabyPlayerTests/SMBSpikeTests.swift`：过滤、路径、range、默认源迁移和可选实时共享测试。

## 已知限制和建议优先级

1. 封面展示、缓存与缺失占位回退已完成 Debug，当前不阻断使用。如需对每个 Samba 文件强制生成真实视频抽帧图，可作为后续视觉质量优化，不应再标记为当前功能 bug。
2. 连接成功后每次冷启动仍遍历共享；尚未实现原子本地索引、首页缓存先显示和增量刷新。
3. 家长媒体源页可切换源，但缺少一个正式的“编辑 Samba 连接”入口；原诊断页代码仍在，不应再当作儿童播放入口。
4. 现有 Mac ASR 音频提取仍假设 HTTP/本地 URL；Samba 播放不受影响，但对 Samba 文件手工生成新字幕需增加 SMB asset 提取或云端适配。
5. 目前是 Samba/Jennifer 两轨手工选择；多个 Samba 住宅 profile、可达性探测和自动切换尚未实现。
6. 需继续执行冷/热起播、seek、暂停/恢复、切歌、睡眠、断网、拔盘、文件替换和内存矩阵。
7. 公开发行前需完成 AMSMB2/libsmb2 许可证结论。

## 测试状态

- 用户已在实体 Apple TV 完成本轮功能验收；当前版本可正常使用。

- `SMBSpikeTests`：7 个纯逻辑/持久化用例通过，1 个实时共享用例在未注入测试凭据时正确 skip。
- 注入一次性模拟器凭据时，实时光猫用例已通过：78 个视频、分段读取、AVAsset 可播放性和时长成功。
- 全量 `LyricsAndASRTests` 曾有两个旧 D3 reconciler 用例因测试环境 `notConfigured` 失败：
  - `testD3ReconcilerAllowsASROnlyRequestWithoutDownloadedLyrics`
  - `testD3ReconcilerPostsCandidatesAndDecodesServerTimedLyrics`
- 上述记录属于测试 fixture/独立 analysis-service 配置问题，不代表用户已验收的歌词功能不可用，也没有证据表明它与 Samba 播放回归相关。后续仍应补齐该测试配置并重跑。

## 后续工作方式

- 先读取 `SMB_DIRECT_MEDIA_SOURCE_TECHNICAL_DESIGN.md` 和 `SMB_DIRECT_MEDIA_SOURCE_PHASE_A_REPORT.md`，再核对实际代码；文档是现状/目标边界，不能代替验证。
- 保留当前工作树的所有未提交更改，不做破坏性重置。
- 用户反馈新细节 bug 时，先在实体 Apple TV 复现，再修复并按风险补测试。
- 每次真机部署使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/deploy-to-apple-tv.command --debug`。
