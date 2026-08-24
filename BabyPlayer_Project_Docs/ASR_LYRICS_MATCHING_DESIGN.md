# BabyPlayer 声音识别与歌词匹配详细设计

更新时间：2026-08-23

## 当前开发状态（个人内测）

当前版本只服务这台个人 Apple TV 和这台个人 VPS，目标是先完成最小可用闭环：

- Apple TV 从 Jellyfin MP4 提取并永久保留本地 M4A；
- 独立域名 `player.wisteriasoftware.uk` 下的 VPS 负责腾讯 ASR、缓存、额度和
  Version D3 Lyrics Evidence Reconciler；
- 歌词搜索、候选比较、绑定、时间偏移和持久化都在 Apple TV 本地完成；
- 当前不实现用户注册、登录、订阅、支付、家庭共享或多租户隔离；
- 服务器仍保留独立 Bearer Token 边界，未来公开分发时可替换为逐设备配对 Token，
  不需要重写 ASR/歌词模块。

腾讯云 SecretId/SecretKey、DeepSeek API Key 只放 VPS；Apple TV 只需要调用
`/v1` 接口的独立 BabyPlayer Bearer Token。当前服务健康检查已确认两个云端提供方
均已配置，未把任何云端 Secret 放入工程或提交到 Git。

## 结论

声音识别采用“Apple TV 本地分析 + 独立 VPS 腾讯 ASR 代理”。Jellyfin 只提供 MP4
媒体流，不运行分析，不安装插件；EnglishFlow Account Server、翻译与 TTS 不参与。

```text
Jellyfin MP4
    │ 局域网播放地址
    ▼
Apple TV / AVFoundation
    ├── 导出完整歌曲段为 M4A（AAC）
    ├── 持久保存到本地歌曲音频库
    ├── 较长曲目另导出最长 120 秒 ASR 前段
    └── 先查本地转写/绑定缓存
              │ 未命中
              ▼
BabyPlayer 独立 VPS（8011）
    ├── 独立 Bearer Token
    ├── 5 小时/月硬上限
    ├── ASR 模块：转写结果缓存
    ├── 歌词修复模块：只处理 AI v1 的结构化逐行 repair
    └── 临时上传关闭即删除
              │
              ▼
腾讯录音文件识别极速版（16k_en）
    └── 文字 + 句/词时间戳
              │
              ▼
Apple TV
    ├── T0：立即显示第 1 份普通歌词
    ├── T1：同歌置信度 + 全局单调 alignment 生成 AI 校时歌词 v1
    ├── T2：VPS 读取 ASR 缓存，DeepSeek 审查最多 3 份候选
    ├── 候选都弱时由 VPS 限域检索，新结果仍须与 ASR 比较
    ├── DeepSeek 返回 ASR word ranges，服务器换算/验证时间
    └── 手动选择永远优先且不会被自动结果覆盖
```

## Apple TV 的职责

1. 使用 `AVAssetExportSession` 和 `AVAssetExportPresetAppleM4A` 从 MP4 导出 M4A。
2. 优先使用 Jellyfin 章节；否则从家长设置的统一片头时间开始。
3. 完整歌曲段存在 Application Support 下，不设自动淘汰上限，仅家长可删除。
4. 单次 ASR 最长使用前 120 秒；较长曲目另保留识别前段，不截断完整本地音频。
5. 把 M4A、媒体指纹、大小、提取时间、识别状态写入本地音频库清单。
6. 本地集中计算 normalized text、ordered phrase、标题、coverage 和时间顺序证据；通过后用全局单调 alignment 立即生成 AI v1，再把 v1 原始行和对齐证据临时发给歌词 repair 模块。
7. 家长的手动绑定与多次校时拥有最高优先级。

Apple TV 原生导出 M4A，不额外引入 MP3 编码器。腾讯极速版支持 M4A/AAC，因此没有
必要为了 MP3 增加复杂度。

## 家长设置：歌曲音频缓存

列表每行显示：曲目名、大小、导出日期、音频时长、识别状态、当前绑定。提供：

- 重新分析；
- 删除单首缓存；
- 删除全部缓存；
- 查看总占用和本月 ASR 剩余时间。

本地音频库不设自动容量淘汰。它是后续“纯音频 + 同步歌词”的源资产，只有家长在
设置中删除单曲或清空时才移除。删除 M4A 不删除最终歌词绑定或 VPS 的 ASR 转写缓存。

## 渐进式 AI Lyrics 生成

页面先稳定绑定第 1 份普通歌词。腾讯 ASR 只提供句/词时间戳和噪声 transcript。本地的 `sameSongConfidence` 使用五类命名证据和集中阈值，不要求 ASR 逐字匹配。证据足够时，动态规划在整首歌上完成全局单调对齐，保留原歌词文本并产生 AI v1。

DeepSeek V4 Flash 使用两阶段非思考 JSON contract：先评估现有候选并返回 `need_web_search`，再根据 ASR、原候选和可选检索证据返回最终文本及 `asr_word_start_index/asr_word_end_index`。服务端校验范围单调、不重叠、不越界且文本受 ASR/候选支持，再机械生成时间。原 `/v1/refine` 只作兼容回退。

本地确定性同歌证据包括：

- normalized text similarity；
- ordered token/phrase similarity；
- 标题/文件名 similarity；
- ASR 对原歌词的 coverage；
- sentence/word timestamps 的顺序合理性。

声音分析未完成前稳定显示第 1 个候选。用户点击任一候选时，内存 manual lock 和 generation 在任何 `await repository` 之前同步生效；后续 ASR/alignment/DeepSeek 可更新 AI candidate，但不再自动覆盖。

每份歌词分别保存 `autoOffset + manualAdjustment = effectiveOffset`。提前/延后操作只累加
`manualAdjustment`，自动重校时不覆盖人工调整。

## 生成时机与月底策略

默认在当前曲目播放缓冲稳定后异步生成，完成前使用第 1 份网络歌词，不阻塞视频。
最终结果和完整 M4A 都在 Apple TV 保留，下次直接使用。

月底预生成应是家长明确开启的机会任务，而不是保证在最后一天零点执行的定时任务。
tvOS 后台处理由系统择机调度且可中断。策略应为：只在当月最后一天、播放器空闲、网络合适、
剩余额度高于保留值时串行处理未生成曲目；每首仍先查服务端缓存，收到系统取消后立即停止。
本策略不应默认打开，以免在家长不知情时消耗额度。

## 额度与错误

- 服务端按北京时间自然月保存 `used_seconds + reserved_seconds`。
- 硬上限固定为 `18,000` 秒，即 5 小时。
- 请求开始前原子预留时长；并发请求也不能穿透上限。
- 只有腾讯成功返回后才把预留转为已用；失败会释放预留。
- 缓存命中不调用腾讯、不消耗额度。
- 达到上限返回 HTTP 429、`MONTHLY_ASR_LIMIT_REACHED` 和下月 1 日 00:00
  （Asia/Shanghai）的 `next_available_at`。
- Apple TV 显示：“本月声音分析额度已用完，可于 9 月 1 日 00:00 再次使用”。

腾讯控制台关闭后付费仍必须保持；这是云端第二道硬保护。

## 隐私与解耦

- VPS 不持久化 M4A，不保存 Jellyfin URL 或访问令牌。网页候选只存在当次请求内存；验证后的最终 AI Lyrics 按不可逆媒体指纹和 reconciliation version 写入 SQLite 缓存。
- multipart 临时文件在请求 `finally` 中关闭，由系统删除；systemd 同时启用
  `PrivateTmp=true`。
- 数据库只保存音频 SHA-256、不可逆媒体指纹、腾讯转写文字、时间戳和用量；
  Apple TV 仍持久化最终绑定，VPS 缓存可避免重复 DeepSeek/检索请求。
- BabyPlayer 使用独立域名、目录、Linux 用户、systemd、SQLite 和 Bearer Token。
- 腾讯 AppID/SecretId/SecretKey 和 DeepSeek API Key 只存在 `/opt/babyplayer-asr/.env`。
- EnglishFlow 的数据库、鉴权、TTS、翻译和部署脚本不做任何修改。

当前独立 Bearer Token 适合这台个人 Apple TV 的私有部署；如果未来公开分发 App，应升级
为一次性配对码签发的逐设备 Token，不能把一个共享 Token 放进公开安装包。
