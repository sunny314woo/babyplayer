# BabyPlayer 开发接力摘要

更新：2026-08-25（人声分离与 Wheels 前奏修复后）
项目：`/Users/wufengyu/Projects/AppleTV-儿童播放器`

本文件用于快速接力；架构现状、代码审查、实测数据、竞品研究和改进优先级以
[《智能歌词与自动字幕现状审查》](SMART_LYRICS_AUTO_SUBTITLE_AUDIT_2026-08-24.md)为准。

## 当前方向

- 播放和交互仍在物理 Apple TV“客厅”上验证。
- Mac 本地运行歌词服务，调用腾讯 ASR / DeepSeek，并保存过程文件。
- Apple TV 只提交一个很小的分析任务，不再转换或上传整首音频。
- Mac 使用 Jellyfin 返回的本机 `Path` 直接读取原视频，一次解码为 PCM/WAV，不再做二次 AAC 转码。
- Mac 先用 `python-audio-separator 0.44.5 + Kim_Vocal_2.onnx` 提取 vocals stem，再跑 Silero VAD；
  各 60 秒/重叠 5 秒腾讯分片从同一无损人声轨生成。
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

1. `ASR 识别歌词`：人工发起；每次先询问 Mac 的 fingerprint/SHA-256/分析版本缓存，成功后自动续跑 DeepSeek 并启用。
2. `DeepSeek 校准歌词`：必须先有 ASR；没有下载歌词时仍可用歌曲名 + ASR word timeline 整理，允许 `asr_only`。
3. `重新 ASR 识别`：强制重跑腾讯 ASR。
4. `重新 DeepSeek 校准`：只重跑 DeepSeek。
5. `采用腾讯 ASR 字幕` 和 `采用 DeepSeek 校准字幕`：保留两份结果的手工 A/B 和恢复入口，菜单明示当前来源。

播放、搜索普通歌词、切换歌词、单曲循环和重新进入播放器，都不得自动触发 ASR 或 DeepSeek。

显式发起的 ASR 链会在 DeepSeek 成功后自动替换并固定字幕，播放画面显示进度和结果。
DeepSeek 失败时保留当前字幕与 ASR；如果处理期间用户又手动选择，较新的手工意图优先。

## 优先级和持久化

- 固定的普通歌词与 ASR / DeepSeek 结果可以共存。
- 点击“采用”后，分析歌词优先；普通歌词不删除，仍可切换回去。
- ASR 和 DeepSeek 结果并列保存，任一份都可反复采用；DeepSeek 成功默认切到校准字幕。
- tvOS 当前副本保存在私有 Caches，Mac SQLite 保留可重建的 ASR / DeepSeek 服务端结果。Caches
  在空间不足且 App 未运行时可能被系统清除，不能称为永久保存；家长人工绑定丢失后当前仍可能需要重新选择。
- 已保存歌词内容、ASR 音频证据和原视频内容 SHA-256。
- 恢复服务端缓存前，Mac 会先核对原视频 SHA-256；一致时直接复用，不调用腾讯；内容变化才重新识别。
- ASR 缓存版本同时包含基础分析版本、分片时间线版本和 `60/5` 分片形状；旧的整首 v1 结果不会遮住新结果。
- Apple TV 的 ASR 证据哈希包含完整 word timeline 和 VAD 质量标记，新证据会使电视
  本地旧 DeepSeek 结果过期。服务端 D3 缓存也已绑定实际 ASR words/VAD 和候选内容哈希；
  2026-08-25 前的旧 evidence 缓存不再命中。
- 卸载 App 会清除结果；媒体确认删除后的清理逻辑还需后续验证。

## 本地测试环境

- Apple TV Debug 地址：`http://192.168.3.33:8011/v1`
- 持久启动：首次运行 `BabyPlayerASRServer/scripts/install-local-development-service.sh`，安装后由
  LaunchAgent `uk.wisteriasoftware.babyplayer-asr-local` 在登录时启动并在异常退出后自动拉起。
- 手工前台调试：`BabyPlayerASRServer/scripts/start-local-development.sh`
- 健康检查：`curl --fail http://127.0.0.1:8011/health`
- 服务状态：`launchctl print gui/$(id -u)/uk.wisteriasoftware.babyplayer-asr-local`
- 服务日志：`~/Library/Logs/BabyPlayerASR/`
- 本地数据库：`BabyPlayerASRServer/babyplayer-asr.local.sqlite3`
- 过程文件：`BabyPlayerASRServer/LyricsTestOutputs/`
- 本地任务接口：`POST /v1/local-analysis/jobs`，Apple TV 用 `GET /v1/local-analysis/jobs/{id}` 短轮询。
- 过程文件包括 Mac 提取的 `extracted_audio.m4a`、原始 `asr.srt`、门控后
  `asr_quality_filtered.srt`、`voice_activity.json`、`audio_preprocessing.json`、ASR JSON、
  候选歌词、DeepSeek 输入输出和 AI SRT。
- 只允许读取 `LOCAL_MEDIA_ROOTS` 白名单中的媒体；production 禁用本地路径接口。

### 本地质量依赖

```bash
cd BabyPlayerASRServer
.venv/bin/pip install -r requirements-local-quality.txt
.venv/bin/audio-separator -m Kim_Vocal_2.onnx \
  --model_file_dir .cache/audio-separator-models --download_model_only
./scripts/install-local-development-service.sh
curl --fail http://127.0.0.1:8011/health
```

健康检查应同时为 `voice_activity_configured=true`、
`vocal_separation_configured=true`、`vocal_separation_model_ready=true`。LaunchAgent
必须保留 `ProcessType=Interactive`；`Background` 会使这台 Mac 的 CoreML 分离慢约一个数量级。

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

## 当前验证

- tvOS 26.2 模拟器自动化测试：58 项通过，0 失败；真机需继续验证 AVKit 方向键焦点手感。
- Python 服务端：54 项通过，0 失败。
- Mac 服务健康，ASR 和 DeepSeek 已配置。
- `Rain Rain Go Away.mp4` 已验证：Mac 可直接提取 155 秒音频；旧 ASR 缓存补存视频哈希时腾讯用量增加 0 秒。
- 当前 Wheels 结果：157.171 秒、191 个 ASR words、末词 140.07 秒；用户明确确认开头
  “旋律 → 汽车声 → 节奏”均无人声，质量过滤和 DeepSeek 的首句都从 22.45 秒开始。
- Wheels 原 ASR 仍识别出 `BB/DD/Dee/E` 类分离残留，但这些词已被标记并排除于最终两份字幕。
- Wheels 真实 DeepSeek：32 行，`asr_word_coverage=0.9945`，`recovered_asr_word_count=0`；
  未覆盖的唯一项为没有实质文字的标点。
- 157 秒歌曲的分片计划为 `0–60 / 55–115 / 110–157`。
- 该歌新策略的月度内部计量为 `60 + 60 + ceil(47.184) = 168` 秒，相比单次 `ceil(157.184) = 158` 秒增加 10 秒（约 6.3%），共 3 次 Provider 请求。
- 腾讯把整分钟识别成一个 segment 时，Apple TV 会按词级时间拆成每行最多 6 词 / 30 字符 / 3.2 秒；没有 word timeline 时也会在 segment 时间内均匀分配，不再整段铺屏。
- 2026-08-24 实测“ASR 点了但没变”的直接原因是 Apple TV 发现本地旧 ASR 后直接返回，未询问 Mac 新版本缓存；该短路已取消。
- Baby Shark 新结果：417 个 ASR words，旧 7.60 秒伴奏幻觉消失，首词 12.55 秒；
  DeepSeek 92 行，`asr_word_coverage=1.0`，末句 176.99 秒。
- 分析等待发生在独立异步任务中，不暂停播放器，也不改变单曲循环。
- 2026-08-24 22:53 已再次覆盖安装并启动最新 Debug App 到“客厅”。
- Mac `8011` 已运行分片代码。
- 用户人工验证：Baby Shark 基本通过；Wheels 仍有不匹配，但 ASR 和 DeepSeek 闭环基本可用。
- 2026-08-25 第 67 首 `Who Took the Cookie?` 曾报 `-1004`：原因是 Mac `8011` 进程未运行，
  不是歌曲、音频提取或腾讯 ASR 失败。原 MP4 可成功提取 122.098 秒 M4A，原有
  ASR 缓存为 167 words，用户在服务恢复后已确认歌曲正常。本地服务现已改由 LaunchAgent 托管。
- `Who Took the Cookie?` 新人声轨 ASR 为 175 个词，0.50–120.35 秒；`He he`、`Bear`、
  `Kangaroo` 均保留。Web 候选稳定证据 ID 修复后 DeepSeek 31 行成功。
- D3 缓存现已绑定实际 ASR/VAD/候选哈希；模型乱序、重叠或单行无支持不再使整首 422，
  有声 ASR 空洞会自动回收并计入覆盖率。

## 下一步

1. 建立 10–20 首人工标注集；不必手工标注每一个无声帧，先标“人声区间 + 每句文字/首尾 + 段落类型/重复次数”即可。
2. Wheels 已确认 0–22.45 秒无人声；下一个人工点是 140.07–157.17 秒是否存在真实演唱。
3. 用同一标注集比较腾讯人声轨与 faster-whisper/WhisperX，评估第二 ASR 或可信歌词强制对齐，不再盲调 VAD 阈值。
4. 统一 ASR SRT、Apple TV ASR 和 DeepSeek 的 canonical cue/分行，并将尾段人声、重复次数和时间误差变为自动指标。
5. Apple TV 当前只会显示识别 1/1；真实分片进度只在 Mac 内部可见，属于待改进 UI。

## 安全约束

- 不输出或提交 Token、腾讯密钥、DeepSeek Key、`.env`、私密 xcconfig、本地 SQLite 或过程文件。
- 不删除 VPS，不修改 VPS 上的支付、翻译和其他服务。
- 不修改全局 `xcode-select`；构建时临时指定 `DEVELOPER_DIR`。
- 不得重置或覆盖用户已有改动；修改前先检查工作树并只处理当前任务范围。

关键代码：`SystemPlayerView.swift`、`LyricsRepository.swift`、`BabyPlayerASR.swift`、`local_analysis.py`、`service.py`、`development_artifacts.py`。
