# BabyPlayer Phase 2：目录导航与历史内容数据

更新时间：2026-09-27

## 本阶段范围

- Jellyfin 和 Samba 仍是两个独立媒体库。各自的客户端按父目录读取直接子文件夹和视频，儿童首页共用 `BabyPlayerFolderSection` 展示文件夹与逐级返回。
- Jellyfin 的 Root Folder 当前默认为“音乐视频”库并保存其 ID；Samba 沿用已有 `rootPath`。Root Folder 更换入口属于后续家长设置阶段。
- 两个来源各自保存上次访问路径。启动时逐级读取服务器实际返回的子目录，失效路径只能回到有效的上层或根目录。
- “顺序播放此文件夹”和“随机播放此文件夹”在点击时递归收集所有子目录视频，再交给已有播放队列；目录浏览没有产品层深度上限。旧 Samba 平面扫描的 `maximumDepth=5` 只影响旧缓存/封面预热，不决定哪些目录可以浏览或播放。
- Samba 原平面索引格式未迁移：冷启动可从缓存视频重建已有文件夹入口。缓存不证明来源在线，后续 Phase 3 才建立在线状态判定。

## 历史数据与新内容边界

原版本为了个人使用，会根据唯一文件名把 Jennifer/Jellyfin 与 Samba 约 70 条内容映射到 `filename-sha256:` ID。这个 ID 已用于评分、屏蔽、续播、封面和字幕/ASR 结果。本阶段不删除这些映射，也不改写已保存的数据：本机已有的 `BabyPlayer.ContentAliasesV1` 及歌词库中已持久化的旧别名继续可读。旧内容因此仍能看到之前的结果。

从本阶段开始，新视频没有历史别名时使用 `source-v1:jellyfin:<Jellyfin ID>` 或 `source-v1:smb:<SMB path>`。两种来源不再通过文件名生成共同 ID。来源专属 ID 同时传给现有歌词/ASR 描述符，阻止新内容在读取历史结果时仅按相同标题关联到另一来源；歌词、ASR 和 DeepSeek 的生成流程未改动。旧兼容映射函数仍保留用于历史迁移测试，不参与新内容登记。

这是一条向前适用的边界：历史上已共享的记录继续共享，新内容按来源独立保存。不要清空 Keychain、`BabyPlayer.ContentAliasesV1`、本机歌词库或封面缓存来“迁移”旧记录。

## 仍待后续阶段处理

- Phase 3：三来源配置/在线状态、优先级与启动选择。缓存列表不能用于在线判定。
- Phase 4：家长更换 Jellyfin Root Folder、三来源配置入口和优先级 UI。
- Phase 5–7：百度授权、目录与独立播放 Spike。Spike 成功前不接入正式播放链。
- Jennifer 笔记本上的 AI 服务目前仍按原局域网地址连接。Samba 播放不依赖 Jennifer；新字幕分析是否可用取决于该服务本身可达。本阶段未修改该链路，未来可评估迁至常驻服务器。

## 测试与环境

`BabyPlayerTests/SMBSpikeTests.swift` 覆盖来源身份、根目录边界、缓存目录、路径恢复、Jellyfin 三层目录和递归视频收集。真实 Samba 测试只在测试 App 容器预先注入 `BabyPlayer.Tests.LiveSMBPassword` 后运行；Apple TV App 的 Keychain 凭证不能直接被模拟器测试读取。用户已确认实体 Apple TV 的 Samba 连接可用，无需向开发过程提供密码。
