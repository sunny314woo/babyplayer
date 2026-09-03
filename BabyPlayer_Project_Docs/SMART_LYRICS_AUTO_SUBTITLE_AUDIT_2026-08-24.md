# 智能歌词与自动字幕现状审查

更新时间：2026-08-25（已同步人声分离、完整性保护和三首真歌实测）

审查范围：Apple TV 歌词展示、腾讯 ASR、Mac 本地分析服务、DeepSeek 歌词校准、候选检索、缓存与测试

原始审查边界：2026-08-24 只审查、验证和完善文档。2026-08-25 用户授权按最优方向
实施修复。本文现在同时记录“原始根因”和“当前已落地状态”，不再把已实现能力列为未完成。

> 2026-08-27 架构更新：Debug 与 Release 已统一为当前 Jellyfin 主机的 Mac `8011/v1`
> 本地任务；VPS 上传路径已停用。下文提及 Debug/Mac 与 Release/VPS 分叉的内容仅是历史审查记录。

## 2026-08-25 最终实施状态

- D3 缓存已绑定实际 ASR words/时间、VAD 分数/标记和候选内容 SHA-256，不再复用
  旧 word-range 映射。
- Mac Debug 已以 `python-audio-separator 0.44.5 + Kim_Vocal_2.onnx` 生成 vocals stem，
  再在人声轨上跑 Silero VAD v6，而不再用混音能量判断“有没有人唱”。
- 音频管线已改为“原视频一次解码为 44.1 kHz PCM/WAV → 人声分离 → VAD →
  各腾讯分片独立从无损人声轨编码”，消除了“整首 AAC 再转分片 AAC”的二次有损编码。
- 整首人声覆盖和平均概率同时低于阈值时，任务以 `NO_VOCALS_DETECTED` 结束，
  不调用腾讯，避免为明显无人声媒体付费。
- Apple TV ASR 字幕和 DeepSeek 都会排除无候选支持的伴奏残留；对 vocals stem 中仍残留的
  `BB / DD / Dee / E` 等短促乐器幻觉有额外的窄规则，`He he` 和 `Bear` 等真实短词保留。
- D3 不再因模型行乱序、重叠或单行文字无证据而整首 422；服务器按 ASR 时间确定性
  排序，丢弃重叠/无支持模型行，再把模型遗漏但有人声证据的 ASR 词自动回收为字幕。
  响应新增 `asr_word_coverage` 和 `recovered_asr_word_count`，可直接查看是否丢词。
- Web 候选改用服务器生成的稳定 `candidate_id:retrieved_text` 证据 ID，并安全归一化
  DeepSeek 自行编造的 Web 行名，修复 ASR 已成功但 DeepSeek 422 的直接转换故障。
- Mac `8011` 已改为 LaunchAgent 登录启动/异常自恢复；Apple TV 现会把 `-1004` 明确说明为
  Mac 服务无法连接。LaunchAgent 使用 `ProcessType=Interactive`，因为 `Background` QoS
  在这台 Apple Silicon Mac 上使 CoreML 分离慢约一个数量级。
- 当前回归：Python 54/54，tvOS 26.2 模拟器 58/58。真机已覆盖安装，AVKit 方向键焦点手感仍需人工验收。

尚未完成的核心能力是歌声专用活动检测、腾讯真实词置信度、可信歌词的歌声强制对齐和
10–20 首人工标注回归集。当前已显著降低三首实测歌曲的伴奏幻觉和模型漏词，但仍不应宣传为
“所有儿歌都可靠”或“实时字幕”。

## 一、结论摘要

当前版本已经完成了一个可人工操作的开发闭环：Apple TV 可以请求 Mac 分析本地 Jellyfin
视频，Mac 提取音频并调用腾讯 ASR，Apple TV 可单独采用 ASR 字幕；随后还可以人工调用
DeepSeek，保存并单独采用另一份校准字幕。Baby Shark 的人工验证说明这个闭环确实可以成功。

原始效果不稳定的主要原因不是一个提示词写得不好，而是链路中缺少了几层字幕系统的基础能力。
本轮已落地其中的无损中间音频、人声分离、人声轨 VAD、证据缓存和模型漏词回收：

1. 腾讯接口是通用语音识别，不是专门的歌声歌词转写；现在已先输入分离后人声，
   但人声 stem 仍会有泄漏和分离伪影。
2. 审查时没有人声活动、纯音乐门控或幻觉过滤；现已有 vocals stem + VAD +
   短促残留过滤，但腾讯本身仍未提供可用的真实词置信度。
3. ASR 字幕和 DeepSeek 字幕不是直接转换关系。两者从同一份 ASR 词时间线分别重新分行，
   所以行数、边界和文字无法一一对应。
4. DeepSeek 结果只允许绑定已有 ASR 词。当前可自动回收“DeepSeek 漏掉”的有声 ASR 词，
   但 ASR 本身完全没有返回的演唱仍无法生造时间。
5. 服务端现已计算 ASR 词覆盖并回收所有非风险空洞；仍未实现基于人工真值的重复副歌数量、
   尾段人声和时间误差门槛。
6. 审查发现的 DeepSeek 缓存证据绑定缺失已于 2026-08-25 修复；当前键包含实际 ASR/VAD/候选哈希。
7. 2026-08-27 已移除原有 Debug/Mac 与 Release/VPS 分叉；当前两种构建都只走当前 Jellyfin
   主机的 Mac `8011/v1`，连接失败时不回退 VPS。

因此，后续不应该继续把主要精力放在调整 DeepSeek 提示词上。当前最值得继续的顺序是：
建立真实歌曲质量基线 → 引入第二 ASR/强制对齐 A/B → 完善可信歌词和重复结构验收 → 英文稳定后再生成双语字幕。

## 二、本轮验证结果

### 2.1 自动化验证

- Python 服务端：使用临时 SQLite 覆盖本机 `.env` 中的生产数据库路径后，54 项测试通过。
- tvOS：使用 tvOS 26.2 模拟器和禁止签名方式运行，58 项测试通过。
- 自动化测试未连接或修改真实“客厅” Apple TV。
- 本轮已修改 Mac 音频质量链路、D3 确定性校验/恢复、Apple TV 响应解码和相关测试。

直接在 `BabyPlayerASRServer` 执行 README 原来的测试命令会加载本机 `.env`。如果其中
`DATABASE_PATH=/var/lib/babyplayer-asr/...`，普通 Mac 用户会在测试收集阶段遇到权限错误。
这不是业务测试失败，而是测试没有隔离运行配置。安全的当前命令见服务端 README。

### 2.2 人工与过程文件证据

用户确认 Wheels 的开头顺序是“只有旋律 → 汽车声 → 节奏”，这整段都没有人声。
这一真值用于验收新质量层，不再把明显的乐器能量当作演唱。

本机 `LyricsTestOutputs` 是 Git 忽略的开发过程目录。当前可见数据如下：

| 曲目 | 音频时长 | 新 ASR 词数 | 首个可见词 | 末词 | DeepSeek 行数 | ASR 词覆盖 | 观察 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Baby Shark | 189.76 s | 417 | 12.55 s | 176.99 s | 92 | 100% | 旧 7.60 s 伴奏幻觉消失；每轮重复演唱保留，DeepSeek 无漏词回收 |
| The Wheels On The Bus | 157.17 s | 191 | 22.45 s | 140.07 s | 32 | 99.45% | 22.45 s 前零字幕；`BB/DD/Dee/E` 残留被排除；唯一未覆盖项为无实质文字标点 |
| Who Took the Cookie? | 122.10 s | 175 | 0.50 s | 120.35 s | 31 | 100% | 新识别补齐首尾；Web 证据 ID 修复后 D3 可直接成功 |

人声分离后 Baby Shark 的词数从 433 降到 417，主要是前奏幻觉和重复 `doo/d`
伪影被删除，不是副歌数量下降。Wheels 的旧结果从 14.45 秒就显示字幕；新 ASR 虽仍从
11.56 秒识别出 `BB`，但人声证据将其与后续间奏残留标为不可见，最终 ASR 和
DeepSeek 都从实际开唱的 22.45 秒开始。

注意：`asr.srt` 按腾讯原始 segment 输出，而 Apple TV 会把同一 segment 按 6 词、30 字符、
3.2 秒和停顿重新分行。因此过程目录里的 `asr.srt` 不能复现电视实际看到的 ASR 字幕，不能直接
拿它与 `ai.srt` 做逐行 A/B 比较。

## 三、当前真实架构

### 3.1 操作模型

当前不是普通播放时的实时字幕，而是“一次显式触发 + 自动后续”的结果：

```text
普通歌词搜索（LRCLIB / 内置歌词）
        │
        ├── 家长可固定、校时、反复切换
        │
人工点击“ASR 识别歌词”
        │
        ├── 保存 ASR 字幕
        ├── 自动进入 DeepSeek（亦保留单独手工入口）
        ├── 要求服务端已有 ASR
        ├── 保存 DeepSeek 字幕并自动启用
        │
        └── 家长仍可在 ASR / DeepSeek / 普通歌词之间手工 A/B
```

普通播放、搜索普通歌词、单曲循环和重新进入播放器都不会自动调用腾讯或 DeepSeek，因此仍能避免
意外计费。家长点击 ASR 即是对这一次完整链路的明确授权；如果处理期间又手动切换字幕，较新的
手工意图优先，DeepSeek 结果只保存不覆盖。

### 3.2 Debug 真机路径

当 App 是 Debug 构建且 ASR Base URL 为 HTTP 时：

```text
Apple TV
  └── POST /v1/local-analysis/jobs
        只提交 Jellyfin 本机 Path、媒体指纹和歌曲时间范围
              │
              ▼
Mac 本地服务
  ├── 校验 Path 必须位于 LOCAL_MEDIA_ROOTS 白名单
  ├── 对原视频计算 SHA-256
  ├── FFmpeg 对歌曲范围一次精确 seek，解码为 44.1 kHz PCM/WAV
  ├── Audio Separator + Kim_Vocal_2.onnx 提取 vocals stem
  ├── 在 vocals stem 上运行 Silero VAD，整首无人声时提前停止
  ├── 每个 60 秒/重叠 5 秒分片都直接从无损人声轨编码
  ├── 顺序调用腾讯 Flash ASR
  ├── 按重叠中点合并词时间线
  └── SQLite 缓存 ASR + 预处理/VAD 证据，开发模式可保存过程文件
```

优点是 Apple TV 不需要上传音频，Mac 可直接访问原媒体，也便于保留调试证据。限制是 Jellyfin
必须向 Apple TV 返回对 Mac 有意义的本机路径，而且 Mac、Jellyfin、服务和媒体盘都要在线。

### 3.3 Release / HTTPS 路径

Release 构建不会使用 Mac 本地任务，即使 Base URL 指向 HTTP 也会关闭该路径。当前 Release 逻辑：

1. Apple TV 使用 `AVAssetExportSession` 从当前媒体临时导出整首 M4A。
2. Jellyfin 的远程 fragmented MP4 如果不能直接导出，Apple TV 可能先临时下载整份源视频。
3. Apple TV 把整首临时 M4A 上传到 `/v1/analyze`。
4. 上传完成或失败后删除临时音频。

这条路径没有使用 Mac 的 60/5 分片任务，网络、内存、临时空间、导出兼容性和超时条件也完全不同。
当前“Baby Shark 通过”的结论只覆盖已实测的开发路径，不能自动外推到 Release / VPS。

### 3.4 ASR 与 DeepSeek 的数据关系

ASR 展示字幕：Apple TV 读取腾讯 `segments[].words[]`，再按照电视可读性规则重新分行。

DeepSeek 字幕：Apple TV 明确过滤掉所有带 `identityAnchor` 的 ASR/AI 候选，只上传最多三份普通
歌词；服务器从 SQLite 重新读取原始 ASR words，让 DeepSeek 为每一行选择连续的词索引范围，
然后服务器机械换算开始/结束时间。

因此真实关系是：

```text
                  ┌── Apple TV 可读性分行 ── ASR 字幕
腾讯 ASR words ───┤
                  └── 普通歌词 + DeepSeek 重建 ── DeepSeek 字幕
```

它们是共享一份词时间线的两个派生结果，不是“ASR SRT 直接送给 DeepSeek 转码”。

## 四、已经完成的有效改进

以下改进在代码中真实存在，应保留：

1. ASR 和 DeepSeek 仍是可独立测试的两个阶段；播放器已将人工发起 ASR 改为自动续跑 DeepSeek 并启用，同时保留所有手工入口。
2. ASR、DeepSeek 和固定普通歌词可以共存，并可反复采用。
3. Debug 路径改为 Apple TV 只提交轻量任务，Mac 直接读取白名单内的 Jellyfin 本地文件。
4. Mac 对完整原视频计算内容 SHA-256，减少文件变化后误用旧 ASR 的风险。
5. ASR 缓存版本包含分片时间线版本与 60/5 形状，旧整首结果不会遮住新的分片算法结果。
6. 60 秒分片加 5 秒重叠，按时间归属合并；不会因为歌词文字相同就全局删除重复副歌。
7. 腾讯返回超长 segment 时，Apple TV 会按词数、字符数、时长和停顿拆成短行。
8. DeepSeek 只返回 ASR 词范围，最终时间由服务器生成，避免模型自由编造时间戳。
9. 服务端有 Bearer Token、月度 18,000 秒硬限额、并发/频率限制和 SQLite 缓存。
10. 本地路径接口只在非 production 开放，且读取范围受 `LOCAL_MEDIA_ROOTS` 限制。
11. 开发过程可保存音频、原始 ASR、候选、DeepSeek 输入输出和 SRT，具备排查基础。
12. `.env`、私密 xcconfig、本地数据库和过程文件已被 Git 忽略；当前和历史提交均未发现真实密钥。
13. Mac 已从一次 PCM/WAV 解码生成 vocals stem，VAD 和每个腾讯分片共用同一无损时间线。
14. 整首无人声可在云端 ASR 前门控；音频预处理摘要、模型版本和 VAD 范围都进入缓存与过程文件。
15. D3 响应提供客观 ASR 词覆盖；模型遗漏的有声词会以有界 ASR-only 行补回，不再默默丢副歌。
16. LaunchAgent 已使用 Interactive QoS 和可重试 bootstrap，解决 `-1004`、异常退出和 CoreML 后台降速。

这些改进解决了“链路能否跑通、能否人工比较、能否控制成本和避免覆盖”的问题，但还没有解决
“歌词是否完整、纯音乐是否安静、重复副歌是否全部保留、时间是否足够准”的质量问题。

## 五、重点问题与根因

### 5.1 ASR 字幕为什么不能直接用于 DeepSeek 字幕

这是实现契约和缓存正确性共同造成的。

#### 直接原因：两者采用不同分行器

- ASR 字幕在 Swift 中按最多 6 词、30 字符、3.2 秒、0.65 秒停顿分行。
- DeepSeek 可为一行选择最多 100 个 ASR 词，服务端没有再次套用电视可读性分行规则。
- D3 请求明确排除了 ASR 字幕候选，所以 DeepSeek 根本没有接收 Apple TV 已形成的 ASR 行 ID。
- 过程文件 `asr.srt` 使用腾讯 segment，和 Apple TV 的 ASR 行又是第三种结构。

所以目前不存在稳定的 `ASR cue ID → DeepSeek cue ID` 映射，也无法保证行数相同。

#### 严重原因：DeepSeek 服务端缓存没有绑定真实证据

审查时 AI 缓存键为：

```text
subject + media_fingerprint + reconciliation_version + ASR analysis_version
```

它没有包含：

- 实际 ASR transcript/word timeline 的哈希；
- 原视频内容 SHA-256；
- 本次普通歌词候选内容哈希；
- Web 候选内容哈希。

如果在算法版本不变时强制重跑 ASR，或者普通歌词候选改变，非强制的 DeepSeek 请求仍可能返回旧映射。
Apple TV 随后把这份服务端旧结果标记为当前本地 ASR 的 evidence hash，导致“本地看起来版本一致，
实际 word index 来自旧时间线”。

该 P0 已修复：当前以实际 ASR words/时间、VAD 标记和候选内容的规范 JSON SHA-256 作为
evidence cache version 的一部分。

### 5.2 为什么无歌词或纯音乐部分也生成字幕

原因是原链路只把混合音轨送给通用 ASR，无法区分“有节拍”和“有人唱”。通用 ASR 会把
乐器泛音、汽车声、回声和分离伪影识别成短词，而旧实现又会无条件显示所有 ASR word。

当前已改为四道门控：

1. 从原视频一次解码 PCM/WAV，先提取 vocals stem。
2. 在 vocals stem 上跑 Silero VAD；整首人声覆盖和平均概率同时过低时，不调腾讯。
3. 为每个 ASR word 计算人声分数和覆盖，连续低活动词组标记为可能伴奏幻觉。
4. 对 vocals stem 特有的弱短残留使用极窄词法规则；只过滤如 `BB/DD/Dee/E`，
   不删除 `He he`、`Bear` 或常见短词。

Wheels 实测证明这个分层方法正确：腾讯仍在 11.56 秒返回 `BB`，但最终字幕不会出现；
第一句从实际演唱的 22.45 秒开始。这比单纯提高 VAD 阈值更安全，因为儿歌的弱声、拉长音和独立角色名
也容易被通用 VAD 低估。

现有 `testASRTimelineHidesSubtitleDuringInstrumentalGap` 只证明“如果 cue 之间本来存在空档，播放器会
隐藏字幕”，并没有证明“ASR 不会在纯音乐区错误创建 cue”。测试名称容易让人高估当前能力。

### 5.3 为什么部分副歌内容丢失

有三种独立丢失路径，当前已解决其中的“模型合法跳词”，但无法凭空恢复 ASR 本身完全漏掉的演唱。

#### 路径 A：ASR 根本没有返回词

当 ASR 完全没有返回某段演唱时，DeepSeek 不能凭歌曲记忆创造时间。这一安全边界仍然保留。
新 Wheels 的末词提升到 140.07 秒；用户已确认开头无人声，但还没有对 140.07–157.17 秒建立人工真值，
所以不再把这 17.10 秒自动定性为“漏掉的尾段副歌”。

#### 路径 B：DeepSeek 可以合法跳过词

原服务端只要求各行词范围单调、不重叠和不越界，没有要求相邻范围连续；DeepSeek 因此可以合法跳过副歌。
现在服务端会把所有未被模型覆盖、且没有伴奏幻觉标记的 ASR 词按原 segment、最多 12 词和
1.25 秒时间间隙确定性回收；并返回客观覆盖率。对重叠/乱序模型行也不再整首失败，而是舍弃模型行后用原 ASR 补回。

`song_match_confidence` 是模型自报值，Swift 只检查它位于 0 到 1，没有最低采用门槛。因此 0.90
不能被解释为 90% 完整，也不代表重复副歌数量正确。

#### 路径 C：候选版本和重复结构没有被确定性验证

- LRCLIB 只用歌名、演唱者、版本提示和时长进行粗排，最多留下 3 份。
- Wheels 当前第一候选明显包含口白和不同编曲，第二候选又有 doors 等不同段落。
- 服务端相似度取“顺序相似度、左右 token coverage”三者的最大值。儿歌重复词很多，错误或截短
  版本也可能获得很高的无序 coverage。
- 当本地分数超过阈值时，即使 DeepSeek 第一阶段请求搜索，服务器也可能阻止 Web 搜索。
- 提示词要求保留重复演唱，且当前会回收所有有声 ASR 空洞；但在没有人工段落真值时，
  仍无法证明每个 verse/chorus 的实际出现次数是 100% 正确。

### 5.4 其他重要问题

| 状态 | 优先级 | 问题 | 当前结论 |
| --- | --- | --- | --- |
| 已修复 | P0 | DeepSeek 缓存未绑定实际 ASR 和候选证据哈希 | 已绑定 ASR words/时间/VAD/候选证据哈希 |
| 已修复主链路 | P0 | 没有人声/静音门控 | 已有 vocals stem、stem VAD、整首无人声门控和短残留过滤；仍无腾讯词置信度 |
| 部分修复 | P0 | 没有尾段、连续覆盖和重复结构验收 | 已回收有声 ASR 空洞并输出覆盖率；仍需人工真值的尾段/重复数量验收 |
| 待处理 | P1 | Debug/Mac 与 Release/VPS 数据路径不同 | 开发真机通过不能代表发布版通过 |
| 待处理 | P1 | ASR、开发 SRT、DeepSeek 使用三种分行契约 | 难以逐行比较；仍需统一 canonical cue |
| 已修复 | P1 | 整首 AAC 后再把 AAC 重编码成分片 AAC | 现从一次 PCM/WAV 无损人声轨独立编码过程件和每个分片 |
| 待处理 | P1 | 歌词绑定和分析副本实际保存在 tvOS Caches | 系统空间不足时可清除，不能称为永久保存 |
| 待处理 | P1 | 没有 10–20 首真实歌曲标注集和质量指标 | “自动化测试通过”不等于字幕效果通过 |
| 待处理 | P2 | Apple TV 把所有本地识别进度显示成 1/1 | Mac 实际分片状态没有传到用户 |
| 待处理 | P2 | 通用网页抓取只抽取整页可见文本 | 导航、简介和页面噪声可能混进歌词证据 |
| 待处理 | P2 | 本地接口只判断 `PRODUCT_ENV == production` | 环境名误拼会意外开放本地 Path 接口 |
| 待处理 | P2 | 服务在模块导入时创建 App 并加载 `.env` | 测试必须显式覆盖临时 SQLite |
| 待清理 | P2 | Swift 中还保留旧分片、旧 repair 和停用代码 | 测试覆盖数字与当前主链路能力不完全等价 |

## 六、Apple TV 与服务器限制

### 6.1 tvOS 存储不是持久数据库

当前歌词候选、绑定和分析副本实际写入 App 私有 `Caches`。Apple 的 tvOS 指南说明，除很小的
`UserDefaults` 持久空间外，其他本地数据必须允许系统在空间不足时清除；App 不运行时缓存可能被删除。

因此文档和产品都应采用以下表述：

- Apple TV 保存的是可丢失的本地副本，不是权威永久存储。
- App 正在运行时缓存通常不会被系统删除，但不能承诺重启或长期保留。
- 卸载 App 一定会删除 App 容器；覆盖安装是否保留也不应作为数据保障。
- 可重建的权威结果应留在 Mac/VPS，电视发现副本丢失后重新拉取。
- 如果要保存家长人工校时和固定选择，应同步到 Mac/VPS 或 iCloud，而不是只依赖 Caches。

参考：[Apple tvOS 本地存储限制](https://developer.apple.com/go/?id=app-programming-guide-for-tvos)。

### 6.2 后台运行与长任务

tvOS 会在用户离开 App 后较快挂起普通应用。当前轮询任务依赖播放器控制器和前台 Task；Mac 的后台
任务可能继续完成，但 Apple TV 不应承诺持续轮询或立即保存结果。后台 `URLSession` 适合文件传输，
不能自动把当前轮询和 DeepSeek 工作流变成可靠后台作业。

参考：[Apple TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)、
[后台下载](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)。

### 6.3 网络与媒体路径

- Debug 本地服务使用局域网 HTTP，只能用于受控开发网络，不能作为公开发布配置。
- Apple TV、Mac、Jellyfin 和媒体磁盘必须同时可达。
- Jellyfin 返回的 `Path` 必须是 Mac 上真实存在且位于白名单内的路径。
- Release 路径可能让 Apple TV 临时下载完整远程 MP4，长视频会增加等待、临时空间和失败概率。
- Release 必须使用 HTTPS；一个共享 Bearer Token 只适合当前个人内测，不适合公开分发。

### 6.4 服务端与第三方能力

- 腾讯 Flash ASR 面向录音/音视频字幕等通用语音场景，不等于歌声专用歌词转写。
- 当前配置是 `16k_en + word_info=1`。腾讯接口还提供热词、自学习模型等参数，但对儿童歌声是否
  有效需要用自有歌曲集 A/B 验证，不能直接假设会提升。
- Mac 每首歌先完成全部提取和分片，再顺序调用腾讯，最后才运行 DeepSeek；这是批处理，不是实时字幕。
- 开发过程目录包含完整提取音频、歌词文本和模型输入输出。虽然被 Git 忽略，仍应设置自动清理周期，
  并只保存自己有权处理的媒体。
- 当前 SQLite 和共享 Token 面向单用户，未来多设备需要逐设备身份、任务幂等和权限隔离。

腾讯参考：[录音文件识别极速版](https://cloud.tencent.com/document/product/1093/52097)。

## 七、为什么 YouTube、翻译插件和学习 App 看起来更好

这个比较最容易产生误判，因为输入和目标并不相同。

| 场景 | 常见真实输入 | 相对容易的原因 |
| --- | --- | --- |
| 沉浸式翻译插件 | 平台已经提供的字幕轨，再做翻译 | 主要解决文本翻译和双语排版，很多时候没有重新做 ASR |
| YouTube 点播 | 完整视频上传后后台预计算，也可能有创作者字幕 | 可以用全局上下文、重跑模型、人工修订，不要求边播边出 |
| YouTube 直播 | 正常延迟下的自动字幕，或外部专业字幕流 | 可接受延迟；大型活动常直接接入人工/专业字幕供应商 |
| 英语学习 App | 已知课程脚本、单人清晰发音、低背景噪声 | 本质接近“已知文本强制对齐”，不是从混合音乐猜歌词 |
| 短剧 | 制作方已有台词、剪辑时间线或预制字幕 | 经常是内容资产，不是播放端现场生成 |
| BabyPlayer 当前 | 英文歌声 + 伴奏 + 拟声 + 重复副歌 + 版本不确定 | 同时做曲目识别、歌词发现、歌声 ASR、对齐和字幕分行 |

沉浸式翻译官方说明要求先启用会议平台或视频网站自身字幕；Bilibili 没有字幕内容时也无法提供双语
字幕。YouTube 官方同样明确说明自动字幕会受背景噪声、口音、静音和重叠说话影响，并鼓励创作者
审阅或上传专业字幕。

参考：[沉浸式翻译使用说明](https://immersivetranslate.com/docs/usage/)、
[沉浸式翻译 FAQ](https://immersivetranslate.com/docs/faq/)、
[YouTube 自动字幕](https://support.google.com/youtube/answer/6373554?hl=en)、
[YouTube 直播字幕输入](https://support.google.com/youtube/answer/3068031?hl=en)。

真正值得借鉴的不是“把 LLM 换得更大”，而是它们把字幕拆成稳定的多个阶段，并对输入质量、
延迟、置信度、回退和人工修订分别设计。

## 八、可借鉴的开源项目

### 8.1 通用 ASR 与时间戳

| 项目 | 关键方法 | 对 BabyPlayer 的价值 | 限制 |
| --- | --- | --- | --- |
| [faster-whisper](https://github.com/SYSTRAN/faster-whisper) | VAD、word probability、avg logprob、no-speech probability、重复和幻觉阈值 | 可作为 Mac 上第二 ASR 基线，补齐当前腾讯结果丢弃的质量信号 | 通用语音模型，歌声仍需实测 |
| [WhisperX](https://github.com/m-bain/whisperX) | VAD + wav2vec2 强制对齐，生成词级时间 | 有已知歌词时，比让 LLM 选择 word ranges 更适合做确定性对齐 | 对语言和对齐模型有要求；歌声不一定等同语音 |
| [stable-ts](https://github.com/jianfch/stable-ts) | 静音抑制、VAD、词时间和 regrouping | 分行与静音处理值得参考 | 项目已暂停开发，不宜作为长期唯一依赖 |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | 本地推理和实时 stream 示例 | 可在 Mac 本地运行，减少云依赖 | 直接在 tvOS 集成的体积、性能和维护成本较高 |

### 8.2 实时字幕

| 项目 | 关键方法 | 可借鉴点 |
| --- | --- | --- |
| [Whisper-Streaming](https://github.com/ufal/whisper_streaming) | LocalAgreement-n：连续多次结果一致的前缀才提交；VAD/VAC；动态缓冲裁剪 | 不要把每个小分片的第一次结果直接上屏，要区分 provisional 与 committed |
| [WhisperLiveKit](https://github.com/QuentinFuxa/WhisperLiveKit) | WebSocket、VAD/VAC、SimulStreaming/LocalAgreement、多后端 | 如果未来真做实时，可参考端到端服务结构和增量稳定策略 |
| [WhisperLive](https://github.com/collabora/WhisperLive) | 连续音频 WebSocket、VAD、词时间、hotwords、多后端 | 浏览器/客户端只推流，重计算放到服务器；适合研究而非直接照搬 |

Whisper-Streaming 明确指出，简单固定小窗口会切断单词并丢失上下文；它用多次更新的一致前缀解决
“结果什么时候可以稳定上屏”的问题。当前 BabyPlayer 是完整文件批处理，没有 provisional/committed
概念，不能仅靠把 60 秒改成 2 秒就得到成熟实时字幕。

### 8.3 歌声专用处理

| 项目 | 关键方法 | 对当前问题的价值 |
| --- | --- | --- |
| [python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator) | 统一调用 UVR/MDX/Demucs/MDXC 等 vocals 分离模型，支持 Apple Silicon CoreML | 已以 0.44.5 + `Kim_Vocal_2.onnx` 接入 Mac 主链路；模型约 66.8 MB，这台 M2/24 GB Mac 实测分离 2–3 分钟儿歌约 54–117 秒，峰值内存约 5–6 GB |
| [Demucs](https://github.com/facebookresearch/demucs) | 从混合音乐分离 vocals 和 accompaniment | 可在离线开发阶段验证“只识别人声 stem”是否减少纯音乐幻觉和漏词；原仓库已归档，应评估维护风险 |
| [SOFA](https://github.com/qiuqiao/SOFA) | Singing-Oriented Forced Aligner | 当歌词文本可信时，直接做歌声强制对齐，目标比通用 ASR 更接近本项目 |
| [lyrics-aligner](https://github.com/schufo/lyrics-aligner) | 歌词与混合音乐的音素/词级对齐，并联合歌声分离 | 证明“可信歌词 + 专用对齐”是成熟研究路径 |
| [All-In-One](https://github.com/mir-aidj/all-in-one) | 人声分离后的歌曲结构分析，输出 intro/verse/chorus | 可辅助检查重复副歌和尾段结构，但不直接生成歌词 |

相关研究也把 Automatic Lyrics Transcription 单独视为比普通语音识别更困难的任务，并持续研究
人声分离对 Whisper 歌词转写的帮助：
[Exploiting Music Source Separation for Automatic Lyrics Transcription with Whisper](https://arxiv.org/abs/2506.15514)。

不建议现在直接替换为某一个开源仓库。更稳妥的方法是抽取其中的架构原则，在同一批儿歌上做
腾讯原音、腾讯人声 stem、faster-whisper 原音、faster-whisper 人声 stem 四组对比。

## 九、推荐的目标架构

对于已经存放在 Jellyfin 的固定儿歌，优先做“播放前离线生成”，而不是为了看起来先进而直接追求
实时。离线可以使用整首上下文、重复运行、完整性检查和人工确认，最终体验反而比边播边猜更稳定。

推荐结构：

```text
Jellyfin 原视频
  │
  ├── 无损/单次解码为 PCM/WAV
  ├── 人声分离（Mac 已实现，模型可版本化）
  ├── 人声轨 VAD / 整首无人声门控（已实现）
  │
  ├── ASR A：腾讯
  ├── ASR B：faster-whisper/WhisperX（先作为评估与回退）
  │
  ├── 可信歌词来源
  │     ├── 内置已授权歌词
  │     ├── LRCLIB 候选
  │     └── 限域官方来源
  │
  ├── 确定性版本选择与重复结构检查
  ├── 歌声强制对齐 / 单调动态规划
  ├── 质量门槛：人声、覆盖、尾段、重复、时间误差、可读性
  │
  ├── 统一 canonical cue schema
  │     ├── cue_id
  │     ├── source_word_ids
  │     ├── start/end
  │     ├── original_text
  │     ├── normalized_text
  │     ├── acoustic_confidence
  │     └── alignment_confidence
  │
  └── 英文字幕稳定后，异步生成中文翻译并共用 cue_id
```

DeepSeek 最适合做：候选解释、轻量错词修正、英文标点/大小写和翻译。它不应该独自决定哪里有人声、
副歌出现了几次或整首是否覆盖完整；这些应由声学信号和确定性校验决定。

如果没有任何可信歌词，允许进入单独标记的“ASR-only 低置信模式”，但必须：

- 先通过人声活动掩码；
- 低置信词不显示；
- 大段未识别保持空白，不让 LLM 根据歌曲记忆补齐；
- 明示结果需要家长确认，不与已验证歌词使用同一质量等级。

## 十、建议执行顺序

### 阶段 0：先建立质量基线（进行中）

1. 选 10–20 首覆盖前奏、间奏、重复副歌、拟声、快慢歌和不同演唱者的儿歌。
2. 人工标注每句文字、开始/结束、人声区间、段落类型和重复次数。
3. 固定保存每次运行的音频哈希、配置、ASR 原始 JSON、最终 cues 和指标。
4. Baby Shark、Wheels、Who 已完成机器侧回归记录；仍需扩充到 10–20 首并补全人工词级真值。

建议初始指标：

- 重复 verse/chorus recall：100%；
- 末段覆盖：最后一个实际演唱词与字幕末词差不超过 2 秒；
- 纯音乐误报：纯音乐区字幕占用不超过 1%，且不允许持续 0.5 秒以上的幻觉句；
- 已知歌词行覆盖：不低于 98%；
- 行开始时间中位误差：不高于 0.35 秒，P95 不高于 0.8 秒；
- 单行最多 6–8 个英文词，显示时间 0.8–4.0 秒；
- 错版本采用率：0。

这些值是首轮工程目标，需根据真实标注和电视观看体验调整。

#### 最少人工标注怎么做

不需要逐帧点“有人声/无人声”，也不需要从空白文件开始。对每首歌，用当前
`asr_quality_filtered.srt` 和 `ai.srt` 作为机器预标，人只需听一遍并修正以下内容：

| 必填项 | 最小标注 | 用途 |
| --- | --- | --- |
| 媒体身份 | 原视频 SHA-256、歌曲起止 | 保证下次测的是同一版本 |
| 人声区间 | 每个连续演唱/口白段的开始和结束 | 其补集自动就是前奏/间奏/音效负样本，无需另外逐段标“无人声” |
| 歌词 cue | 每句文字、句首、句尾 | 计算错词、时间误差和覆盖 |
| 段落标签 | intro / verse / chorus / bridge / outro / spoken / sound-effect | 检查副歌数量和纯音乐误报 |
| 重复编号 | 例如 `chorus-1/2/3` | 确保模型没有合并或删除重复演唱 |

首轮只做 Baby Shark、Wheels、Who、Rain 和一首大量前奏/间奏的歌。每首预计只需
5–10 分钟“听 + 改边界/错词”，而不是手工重做全部字幕。当规则或模型改变时，同一份真值可自动重放；
只需对失败样本增量复核。这是用少量人工换取之后大量自动化可靠性的最小方案。

### 阶段 1：修复确定性正确性

1. 已完成：DeepSeek 缓存键加入实际 ASR/VAD/候选 evidence hash；ASR 本身仍以媒体指纹和原视频 SHA-256 校验。
2. 已完成：Apple TV 的 ASR evidence hash 包含完整 word timeline 和质量标记，新证据会使旧 DeepSeek 结果过期。
3. 建立统一 cue schema；ASR SRT、电视 ASR 和 DeepSeek 输出复用同一个分行器。
4. 部分完成：D3 已校验/回收 ASR 索引空洞并返回词覆盖率；首尾人声和重复段落数量仍需人工真值。
5. `song_match_confidence` 改为服务端计算的指标集合，不再直接信任模型自报值。

### 阶段 2：补齐声学质量层（主链路已完成，第二 ASR 待 A/B）

1. 已完成：一次解码为 PCM/WAV，整首过程件和腾讯分片都从无损人声轨生成。
2. 已完成：保存每个 ASR word 的 vocals-stem VAD 分数/覆盖/风险标记。
3. 已完成首轮 A/B：使用 Audio Separator + Kim Vocal 2，并以 Baby Shark/Wheels/Who 实测；更大模型只应在标注集上证明收益后替换。
4. 同一标注集比较腾讯与 faster-whisper/WhisperX，保留 word probability、no-speech probability、
   avg logprob 等质量信号。
5. 只在多个声学证据通过时创建 cue；纯音乐区默认空白。

### 阶段 3：改为“可信歌词强制对齐优先”

1. 优先使用内置已授权歌词或高置信候选，保持原文和重复顺序。
2. 用 WhisperX、SOFA 或现有单调 DP 的实测结果选择对齐器。
3. 以歌曲结构和声学重复证据检查每次副歌，不让 LLM自由删行。
4. 对无法对齐的行返回 `unmatched`，不要强行插值成看似正确的时间。

### 阶段 4：产品化和双语字幕

1. Mac/VPS 保存权威结果，Apple TV 只缓存并可自动重新拉取。
2. 分析任务与 App 前台轮询解耦；重新进入播放器可以按 job ID 恢复。
3. 英文 cue 通过质量门槛后再翻译，中文和英文共用 cue ID 和时间。
4. 家长修订、固定选择和时间调整同步回权威存储。
5. 最后再评估 WebSocket 实时模式；对固定 Jellyfin 媒体，默认仍建议预生成。

## 十一、下一轮验收清单

### Baby Shark

- 已确认新首词 12.55 秒，旧 7.60 秒伴奏幻觉被消除。
- 已确认 417 个 ASR 词全部进入 92 行 DeepSeek 时间线，`asr_word_coverage=1.0`。
- 待做：人工标注每段人声区间和标准文本，将 `Save it last` 等仍存在的轻微 ASR 错词纳入可量化 WER。

### The Wheels On The Bus

- 已确认 0–22.45 秒的旋律、汽车声和节奏区无人声，最终零字幕。
- 已确认 `BB/DD/Dee/E` 没有进入 ASR 质量过滤字幕或 DeepSeek 结果。
- 已确认 DeepSeek 32 行、覆盖率 99.45%，首句 22.45 秒、末句 140.07 秒；原先允许的跳词路径已封堵。
- 待做：确认 140.07–157.17 秒的人声真值，不在没有听辨证据时自动判定为漏词。
- 对三个 LRCLIB 候选逐段标记正确/错误版本，验证检索门槛。
- 副歌/verse 数量必须作为确定性断言，而不是人工扫一眼。

### Rain Rain Go Away

- 检查 24 个 discarded candidate lines 是正确剔除还是过度删除。
- 核对 125.56 秒后的约 29.9 秒是否为纯音乐、片尾或漏识别人声。
- 若为纯音乐，该曲可作为尾段静音门控的正向样本；若有人声，则属于与 Wheels 同类的尾段漏识别。

## 十二、当前可接受的产品定位

建议继续把功能称为“家长触发的歌词分析/校准”，不要称为“可靠实时字幕”。声学主链路已显著改善，
但阶段 0 的标注集和阶段 3 的可信歌词强制对齐仍未完成。当前版本适合继续个人内测，不应在没有家长确认的情况下
自动替换全部儿歌字幕。

这并不意味着儿歌 App 做不到。恰恰因为媒体库固定、歌曲数量有限、歌词经常可提前获得，本项目有比
开放式 YouTube 实时字幕更有利的条件。只要把目标从“让通用 ASR 和 LLM 猜完整歌词”调整为“可信
歌词 + 歌声声学门控 + 专用对齐 + 可量化验收”，效果应当能显著提升。
