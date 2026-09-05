# BabyPlayer 当前开发状态

> 更新日期：2026-09-05
> 状态：当前 Debug 版已在实体 Apple TV 上完成家庭环境功能验证，可正常使用。
> 本文是后续开发和新对话接力的当前事实入口；早期 V1/Spike 文档中与本文冲突的范围和状态已被本文取代。

## 1. 当前产品基线

BabyPlayer 已从“只能连接 Jennifer/Jellyfin”扩展为可手工切换的双媒体源：

| 媒体源 | 日常播放链路 | 当前状态 |
|---|---|---|
| 局域网 Samba | Apple TV → 光猫/路由器 Samba → U 盘 | 实体 Apple TV 已验证，无需 Mac 开机 |
| Jennifer/Jellyfin | Apple TV → Jennifer 上的 Jellyfin HTTP API | 保留兼容，可从家长设置手工切回 |

家长最后手工选定的媒体源会持久化，下次启动继续使用该来源，不会自动回退到 Jennifer。两种来源都进入同一个 BabyPlayer 儿童首页和全屏系统播放器，不把 Samba 目录页当成另一个播放器。

## 2. Samba 支持和实测结果

当前家庭测试拓扑：

```text
“客厅” Apple TV 192.168.1.20
        ↓ SMB/TCP 445
光猫 Samba       192.168.1.1
        ↓
usb-0781-060116_1/sss73
```

已验证：

- Samba 账号登录、共享与目录扫描正常。
- 正确识别 78 个真实 MP4，忽略 78 个 `._*.mp4` AppleDouble 隐藏侧边文件，首页不会误显示为 156 个。
- 支持 SMB 分段读取和 AVFoundation 播放；自动真机探针结果为 `count=78 bytes=196608 playable=true playback_seconds=4.36`。
- Samba 内容在 BabyPlayer 正常首页展示，选中后使用原有全屏播放器，退出播放后回到当前 Samba 首页。
- Samba 媒体扫描和播放不经过 Mac/Jennifer；只要 Apple TV、局域网设备和 U 盘在线即可播放。

## 3. 已完成 Debug 的用户功能

以当前实体 Apple TV 功能测试为准，以下能力已完成 Debug，目前可正常使用：

- 歌词/字幕的展示、选择和已有结果复用。
- 封面显示、缓存与缺失时的占位回退。
- 未播完进度保存、首页置顶与继续播放。
- `喜欢` / `不喜欢` / `屏蔽` 的本地偏好、排序与解除屏蔽。
- 手工和智能片头/片尾跳过，包括安全边界和片尾渐弱切换。
- 媒体源切换、默认源持久化、首页播放与返回路径。

“功能测试可正常使用”不等于“已完成公开发布验收”。以下仍属于发布前工程质量工作，不应重新报告为当前用户功能未完成：

- 长时播放、多轮冷/热启动、seek 和峰值内存统计。
- 断网、拔盘、凭据失效、文件替换、后台/前台和睡眠恢复故障矩阵。
- AMSMB2/libsmb2 公开分发的许可证复核。

## 4. Mac 与云端服务边界

- 视频播放、媒体扫描、本地进度和偏好不依赖 Mac。
- 已有歌词/字幕和普通在线歌词可继续使用。
- 当前新的 ASR/DeepSeek 字幕生成仍是可选的 Mac 分析服务。Mac 离线时应只禁用新分析，不影响 Samba 播放和已有结果。
- 后续可将分析接口迁移为可选云端服务，但这不是当前播放链路的阻断项。

## 5. 文档优先级

后续对话按以下顺序获取事实：

1. 本文：当前已实现/已验证基线。
2. `SMB_FOLLOWUP_HANDOFF_2026-09-05.md`：当前实现位置、测试和后续优化入口。
3. `SMB_DIRECT_MEDIA_SOURCE_PHASE_A_REPORT.md`：Samba 真机验证证据。
4. `SMB_DIRECT_MEDIA_SOURCE_TECHNICAL_DESIGN.md`：目标架构和发布验收边界。
5. 早期 `PRODUCT.md` / `DESIGN_BRIEF.md` / `TASK.md`：产品起点和历史决策；其中“只支持 Jellyfin”、“不做进度/偏好”等表述不再代表当前实现。
