# BabyPlayer ASR Server

这是与 Jennifer/Jellyfin 运行在同一台 Mac 上的 BabyPlayer 本地 AI 服务。它负责腾讯 ASR、
DeepSeek、中文字幕和结果缓存，固定监听 `8011`；Apple TV 不通过 VPS 处理这些任务。

## 当前开发状态

当前为个人内测的最小闭环：只有一台 Apple TV 使用，不提供用户系统、登录、订阅、支付、
家庭共享或多租户功能。Debug 与 Release 使用同一条 Mac 局域网路径：

| 场景 | Apple TV 提交内容 | 音频处理位置 | 服务地址 |
| --- | --- | --- | --- |
| Debug / Release | Jellyfin 本机 Path、指纹、歌曲范围 | Mac 读取白名单内原视频，60 秒分片、重叠 5 秒 | 当前 Jellyfin 主机的 `:8011/v1` |

Apple TV 不读取固定 Base URL。若当前 Jellyfin 为 `http://192.168.1.14:8096`，客户端会自动把
ASR、DeepSeek 和翻译地址构造成 `http://192.168.1.14:8011/v1`，并使用
`/v1/local-analysis/jobs`。代码不允许静默回退到 VPS。

```text
/opt/babyplayer-asr                 独立程序与 .env
/var/lib/babyplayer-asr             独立 SQLite 数据库
babyplayer-asr.service              独立 systemd 服务
127.0.0.1:8011                      独立监听端口
player.wisteriasoftware.uk          独立子域名
```

同一 BabyPlayer 服务进程内有四个边界清晰的模块：

- ASR 模块保护腾讯密钥、执行每月 18,000 秒硬上限，并缓存腾讯返回的转写文字和时间戳。
- 兼容歌词修复模块保留原 `/v1/refine` limited-repair contract，供新 D3 链路失败时回退。
- D3 Lyrics Evidence Reconciler 从服务端缓存读取 ASR，两阶段调用 DeepSeek 完成候选审查和最终 word-range 映射；必要时通过独立限域检索器获取新的候选证据。
- 非 production 的 Mac 本地任务模块只读取 `LOCAL_MEDIA_ROOTS` 白名单内文件，计算原视频
  SHA-256、提取音频、分片并把进度保存在内存任务表中。

生产 `/v1/analyze` 服务不下载 Jellyfin 视频，也不持久化上传音频。Mac 开发任务会直接读取
Jellyfin 本机 Path；如果显式启用过程文件，会把提取音频、ASR/DeepSeek JSON 和 SRT 保存到
本机调试目录。网页候选只存在于当次请求内存；最终通过服务端验证的 AI Lyrics 会写入 SQLite。

当前 D3 缓存键已同时绑定媒体指纹、reconciliation version、ASR 算法版本、
实际 ASR word timeline/VAD 标记哈希和候选歌词哈希。同一算法版本下强制重跑 ASR
或更换候选后，普通 DeepSeek 请求也不会再复用旧 word ranges。历史根因和审查见
[`../BabyPlayer_Project_Docs/SMART_LYRICS_AUTO_SUBTITLE_AUDIT_2026-08-24.md`](../BabyPlayer_Project_Docs/SMART_LYRICS_AUTO_SUBTITLE_AUDIT_2026-08-24.md)。

## 本地运行

```bash
cd BabyPlayerASRServer
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-local-quality.txt
.venv/bin/audio-separator -m Kim_Vocal_2.onnx \
  --model_file_dir .cache/audio-separator-models --download_model_only
cp .env.example .env
uvicorn app.main:app --host 0.0.0.0 --port 8011
```

`Kim_Vocal_2.onnx` 约 66.8 MB，只保存在已被 Git 忽略的
`.cache/audio-separator-models/`。不要将模型、`.env`、SQLite 或开发输出提交到 Git。

占位符未替换时 `/health` 正常，但 `provider_configured=false` 和/或
`lyrics_refiner_configured=false`，对应接口返回 503，不会调用腾讯或 DeepSeek。

运行测试时不要让本机 `.env` 的生产 `DATABASE_PATH` 污染测试。使用临时 SQLite：

```bash
TEST_DATABASE_DIR="$(mktemp -d)"
DATABASE_PATH="$TEST_DATABASE_DIR/test.sqlite3" PRODUCT_ENV=test \
  python -m pytest -q -p no:cacheprovider
```

当前结果：63 项通过。测试目录只包含本次 SQLite，可在完成后删除。

### Mac 本地开发

推荐首次配置后将服务安装为当前 Mac 用户的 LaunchAgent：

```bash
cd BabyPlayerASRServer
./scripts/install-local-development-service.sh
launchctl print gui/$(id -u)/uk.wisteriasoftware.babyplayer-asr-local
curl --fail http://127.0.0.1:8011/health
```

安装脚本不会复制或显示 `.env`；LaunchAgent 仍通过项目内的
`start-local-development.sh` 加载本地配置。它会在用户登录时启动，进程异常退出后自动拉起；
日志保存在 `~/Library/Logs/BabyPlayerASR/`。只需临时前台调试时，可改用：

```bash
BabyPlayerASRServer/scripts/start-local-development.sh
```

本地 `.env` 至少需要正确设置 `LOCAL_MEDIA_ROOTS`、`LOCAL_FFMPEG_PATH`、本地数据库和开发
过程目录。`PRODUCT_ENV=production` 会关闭本地 Path 接口；生产部署必须使用精确的
`production`，不要使用容易误拼的自定义名称。

Apple TV 的 `-1004` 表示连不上 Mac `8011`，不是腾讯 ASR 识别拒绝。先检查
`launchctl print`、Mac 的 `8011` 健康接口、防火墙和两台设备是否在同一局域网。Mac DHCP
地址变化后，只更新 Apple TV 的 Jellyfin `:8096` 地址；AI 会自动跟随同一主机，不修改
`BabyPlayerSecrets.xcconfig`，也不重新编译 Base URL。

### Mac 人声分离与活动质量层

Mac 的 Debug 与 Release 都执行以下 `:8011/v1` 路径：

```text
完整原视频（不受家长片头/片尾秒数裁剪）
  → 一次解码为 44.1 kHz PCM/WAV
  → python-audio-separator 0.44.5 + Kim_Vocal_2.onnx 提取 vocals stem
  → faster-whisper 内置 Silero VAD v6 分析人声轨
  → Voice Window Planner 过滤短噪声、合并短 gap 并增加首尾 safety padding
  → 只在规划的人声窗口内复用腾讯 60/5 分片与原 offset 时间轴
```

这一路径不下载 Whisper 转写模型。`/health` 应同时显示
`voice_activity_configured=true`、`sparse_asr_configured=true`、
`vocal_separation_configured=true` 和
`vocal_separation_model_ready=true`。任一项为 false 都应先修复本机依赖，不要继续消耗腾讯额度。

具体规则：

- 人声覆盖率低于 0.03 且平均概率低于 0.05 时，返回 `NO_VOCALS_DETECTED`，不调腾讯。
- 每个 ASR word 保存 `voice_activity_score`、`voice_activity_coverage` 和 `quality_flags`；
  整体响应另存 `audio_preprocessing`。
- Planner 失败、没有可信窗口或窗口越界时自动回到原完整歌曲 ASR；失败只会少省额度，
  不会让现有歌词链路失效。
- `voice_window_plan` 返回原始人声秒数、实际提交秒数、节省秒数和保守的片头/片尾候选；
  当前阶段不改变播放器跳过行为。
- 连续至少 3 个词同时低于 0.15 分数且活动覆盖低于 0.25 时，标为
  `possible_instrumental_hallucination`。
- vocals stem 仍可泄漏短促音高；弱分数、短覆盖的 `BB/DD/Dee/E` 类残留会被额外标记，
  `He he`、`Bear` 和常见短词不会因此被删除。
- Apple TV 原始 ASR 字幕隐藏无声学依据的风险词；DeepSeek 也不能把它们作为 ASR-only 歌词。
- 开发输出保留 `asr.srt`、`asr_quality_filtered.srt`、`voice_activity.json`、
  `audio_preprocessing.json` 和 DeepSeek `ai.srt`。

Apple Silicon 分离一首 2–3 分钟儿歌需约 1–2 分钟，峰值内存约 5–6 GB；模型加载后会保留在进程中供后续歌曲复用。
LaunchAgent 必须使用 `ProcessType=Interactive`，否则这台 Mac 上的 CoreML 可被 Background QoS 降速约一个数量级。
这是 Mac 播放前离线质量路径，不在 Apple TV 上执行，也不依赖 VPS。

## API

- `GET /health`：无需鉴权，只返回服务状态，不返回密钥。
- `GET /v1/usage`：查看本月已用、预留、剩余秒数和下次重置时间。
- `GET /v1/cache?media_fingerprint=...`：读取已有转写，缓存命中不消耗额度。
- `POST /v1/analyze`：上传 M4A/AAC/MP3；BabyPlayer 实际固定使用 M4A。
- `POST /v1/refine`：接收 `original_lines` 及其 `aligned_words`、ASR transcript 和集中计算的 evidence；返回 `line_identifier / original_text / suggested_text / should_modify / evidence / confidence`。响应 contract 不存在时间戳字段。
- `POST /v1/lyrics/reconcile`：D3 主接口。Apple TV 只传 `media_fingerprint`/`song_title`/最多 3 份候选；服务器读取 ASR 缓存，必要时限域检索，验证 DeepSeek 返回的 ASR word ranges 后生成最终时间。乱序/重叠/无支持模型行被确定性舍弃，未覆盖但有人声证据的 ASR 词会自动回收。响应包含 `asr_word_coverage` 和 `recovered_asr_word_count`。`force_refresh=true` 可忽略 AI Lyrics 缓存重新分析。
- `POST /v1/local-analysis/jobs`：仅非 production。提交 Jellyfin 本机 Path 和歌曲范围，立即返回可轮询的 job ID；不接收 Apple TV 音频。
- `GET /v1/local-analysis/jobs/{job_id}`：仅非 production。读取提取、识别、完成或失败状态。当前 Apple TV UI 会把识别阶段统一显示为 1/1，不会显示 Mac 内部真实分片序号。

D3 的可复用边界：

- `lyrics_reconciler.py`：纯编排/校验服务，不依赖 FastAPI 或 DeepSeek 传输层；
- `deepseek_lyrics_reconciler.py`：候选评估 + 最终重建两阶段 JSON 适配器；
- `lyrics_retriever.py`：HTTPS/域名/超时/响应大小均受限的候选证据检索器；
- `AsrRepository`：ASR 和最终 AI Lyrics 分表缓存。

所有 `/v1/*` 请求使用独立的 `Authorization: Bearer ...`。达到 5 小时后，新的分析返回
HTTP 429、错误码 `MONTHLY_ASR_LIMIT_REACHED` 和北京时间的 `next_available_at`；已缓存
结果仍然可以读取。

## VPS 部署

服务代码、systemd、Nginx 示例和部署脚本应提交到 Git；真实 `.env` 只保存在 VPS 和
本机被忽略的私密副本中。需要把 VPS 当前配置安全同步到 Mac 时，在项目根目录运行：

```bash
bash BabyPlayerASRServer/scripts/download-vps-env.sh
```

脚本默认使用本机 SSH 配置中的 `hetzner`（root 密钥登录），直接通过 SCP 将
`/opt/babyplayer-asr/.env` 下载为本地 `BabyPlayerASRServer/.env`（权限 `0600`），并
验证必要配置项。已有本地 `.env` 会先备份；`.env`、下载临时文件和备份文件均被 Git
忽略，脚本不会显示任何密钥内容。也可以把其他 SSH host alias 作为第一个参数传入。

把本目录上传到新的 release 目录后执行：

```bash
sudo bash scripts/deploy-vps-release.sh /home/wisteria/babyplayer-asr-release-TIMESTAMP
```

第一次部署只写入 `XX_...` 占位符。稍后由你在 VPS 终端执行：

```bash
sudo bash /opt/babyplayer-asr/scripts/configure-vps-secrets.sh
```

脚本会静默读取 SecretId、SecretKey、独立 BabyPlayer Token 和 DeepSeek API Key，不回显
任何真实值。VPS 已有通配符证书，为 `player.wisteriasoftware.uk` 安装独立
Nginx 站点：

```bash
sudo bash /opt/babyplayer-asr/scripts/configure-nginx-player.sh
```

本地 Xcode 工程已把域名写成可提交配置。不要修改 `Info.plist` 写入真实 Token；而是复制：

```bash
cp Config/BabyPlayerSecrets.xcconfig.example Config/BabyPlayerSecrets.xcconfig
```

然后只在被 Git 忽略的 `BabyPlayerSecrets.xcconfig` 中替换 `XX_BABYPLAYER_API_TOKEN`。
当前 Apple TV 不使用本节 VPS 部署。日常本地运行时，DeepSeek Key 只存在 Mac 项目内被忽略的
`.env`，Apple TV 继续只持有 BabyPlayer Bearer Token。
对于腾讯 ASR 已经配置好的服务器，可以只补 DeepSeek Key，不重新输入其他凭据：

```bash
sudo bash /opt/babyplayer-asr/scripts/configure-deepseek-key.sh
```

如果忘记了之前生成的独立 BabyPlayer Token，可只轮换这一项，不触碰腾讯或 DeepSeek
配置：

```bash
sudo bash /opt/babyplayer-asr/scripts/configure-babyplayer-token.sh
```

然后把同一把 Token 写入 Mac 本地、被 Git 忽略的
`Config/BabyPlayerSecrets.xcconfig`；不要把腾讯 SecretId/SecretKey 或 DeepSeek Key
写入 Apple TV 工程。

腾讯云后付费仍应保持关闭。服务内 5 小时硬上限是第一道保护，腾讯控制台关闭后付费是
第二道保护。

## 当前质量与运维限制

- 当前是完整文件批处理，不是实时字幕：提取、全部腾讯分片和 DeepSeek 都完成后才返回最终结果。
- 腾讯仍使用通用英文 `16k_en`；Mac 已有人声分离和 vocals-stem VAD，但还没有歌声专用活动检测、
  腾讯真实词置信度或第二 ASR 回退。
- Mac 已改为一次 PCM/WAV 解码，每个分片都从同一无损人声轨编码。
- DeepSeek 遗漏的有声 ASR 词现会自动回收；但尾段实际人声、重复副歌数量和词时间误差仍需人工标注集验收。
- `LyricsTestOutputs` 包含完整音频和歌词内容，虽已被 Git 忽略，仍需定期清理并限制本机访问。
- 本地 job 只保存在当前进程内存；服务重启后 Apple TV 不能继续轮询旧 job，但已完成的 SQLite
  ASR 缓存仍可按指纹查询。
- SQLite 和共享 Bearer Token 只适合当前个人部署。公开分发前需要逐设备 Token、任务持久化和权限隔离。
