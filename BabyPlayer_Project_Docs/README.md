# BabyPlayer

面向幼儿家庭的 Apple TV 本地媒体播放器。

核心体验：

**打开 App → 看到内容 → 点击封面 → 播放**

> 当前状态：光猫 Samba 直连已通过实体 Apple TV 扫描和起播验证，并已接入 BabyPlayer 正常首页。歌词、封面、进度/续播、喜欢/屏蔽和片头片尾跳过已完成 Debug，当前测试可正常使用。

## 项目目标

BabyPlayer 不是通用文件播放器，也不是家庭媒体服务器。

它希望把儿童本地视频从“文件”变成孩子能够理解和选择的“内容”。

## Documents

- `DEVELOPMENT_STATUS_2026-09-05.md`：当前已实现、已验证功能和发布前剩余工作（新对话优先读取）
- `PRODUCT.md`：产品定位、V1 范围、产品原则与待确认问题
- `TASK.md`：当前阶段、当前任务与 Backlog
- `CLAUDE.md`：Claude Code 在本项目中的工作规则
- `SMB_DIRECT_MEDIA_SOURCE_TECHNICAL_DESIGN.md`：Apple TV 直连路由器 U 盘、双住宅媒体源切换和可选字幕服务的详细技术设计
- `SMB_DIRECT_MEDIA_SOURCE_PHASE_A_REPORT.md`：2026-09-05 模拟器、光猫共享与“客厅” Apple TV 真机验证记录
- `SMB_FOLLOWUP_HANDOFF_2026-09-05.md`：下一个优化任务所需的当前基线、已知限制、测试状态和真机信息

## Development Status

**SMB 直连 — 真机功能链路已通**

SMB 只读扫描、AppleDouble 过滤、byte-range 读取、AVAsset resource loader、凭据保存、媒体源持久选择、冷启动索引和正式连接编辑入口均已实现。“客厅” Apple TV 已直连 `192.168.1.1` 光猫的 `usb-0781-060116_1/sss73`，正确得到 78 个 MP4 并真实起播；78 个视频的五帧评分封面也已在 Apple TV 本机生成/缓存。Jellyfin/Samba 切换时，评分、偏好、屏蔽、续播、歌词/双语字幕、人工校时和智能片头片尾共用来源无关内容 ID；全局定时与手工跳过设置也只有一份。Jennifer/Jellyfin 仍可手工切回，但不参与 Samba 播放或封面生成。

**核心交互——当前 Debug 测试可用**

歌词/字幕、封面、未播完进度与续播、喜欢/不喜欢/屏蔽、手工与智能片头片尾跳过已完成本轮 Debug。公开发布前的长时稳定性、异常网络矩阵和依赖许可证复核仍单独保留。
