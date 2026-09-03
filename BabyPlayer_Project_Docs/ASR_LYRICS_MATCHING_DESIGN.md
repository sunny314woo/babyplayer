# BabyPlayer 声音识别与歌词匹配当前设计

更新时间：2026-08-25
状态：描述当前已经实现的个人内测版本，不是未来设想

完整质量审查、实测数据、竞品/开源项目分析与改进路线见
[《智能歌词与自动字幕现状审查》](SMART_LYRICS_AUTO_SUBTITLE_AUDIT_2026-08-24.md)。

## 一、系统目标和边界

BabyPlayer 为 Jellyfin 中的固定儿歌视频提供三类可以共存的歌词：

1. LRCLIB 或内置已授权曲目提供的普通歌词；
2. 腾讯 ASR 返回的原始词时间线，经 Apple TV 可读性分行后形成的 ASR 字幕；
3. DeepSeek 使用 ASR word ranges 和普通歌词证据重建的校准字幕。

当前只服务个人 Apple TV，不实现用户注册、订阅、支付、家庭共享或多租户。腾讯和 DeepSeek
密钥只在服务端；Apple TV 只持有独立 BabyPlayer Bearer Token。

当前不是实时字幕，也不是普通播放时的后台自动分析。家长点击一次 `ASR 识别歌词`
后，系统会自动完成 ASR → DeepSeek → 启用 DeepSeek 字幕。普通播放、歌词搜索、单曲循环和
重新进入播放器仍不会自动调用云服务。

## 二、用户操作契约

### 普通歌词

- 字幕默认开启为英文；一次升级迁移后，仍尊重用户后续手工关闭。
- 搜索最多 3 份同步歌词候选，可额外使用 1 份内置纯文本歌词。
- 家长可以固定普通歌词、提前/延后校时或把第一句对齐到当前位置。
- 已固定的普通歌词不会在普通播放时被覆盖；家长明确发起 ASR 链即表示同意在成功后替换。

### 歌词分析

1. `ASR 识别歌词`：读取缓存或运行腾讯 ASR，成功后自动续跑 DeepSeek，再自动启用 DeepSeek 结果。
2. `重新 ASR 识别`：强制重跑腾讯 ASR 与后续 DeepSeek，可能重新计费。
3. `DeepSeek 校准歌词`：必须已经有 ASR；可单独重跑，成功后自动启用。
4. `重新 DeepSeek 校准`：忽略服务端 AI 缓存重新运行，成功后自动启用。
5. `采用腾讯 ASR 字幕` / `采用 DeepSeek 校准字幕`：保留手工切换和 A/B 入口。

ASR、DeepSeek 和普通歌词都可继续保留。DeepSeek 失败不会替换当前字幕；分析期间的更新手工选择
优先于自动启用。有效 DeepSeek 结果在新进入播放页时默认优先；当前会话仍可手工切换。
播放画面角落显示处理阶段，采用成功结果卡在 5 秒后自动隐藏。

### 播放控件焦点

- 2026-08-25 撤回“在顶排再按上键收起”的自定义拦截。实测中该拦截会在进度条显示时提前吞掉上键，导致无法到达歌词和 AI 按钮。
- 现在所有方向键均交给 `AVPlayerViewController` 的原生焦点系统；Back/Menu 仍按产品约定退出播放。
- 若未来重做“只收起控件不退出”，必须基于可验证的 AVKit 焦点状态，不再使用全局上键拦截。

## 三、两条执行路径

### 3.1 Debug / Release + Mac HTTP 本地分析

Swift 从当前 Jellyfin 地址复用主机并固定使用 `8011/v1`；Debug 与 Release 都启用 Mac 本地任务：

```text
Apple TV
  └── POST /v1/local-analysis/jobs
        media_path + fingerprint + title + song window
                 │
                 ▼
Mac 本地服务
  ├── 校验 media_path 位于 LOCAL_MEDIA_ROOTS
  ├── 计算完整原视频 SHA-256
  ├── FFmpeg 一次精确 seek，解码歌曲范围为 44.1 kHz PCM/WAV
  ├── Audio Separator + Kim Vocal 2 生成 vocals stem
  ├── Silero VAD 在 vocals stem 上生成人声证据；整首无人声则停止
  ├── 从无损人声轨独立编码 60 秒分片、相邻重叠 5 秒
  ├── 顺序调用腾讯 Flash ASR
  ├── 合并为全局 words/segments，添加词级 VAD/幻觉标记
  └── SQLite 缓存 ASR + 音频预处理摘要并返回
```

Apple TV 只轮询 job，不上传音频。当前 UI 把所有 recognizing 状态显示为 1/1；Mac 内部虽然知道
分片 1/3、2/3、3/3，但没有把该序号展示到电视。

### 3.2 已停用：Release + VPS HTTPS 上传

以下是旧实现，仅作历史记录。当前安装包不配置 VPS Base URL，也不会执行这条上传路径：

```text
Apple TV
  ├── 尝试从 Jellyfin 媒体临时导出整首 M4A
  ├── 远程 MP4 无法直接导出时，可能临时下载完整源视频
  ├── POST /v1/analyze 上传整首 M4A
  └── 成功或失败后删除临时音频
                 │
                 ▼
VPS
  └── 单次调用腾讯并缓存结果
```

当前正式路径只验收 3.1 的 Mac `8011/v1`；不得在连接失败时静默回退到此旧路径。

## 四、ASR 处理

### 4.1 腾讯请求

当前使用腾讯录音文件识别极速版：

- `engine_type=16k_en`；
- `word_info=1`，要求词级时间戳；
- `first_channel_only=1`；
- 不过滤标点、语气词或脏词；
- 每个分片顺序调用，受服务端 rolling-minute 限速器保护。

腾讯返回模型仍只提供当前链路可用的文本和时间，没有可信的腾讯词置信度或 no-speech probability。
但服务器现会为每个 ASR word 附加 vocals-stem `voice_activity_score`、
`voice_activity_coverage` 和 `quality_flags`，并保存人声分离模型/版本、人声覆盖和平均概率。

### 4.2 60/5 分片合并

- 每个词先加分片全局 offset。
- 相邻分片重叠区域以重叠中点划分唯一所有者。
- 只在不同分片、标准化文字相同且原始时间范围真实重叠时删除边界重复词。
- 不会因为副歌文字重复就全局去重。
- 输出整理为全局单调、不重叠的 segments/words。

服务端现在只对原视频做一次 PCM/WAV 解码。VAD、整首过程 M4A 和各腾讯分片都从同一条
无损人声轨生成，不再存在“AAC 转 AAC”二次有损编码。

### 4.3 Apple TV ASR 分行

腾讯可能把整分钟放在一个 segment。Apple TV 使用词时间线重新分行：

- 最多 6 个词；
- 最多 30 个字符；
- 最长 3.2 秒；
- 词间停顿达到 0.65 秒时换行；
- 强标点后换行。

没有 word timeline 时，会把 segment 文本按时间均匀分配。这只能避免长文本铺满屏幕，不代表合成
词时间准确。

## 五、DeepSeek D3 处理

### 5.1 输入

Apple TV 只上传：

- media fingerprint；
- song title；
- 最多 3 份普通歌词候选。

ASR/AI candidate 因为带有 `identityAnchor`，会被 Swift 明确过滤。服务器从 SQLite 自己读取对应
ASR transcript 和 indexed words。因此 DeepSeek 字幕不是把 Apple TV ASR 行直接转换一遍。

### 5.2 两阶段模型调用

1. 第一阶段比较候选与 ASR，返回候选分数和是否需要 Web 搜索。
2. 第二阶段使用 ASR、普通候选和可选限域 Web 证据，返回最终行文字与连续 ASR word range。

模型不返回时间戳。服务器用每行首词和末词的时间机械生成开始/结束。

### 5.3 当前服务器校验和恢复

服务器已经校验：

- 2–300 行；
- 每行文字非空；
- ASR 索引为整数且不越界；模型乱序行按 ASR 开始索引排序；
- 每行少于 100 个 ASR 词；
- source 和 source line ID 合法；
- 最终文字至少得到 ASR 或候选的最低 token support。
- Web 候选使用稳定合成 `candidate_id:retrieved_text`，模型不稳定行名只能归一化到当次真实 Web 证据。
- 重叠模型行和无文字证据行被舍弃，不会让整首返回 422。
- 所有未覆盖、非伴奏幻觉的 ASR 词会确定性补成 ASR-only 行；模型不能再默默删除副歌。
- 响应返回 `asr_word_coverage` 和 `recovered_asr_word_count`。

服务器当前没有校验：

- 第一/最后人声覆盖；
- 最大无字幕空洞；
- verse/chorus 重复次数；
- 纯音乐区是否有人声；
- Apple TV 可读性分行；
- 模型自报 `song_match_confidence` 是否与客观指标一致。

Swift 只检查 `song_match_confidence` 位于 0 到 1，没有最低接受阈值。

## 六、缓存与证据版本

### ASR 缓存

ASR 表按 subject、media fingerprint 和 analysis version 保存，同时记录音频 SHA-256、原视频
SHA-256、转写和 segments。当前 Mac 分片版本包含基础版本、timeline version 和 60/5 形状，避免
旧整首算法遮住新算法。

### DeepSeek 缓存

AI Lyrics 表当前按 subject、media fingerprint 和以下字符串保存：

```text
reconciliation_version|asr:analysis_version|evidence:sha256(actual_asr_words+vad+candidates)
```

证据哈希包含实际 word 文本/时间、人声活动分数/标记和当次候选内容。强制重跑
ASR、VAD 增量标注或更换候选都会得到新缓存键。2026-08-24 审查发现的 P0 已修复。

## 七、存储与恢复

Apple TV 的歌词候选、绑定和分析副本实际保存在 App 私有 `Caches`，不是 Application Support，也
不是永久音频库。tvOS 在空间不足且 App 未运行时可以清除缓存；卸载 App 会删除整个容器。

Mac/VPS SQLite 保留 ASR/DeepSeek 的服务端副本。当 Apple TV 本地绑定因换歌、退出播放页或
tvOS 清理 Caches 而缺失时，客户端会通过只读 `/v1/lyrics/cache` 按媒体指纹拉回已有 DeepSeek
结果。该路径不触发 ASR、网络歌词搜索或 DeepSeek，恢复后默认优先播放 DeepSeek 字幕。
家长的纯本地校时偏移仍只存在 Apple TV。

Release 只使用临时 M4A，完成后删除。Debug 开发过程目录可以显式保存完整提取音频和 JSON/SRT，
该目录已被 Git 忽略，但需要限制访问和定期清理。

## 八、额度、安全和隐私

- 服务端按北京时间自然月硬限制 18,000 秒。
- 新请求先原子预留；腾讯成功后结算，失败释放或结算已实际完成的分片。
- 缓存命中不调用腾讯。
- 腾讯控制台后付费应继续关闭。
- `/v1/*` 使用独立 Bearer Token；`/health` 不返回密钥。
- Mac 本地 Path 接口在 `PRODUCT_ENV == production` 时返回 404，并且只读取白名单目录。
- 生产必须精确设置 `PRODUCT_ENV=production`，避免环境名误拼导致本地接口开放。
- `.env`、私密 xcconfig、本地 SQLite、过程音频和测试输出都不得提交 Git。
- 当前共享 Token 只适合个人部署；公开分发必须升级为逐设备配对 Token。

## 九、当前验收状态

- Python 服务端自动化测试：55 项通过。
- tvOS 模拟器自动化测试：60 项通过。
- Baby Shark：417 个 ASR 词，首词 12.55 秒；DeepSeek 92 行，ASR 词覆盖 100%。
- The Wheels On The Bus：191 个 ASR 词；用户确认开头旋律/汽车声/节奏无人声，最终首句从 22.45 秒开始。
  DeepSeek 32 行，ASR 词覆盖 99.45%，`BB/DD/Dee/E` 未进入最终字幕。
- Who Took the Cookie?：175 个 ASR 词，0.50–120.35 秒；Web 证据 ID 修复后 DeepSeek 31 行成功。
- I Am The Music Man（第 12 首）：混合对话和歌曲的 577.99 秒 ASR 结果已完成；
  无普通歌词候选时 DeepSeek 以 `asr_only` 整理为 47 行，时间范围 3.63–566.39 秒。

自动化测试证明接口、缓存和 UI 状态机能运行，不证明歌声识别质量已经通过。后续验收必须使用人工
标注的歌曲集，分别统计纯音乐误报、歌词覆盖、重复副歌、尾段覆盖和时间误差。

## 十、下一步

按以下顺序执行，不先继续堆叠提示词：

1. 建立 10–20 首人工标注回归集和质量指标；当前三首只是起始样本。
2. 已完成：DeepSeek 缓存绑定实际 ASR/VAD/候选证据，客户端 evidence hash 也包含质量标记。
3. 统一 ASR SRT、电视 ASR 和 DeepSeek 的 canonical cue/分行结构。
4. 已完成有声 ASR 空洞回收；继续增加尾段人声和重复段落的真值门槛。
5. 已完成 PCM/WAV、vocals stem 和 stem VAD 主链路；继续以 faster-whisper/WhisperX 作为第二 ASR/强制对齐 A/B。
6. 可信歌词优先使用歌声强制对齐；DeepSeek 退回到文字校正和翻译角色。
7. 英文字幕通过质量门槛后再生成共用 cue ID 的双语字幕。
