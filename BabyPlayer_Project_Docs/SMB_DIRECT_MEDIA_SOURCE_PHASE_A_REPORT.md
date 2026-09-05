# SMB 直连媒体源 Phase A 验证报告

> 日期：2026-09-05
> 目标设备：“客厅” Apple TV 4K（第三代），tvOS 26.6
> 当前共享：光猫 `192.168.1.1` 上的 `usb-0781-060116_1/sss73`

## 结论

BabyPlayer 已在实体 Apple TV 上直接登录光猫 Samba，扫描出 78 个真实 MP4，完成分段读取、AVFoundation 可播放性验证和真实起播。自动真机探针记录为：

```text
count=78 bytes=196608 playable=true playback_seconds=4.36
```

媒体文件链路为 `Apple TV → 192.168.1.1 Samba → U 盘`，不经过 Mac/Jennifer。Mac 只在后续主动生成新字幕时才可选使用。

Samba 已从隔离诊断页接入 BabyPlayer 正常首页：家长切到 Samba 后，选择会被持久为下次启动的默认媒体源；播放使用原 BabyPlayer 全屏系统播放器，退出时回到 Samba 首页，不再回到连接设置页或 Jennifer。

后续实体 Apple TV 功能测试还已确认：歌词/字幕、封面、进度/续播、喜欢/不喜欢/屏蔽、手工/智能片头片尾跳过已完成 Debug，当前可正常使用。

## 已通过

- 光猫 TCP 445 可从 `192.168.1.x` 局域网访问，共享和 `/sss73` 目录可读。
- 真实媒体数为 78；另有 78 个 `._*.mp4` AppleDouble 侧边文件，过滤后不会误计成 156。
- 首部、中部、尾部 byte-range 读取通过。
- SMB-backed `AVURLAsset` 可正确读取可播放性和时长。
- tvOS 模拟器实时集成用例在 0.521 秒内通过扫描、随机读取和 AVAsset 验证。
- SMB 逻辑回归测试通过；无凭据时实时网络用例按设计 skip。
- Debug tvOS 真机包构建、签名、AMSMB2 Embed & Sign、安装和启动通过。
- 媒体源会保存 `samba`/`jellyfin` 最后手工选择；已有旧 SMB 成功配置而未保存选择的设备，一次性迁移为 Samba 默认源。

## 网络拓扑变化

初始 U 盘插在中兴路由器 `192.168.5.1`，Apple TV 位于 `192.168.1.20`，因两网段无路由而连接超时。Mac 同时连两张网卡只能用于开发，不会自动替 Apple TV 转发 SMB。

后来将 U 盘移到 Apple TV 同网段的光猫，拓扑变为：

```text
Apple TV “客厅”   192.168.1.20
Mac Wi-Fi             192.168.1.14（只用于开发/部署）
光猫 Samba          192.168.1.1:445
共享/目录           usb-0781-060116_1/sss73
Apple TV → Samba       成功
```

## 真机发现并已修复的工程问题

1. AMSMB2 4.0.3 是动态 Swift Package product；工程已加入 Embed Frameworks + CodeSignOnCopy。
2. 部署脚本不再全局覆盖 `PRODUCT_BUNDLE_IDENTIFIER`，避免 App 与依赖 framework 重名。
3. App 保持 445 为配置约束，但默认端口交由 libsmb2 建立会话。
4. 重连只尝试一次并新建 manager；文件 stat 变化时拒绝继续读取。
5. 播放队列只保存轻量 Samba 引用，当前曲目起播时才创建 resource loader/AVAsset，避免为 78 个条目同时建立重资源对象。

## 剩余验收

当前结果证明实体 Apple TV 的功能链路已通，可继续产品集成。公开发行前仍需完成：

- 10 次冷起播 + 10 次热起播和 seek 性能统计。
- 取消、EOF、切歌、后台/前台、睡眠恢复、断网/拔盘和文件替换故障矩阵。
- resource loader 峰值内存与长时播放稳定性。
- AMSMB2/libsmb2 用于公开分发的许可证结论。

因此，不再存在“两网段无法连接”阻断；但不把一次 4.36 秒播放误报为全部发布验收已完成。

## 2026-09-05 后续回归

- Samba 首页已重新接入原有的本机五帧抽取、画面质量评分和 Application Support 封面缓存；“客厅” Apple TV 日志确认 `ready=78 total=78`。
- 冷启动媒体索引已落地：先显示本机缓存，再连接共享刷新；索引不包含密码并按 Samba 来源隔离。
- 家长设置已增加正式的 Samba 连接编辑入口。
- 切换来源后，旧 Jellyfin ID 下的普通、DeepSeek 和中文翻译结果会在文件名唯一匹配时迁移到 Samba ID；普通在线歌词不会再覆盖已落盘的 DeepSeek/双语结果。
- 两个原先因 `notConfigured` 失败的 D3 reconciler 测试已改用显式 mock 服务注入，连同新增字幕迁移和 SMB 索引用例通过。
- 新 Debug 包已部署到实体“客厅” Apple TV；扫描和全部封面已验证。只读容器核验还确认旧 62 份 DeepSeek、59 份中文翻译没有丢失，并已有 2 份真实 `smb:` 记录成功携带双语结果。屏幕字幕呈现仍需用户打开其中一部影片做最后肉眼确认。
- 后续已将评分、偏好、屏蔽、续播、歌词/双语字幕、人工校时和智能片头片尾统一到来源无关内容 ID。真机确认 Jellyfin/Samba 共 156 条来源别名，10 条现有内容偏好全部迁移，遗留来源评分为 0；两个屏蔽和续播状态均保留。
- 定时关闭、手工片头/片尾和字幕显示模式继续共用同一份全局设置；修复了中文/双语模式在重启后回退英文的问题。
