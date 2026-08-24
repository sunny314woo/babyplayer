# BabyPlayer 开发接力摘要

更新：2026-08-24
项目：`/Users/wufengyu/Projects/AppleTV-儿童播放器`

## 当前方向

- 播放和交互仍在物理 Apple TV“客厅”上验证。
- Mac 本地运行歌词服务，调用腾讯 ASR / DeepSeek，并保存过程文件。
- Apple TV 只提交一个很小的分析任务，不再转换或上传整首音频。
- Mac 使用 Jellyfin 返回的本机 `Path` 直接读取原视频、提取 M4A，再调用腾讯 ASR。
- Mac 把整首音频按 60 秒分片，相邻重叠 5 秒；各片顺序调用腾讯，Apple TV 仍只需人工点击一次。
- 测试不绑定 Jennifer，可对任意视频人工操作。
- VPS 暂不用于开发验证，但保留且不删除。
- Debug 真机包连 Mac；Release 默认仍连生产 VPS HTTPS。
- 播放器已用倍速菜单取代 App 内声音菜单，固定提供 `0.8× / 1× / 1.5× / 2× / 3×`，初始为 `1×`。

## 歌词交互规则

### 普通歌词

- 保留候选歌词、时间调整和“固定为默认歌词”。
- 固定后，单曲循环或重新打开不得跳回候选 1。
- ASR / DeepSeek 不放在普通歌词菜单中。

### 歌词分析菜单

1. `ASR 识别歌词`：人工运行；每次先询问 Mac 的 fingerprint/SHA-256/分析版本缓存，只有版本不命中才计费识别。
2. `DeepSeek 校准歌词`：必须先有 ASR；没有下载歌词时仍可用歌曲名 + ASR word timeline 整理，允许 `asr_only`。
3. `重新 ASR 识别`：强制重跑腾讯 ASR。
4. `重新 DeepSeek 校准`：只重跑 DeepSeek。
5. `采用腾讯 ASR 字幕` 和 `采用 DeepSeek 校准字幕`：两份结果独立显示行数、独立采用，菜单明示当前实际采用来源。

播放、搜索普通歌词、切换歌词、单曲循环和重新进入播放器，都不得自动触发 ASR 或 DeepSeek。

分析完成只保存结果，不自动替换当前歌词。

## 优先级和持久化

- 固定的普通歌词与 ASR / DeepSeek 结果可以共存。
- 点击“采用”后，分析歌词优先；普通歌词不删除，仍可切换回去。
- ASR 和 DeepSeek 结果并列保存，任一份都可反复采用；运行另一阶段不会自动切字幕。
- tvOS 禁止 App 写 Documents / Application Support；Apple TV 副本保存在私有 Caches，Mac SQLite 保留可重建的权威 ASR / DeepSeek 结果。
- 已保存歌词内容、ASR 音频证据和原视频内容 SHA-256。
- 恢复服务端缓存前，Mac 会先核对原视频 SHA-256；一致时直接复用，不调用腾讯；内容变化才重新识别。
- ASR 缓存版本同时包含基础分析版本、分片时间线版本和 `60/5` 分片形状；旧的整首 v1 结果不会遮住新结果。
- DeepSeek 缓存与有效 ASR 时间线版本绑定；Apple TV 的 ASR 证据哈希也包含完整 word timeline，新 ASR 会使旧 DeepSeek 映射过期。
- 卸载 App 会清除结果；媒体确认删除后的清理逻辑还需后续验证。

## 本地测试环境

- Apple TV Debug 地址：`http://192.168.3.33:8011/v1`
- 启动：`BabyPlayerASRServer/scripts/start-local-development.sh`
- 健康检查：`curl --fail http://127.0.0.1:8011/health`
- 本地数据库：`BabyPlayerASRServer/babyplayer-asr.local.sqlite3`
- 过程文件：`BabyPlayerASRServer/LyricsTestOutputs/`
- 本地任务接口：`POST /v1/local-analysis/jobs`，Apple TV 用 `GET /v1/local-analysis/jobs/{id}` 短轮询。
- 过程文件包括 Mac 提取的 `extracted_audio.m4a`、ASR JSON/SRT、候选歌词、DeepSeek 输入输出和 AI SRT。
- 只允许读取 `LOCAL_MEDIA_ROOTS` 白名单中的媒体；production 禁用本地路径接口。

## 遥控器

- 播放画面无菜单焦点时，中间键切换播放/暂停。
- 菜单或进度控件有焦点时，中间键仍是确认。
- 已在“客厅”真机确认播放/暂停正常。

## ASR 分片合并规则

- 词时间先加上分片的全局 offset。
- 相邻重叠区以重叠中点划分唯一所有区，只在不同分片、文字相同且原始时间真实重叠时去掉边界复制词。
- 不会因为歌词文字相同就全局去重；不同时间位置的重复副歌保留。
- 最终 words/segments 被整理为全局单调、不重叠时间线，DeepSeek 只接收这份合并结果。
- 真实 Provider 请求受 rolling-minute 限速器约束，每首内部顺序识别；分片任务失败前已成功返回的腾讯时长仍记入月度用量。

## 当前验证与下一步

- tvOS “客厅”真机测试：50 项通过，0 失败。
- Python 服务端：36 项通过，0 失败。
- Mac 服务健康，ASR 和 DeepSeek 已配置。
- `Rain Rain Go Away.mp4` 已验证：Mac 可直接提取 155 秒音频；旧 ASR 缓存补存视频哈希时腾讯用量增加 0 秒。
- `The Wheels On The Bus` 旧整首 ASR 只返回 3 个 segment/185 个 words，最后一词结束于 138.47 秒；旧 DeepSeek 结果为 35 行、置信度 0.90。
- 现有 157.184 秒过程音频已离线验证为 `0–60 / 55–115 / 110–157.184` 三片，未调用真实腾讯。
- 该歌新策略的月度内部计量为 `60 + 60 + ceil(47.184) = 168` 秒，相比单次 `ceil(157.184) = 158` 秒增加 10 秒（约 6.3%），共 3 次 Provider 请求。
- 腾讯把整分钟识别成一个 segment 时，Apple TV 会按词级时间拆成每行最多 6 词 / 30 字符 / 3.2 秒；没有 word timeline 时也会在 segment 时间内均匀分配，不再整段铺屏。
- 2026-08-24 实测“ASR 点了但没变”的直接原因是 Apple TV 发现本地旧 ASR 后直接返回，未询问 Mac 新版本缓存；该短路已取消。
- Baby Shark 没有普通歌词候选时的 DeepSeek 请求已打通；服务会先尝试受限网站证据，找不到则仅用歌曲名 + ASR 整理，不允许凭记忆补造 ASR 中完全缺失的演唱。
- 分析等待发生在独立异步任务中，不暂停播放器，也不改变单曲循环。
- 2026-08-24 22:53 已再次覆盖安装并启动最新 Debug App 到“客厅”。
- Mac `8011` 已运行分片代码。

下一步在 Apple TV 依次验证：

1. 确认播放菜单已无“声音”按钮，改为“倍速：1×”；依次切换 `0.8× / 1× / 1.5× / 2× / 3×`，验证暂停恢复、单曲循环和换集后仍保持档位。
2. 普通播放不得自动触发 ASR/DeepSeek。
3. 在 `The Wheels On The Bus` 点击一次普通“ASR 识别歌词”，不要点“重新 ASR”。由于分析版本已升级，这一次会真实产生 3 次腾讯请求/约 168 秒月度计量；当前实现阶段没有替用户执行。
4. 观察 Mac 任务文案进入分片 `1/3、2/3、3/3`；完成后先点“采用腾讯 ASR 字幕”，检查是否为短行滚动、前奏无字幕，以及是否覆盖 138.47 秒之后的副歌和尾段。
5. 确认 ASR 完整后再人工点击 DeepSeek；旧 35 行映射不再直接复用，完成后点“采用 DeepSeek 校准字幕”对比。
6. Baby Shark 先确认已有 ASR，即使普通歌词列表为空也可点 DeepSeek；分析后手动采用 DeepSeek 字幕并检查时间线。若现有 ASR 仍是旧版本，先用普通“ASR 识别歌词”让 Mac 做版本检查；只有新版本未命中时才会产生腾讯费用。

## 安全约束

- 不输出或提交 Token、腾讯密钥、DeepSeek Key、`.env`、私密 xcconfig、本地 SQLite 或过程文件。
- 不删除 VPS，不修改 VPS 上的支付、翻译和其他服务。
- 不修改全局 `xcode-select`；构建时临时指定 `DEVELOPER_DIR`。
- 当前工作树有未提交改动，不得重置或覆盖。

关键代码：`SystemPlayerView.swift`、`LyricsRepository.swift`、`BabyPlayerASR.swift`、`local_analysis.py`、`service.py`、`development_artifacts.py`。
