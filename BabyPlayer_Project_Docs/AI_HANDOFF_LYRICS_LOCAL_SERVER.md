# BabyPlayer 歌词服务本地化：AI 接力文档

更新日期：2026-08-24（Asia/Shanghai）

适用仓库：`sunny314woo/babyplayer`

当前分支：`main`

本文档创建前的功能基线提交：`a4f5e73`

## 1. 接力任务

下一阶段要把目前运行在 VPS 的 BabyPlayer ASR/歌词 API 同时支持在 Mac 本地运行，用于
开发和真机测试。生产 VPS 必须继续保留，不能因为本地测试而中断。

目标不是把 DeepSeek 或腾讯 ASR 改成本地模型，而是把调用它们的 FastAPI 服务从 VPS
复制到 Mac 进程中运行：

```text
当前生产链路
Apple TV -> HTTPS/Nginx -> VPS FastAPI:8011 -> 腾讯 ASR / DeepSeek / 限域歌词检索

计划中的本地测试链路
Apple TV 或 tvOS Simulator -> Mac FastAPI:8011 -> 腾讯 ASR / DeepSeek / 限域歌词检索
```

生产与本地模式必须可明确切换；Release 默认始终使用 VPS，Debug 才允许选择本地服务。

## 2. 绝对安全规则

1. 不要在聊天、日志、提交、截图或测试输出中显示任何 Token、SecretId、SecretKey、
   DeepSeek API Key。
2. 真实配置位于 `BabyPlayerASRServer/.env`，文件权限为 `0600`，已被 Git 忽略。
3. Apple TV 只能持有 `BABYPLAYER_API_TOKEN`；腾讯和 DeepSeek 密钥只能留在服务端环境。
4. 不要提交 `Config/BabyPlayerSecrets.xcconfig`，它也已被 Git 忽略。
5. 不要把生产 SQLite 直接当作本地测试数据库写入。
6. 如果需要操作 VPS，只能重启 `babyplayer-asr.service`；服务器上还有支付和翻译服务。
7. 不要修改全局 `xcode-select`。需要命令行构建时临时使用：

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild ...
   ```

## 3. 仓库和关键路径

项目根目录：

```text
/Users/wufengyu/Projects/AppleTV-儿童播放器
```

关键文件：

| 范围 | 路径 | 职责 |
|---|---|---|
| tvOS ASR 客户端 | `BabyPlayer/BabyPlayerASR.swift` | `/usage`、`/cache`、`/analyze`，确定性对齐和 D3 调用编排 |
| tvOS DeepSeek 客户端 | `BabyPlayer/BabyPlayerLyricsRefiner.swift` | `/refine` 兼容链路和 `/lyrics/reconcile` D3 客户端 |
| tvOS UI 触发 | `BabyPlayer/SystemPlayerView.swift` | 自动分析、人工强制刷新、进度和重试 |
| App 网络配置 | `BabyPlayer/Info.plist` | 当前 API Base URL 和 Bearer Token plist key |
| 安全 Xcode 默认值 | `Config/BabyPlayer.xcconfig` | 可提交占位配置 |
| 本机 Xcode 私密值 | `Config/BabyPlayerSecrets.xcconfig` | 真实 BabyPlayer Token；禁止提交 |
| FastAPI 入口 | `BabyPlayerASRServer/app/main.py` | 鉴权、健康检查和所有 API 路由 |
| 环境配置 | `BabyPlayerASRServer/app/config.py` | `.env` 加载和默认值 |
| 数据库 | `BabyPlayerASRServer/app/database.py` | 用量、操作、ASR 缓存和 AI 歌词缓存 |
| 腾讯 ASR | `BabyPlayerASRServer/app/tencent_asr.py` | 腾讯一句话识别适配 |
| ASR 业务层 | `BabyPlayerASRServer/app/service.py` | 上传校验、配额、请求和缓存 |
| D3 编排 | `BabyPlayerASRServer/app/lyrics_reconciler.py` | 候选评估、检索门控、证据校验、ASR 时间映射 |
| DeepSeek D3 | `BabyPlayerASRServer/app/deepseek_lyrics_reconciler.py` | assessment 和 reconciliation 两阶段 JSON 调用 |
| 限域检索 | `BabyPlayerASRServer/app/lyrics_retriever.py` | Super Simple、Pinkfong、BabyBus、YouTube 候选检索 |
| 旧版回退 | `BabyPlayerASRServer/app/deepseek_refiner.py` | `/v1/refine` limited repair |
| VPS service | `BabyPlayerASRServer/ops/babyplayer-asr.service` | 独立 systemd 服务 |
| VPS Nginx | `BabyPlayerASRServer/ops/nginx-babyplayer-asr.conf.example` | 生产 HTTPS 反向代理 |
| 同步私密配置 | `BabyPlayerASRServer/scripts/download-vps-env.sh` | root SSH/SCP 下载 VPS `.env`，不打印密钥 |

与 D3 实施直接相关的提交：

```text
aecff5c  feat: add reusable D3 lyrics reconciliation pipeline
be14a49  ops: add secure VPS environment sync helper
a4f5e73  ops: sync VPS environment over root SSH
```

## 4. 当前服务地址

### 4.1 生产 VPS

| 用途 | 地址 |
|---|---|
| 外部健康检查 | `https://player.wisteriasoftware.uk/health` |
| tvOS API Base URL | `https://player.wisteriasoftware.uk/v1` |
| VPS FastAPI 内部地址 | `http://127.0.0.1:8011` |
| SSH alias | `hetzner`（root，密钥登录） |
| VPS 程序目录 | `/opt/babyplayer-asr` |
| VPS `.env` | `/opt/babyplayer-asr/.env` |
| VPS SQLite | `/var/lib/babyplayer-asr/babyplayer-asr.sqlite3` |
| systemd 服务 | `babyplayer-asr.service` |

Nginx 只负责 `player.wisteriasoftware.uk:443 -> 127.0.0.1:8011`。本地测试不需要修改
VPS Nginx，也不需要重启支付、翻译或其他服务。

### 4.2 计划中的 Mac 本地地址

| 客户端 | 建议地址 | 说明 |
|---|---|---|
| Mac 自检 | `http://127.0.0.1:8011` | `curl` 和 pytest |
| tvOS Simulator | `http://127.0.0.1:8011/v1` | Simulator 与 Mac 共用网络栈 |
| 物理 Apple TV | `http://<MAC_LAN_IP>:8011/v1` | 不能使用 Apple TV 自己的 `127.0.0.1` |
| 可选 Bonjour | `http://<MAC_HOSTNAME>.local:8011/v1` | 需要局域网 DNS 和 ATS 实测通过 |

物理 Apple TV 测试时 FastAPI 必须监听 `0.0.0.0:8011`，Mac 防火墙需要允许 Python/
uvicorn 接收入站连接。`<MAC_LAN_IP>` 可以在 Mac 上通过以下命令获取：

```bash
ipconfig getifaddr en0
```

如果 Mac 使用有线网络或其他接口，应先用 `networksetup -listallhardwareports` 找到正确接口。

## 5. 当前环境配置

### 5.1 私密配置文件

本地已存在与 VPS 内容校验一致的：

```text
BabyPlayerASRServer/.env
```

它包含以下已经配置的项目，但本文档故意不记录任何真实值：

- `BABYPLAYER_API_TOKEN`
- `TENCENT_ASR_APP_ID`
- `TENCENT_ASR_SECRET_ID`
- `TENCENT_ASR_SECRET_KEY`
- `DEEPSEEK_API_KEY`

重新从 VPS 同步：

```bash
cd "/Users/wufengyu/Projects/AppleTV-儿童播放器"
bash BabyPlayerASRServer/scripts/download-vps-env.sh
```

该命令必须在 Mac 上运行，不是在 VPS 内运行。

### 5.2 VPS `.env` 中已经明确设置的非密钥值

```dotenv
TENCENT_ASR_ENDPOINT=https://asr.cloud.tencent.com
TENCENT_ASR_ENGINE_TYPE=16k_en
TENCENT_ASR_MONTHLY_LIMIT_SECONDS=18000
TENCENT_ASR_MAX_AUDIO_SECONDS=300
TENCENT_ASR_MAX_AUDIO_BYTES=12582912
TENCENT_ASR_TIMEOUT_SECONDS=120
TENCENT_ASR_MAX_CONCURRENCY=2
TENCENT_ASR_REQUESTS_PER_MINUTE=3
ASR_ANALYSIS_VERSION=babyplayer-asr-v1
DATABASE_PATH=/var/lib/babyplayer-asr/babyplayer-asr.sqlite3
PRODUCT_ENV=production
```

当前真实 `.env` 没有显式写入以下 D3 参数，因此运行时使用 `config.py` 默认值：

```dotenv
DEEPSEEK_ENDPOINT=https://api.deepseek.com/chat/completions
DEEPSEEK_MODEL=deepseek-v4-flash
LYRICS_RECONCILIATION_VERSION=babyplayer-lyrics-d3-v1
LYRICS_WEB_SEARCH_ENABLED=true
LYRICS_WEB_SEARCH_TIMEOUT_SECONDS=8
LYRICS_WEB_SEARCH_MAX_RESULTS=3
```

注意：`.env.example` 当前写的是 `TENCENT_ASR_MAX_AUDIO_SECONDS=120` 和
`TENCENT_ASR_TIMEOUT_SECONDS=30`，而生产 `.env` 是 `300/120`。这是已知配置差异，不要
在本地化过程中顺手覆盖生产值；应单独决定示例值是否需要更新。

### 5.3 tvOS 当前配置

`BabyPlayer/Info.plist` 当前硬编码：

```text
BabyPlayerASRBaseURL = https://player.wisteriasoftware.uk/v1
BabyPlayerASRAPIToken = $(BABYPLAYER_ASR_API_TOKEN)
```

真实 Token 来自被忽略的 `Config/BabyPlayerSecrets.xcconfig`。当前
`BabyPlayerASRConfiguration` 和 `LyricsRefinerConfiguration` 都强制要求 URL scheme 为
`https`。因此只启动本地 HTTP 服务还不够，下一步必须增加安全的 Debug-only 本地地址
支持。

`Info.plist` 已包含 `NSAllowsLocalNetworking=true`，但仍需在 Simulator 和物理 Apple TV
分别验证 ATS 行为。不要在 Release 中开启全局 `NSAllowsArbitraryLoads`。

## 6. 歌词处理完整链路

1. tvOS 先从歌词源取得最多三份普通候选。
2. tvOS 使用稳定 `media_fingerprint` 请求 `GET /v1/cache`。
3. ASR 缓存未命中时，tvOS 临时导出整首 M4A 并调用 `POST /v1/analyze`。
4. VPS/Mac FastAPI 调用腾讯 ASR，保存 transcript、segments 和 word-level timestamps。
5. tvOS 先执行本地确定性歌词对齐，尽快产出 AI Lyrics v1。
6. tvOS 调用 `POST /v1/lyrics/reconcile`，只上传标题、媒体指纹和最多三份候选。
7. 服务端从自己的 ASR 缓存读取真实时间证据。
8. DeepSeek 第一阶段只判断候选质量和 `need_web_search`。
9. 仅当候选明显较差时，服务端限域检索新的歌词候选。
10. DeepSeek 最终只返回 `asr_word_start_index/asr_word_end_index`，不能返回最终时间戳。
11. 服务端验证索引单调、文本证据和来源后，从腾讯 ASR words 计算开始/结束时间。
12. 结果写入 `ai_lyrics_cache`。自动分析命中缓存；人工“重新分析 AI 歌词”使用
    `force_refresh=true`。
13. D3 失败时回退旧 `/v1/refine`；DeepSeek 失败不应破坏本地确定性歌词。

D3 自动应用门槛目前为 `song_match_confidence >= 0.72`。

## 7. API 契约

所有 `/v1/*` 路由都要求：

```http
Authorization: Bearer <BABYPLAYER_API_TOKEN>
```

| 方法 | 路径 | 作用 | 重要行为 |
|---|---|---|---|
| GET | `/health` | 健康检查 | 不需要鉴权，不返回密钥 |
| GET | `/v1/usage` | 月度 ASR 配额 | 本地新数据库也会有独立计数 |
| GET | `/v1/cache?media_fingerprint=...` | 查询 ASR 缓存 | 未命中返回 404 |
| POST | `/v1/analyze` | 上传音频并调用腾讯 ASR | multipart；受大小、时长、频率和月度限额约束 |
| POST | `/v1/refine` | 旧版有限文本修复 | 兼容回退，不拥有时间轴 |
| POST | `/v1/lyrics/reconcile` | D3 歌词证据重建 | 必须先有同指纹 ASR 缓存；否则返回 409 `ASR_CACHE_REQUIRED` |

## 8. 数据库与本地测试隔离

数据库表包括：

- `asr_usage_monthly`
- `asr_rate_windows`
- `asr_operations`
- `asr_analysis_cache`
- `ai_lyrics_cache`

同步下来的 `.env` 仍指向 VPS 路径 `/var/lib/babyplayer-asr/...`，这个路径不适合 Mac。
本地启动时必须用进程环境覆盖：

```bash
DATABASE_PATH="$PWD/babyplayer-asr.local.sqlite3"
PRODUCT_ENV=development
```

推荐使用全新的本地数据库，让 Apple TV 对测试歌曲重新做一次 ASR，这样能验证完整链路。
不要直接修改或上传本地 SQLite 到 VPS。若未来确实需要生产缓存快照，必须通过 SQLite
在线备份生成只读副本，不能在服务运行时直接复制 WAL 数据库文件。

## 9. 推荐实施方案

### 9.1 保持生产默认值

Release 的默认 Base URL 必须继续是：

```text
https://player.wisteriasoftware.uk/v1
```

### 9.2 为 Debug 增加可切换 Base URL

推荐把 Base URL 也变成 Xcode build setting：

- `Config/BabyPlayer.xcconfig` 保存可提交的生产默认 URL。
- `Config/BabyPlayerSecrets.xcconfig` 可选覆盖本机 Debug URL。
- `Info.plist` 的 `BabyPlayerASRBaseURL` 改为 `$(BABYPLAYER_ASR_BASE_URL)`。
- 注意 xcconfig 中 `//` 会被当作注释；URL 要使用 Xcode 可解析的转义写法并通过构建后的
  `Info.plist` 验证最终值，不能只看源文件。

更稳妥的长期方案是增加明确的 Debug 设置项，例如：

```text
生产 VPS
本地 Mac（Simulator）
本地 Mac（Apple TV 真机）
```

不要让 Release 从 UserDefaults 随意读取 HTTP 地址。

### 9.3 Debug-only HTTP 规则

当前两个 Swift 配置加载器都只接受 HTTPS。应抽出一个共享 URL 校验器：

- Release：只允许 `https`。
- Debug：可以允许 `http`，但 host 必须是 `localhost`、`127.0.0.1`、`.local`，或明确的
  RFC1918 局域网地址。
- 不允许 Debug 配置指向公网明文 HTTP。
- `BabyPlayerASRClient`、`BabyPlayerLyricsRefinerClient` 和
  `BabyPlayerLyricsReconcilerClient` 必须使用同一份解析结果。

### 9.4 启动本地服务

首次准备：

```bash
cd "/Users/wufengyu/Projects/AppleTV-儿童播放器/BabyPlayerASRServer"
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

启动时保留 `.env` 中的真实腾讯/DeepSeek 配置，只覆盖本地专用状态：

```bash
cd "/Users/wufengyu/Projects/AppleTV-儿童播放器/BabyPlayerASRServer"
source .venv/bin/activate
DATABASE_PATH="$PWD/babyplayer-asr.local.sqlite3" \
PRODUCT_ENV=development \
uvicorn app.main:app --host 0.0.0.0 --port 8011
```

这只是开发进程，不要在 Mac 上安装或启用 systemd/Nginx。

### 9.5 本地服务自检

```bash
curl --fail http://127.0.0.1:8011/health

cd "/Users/wufengyu/Projects/AppleTV-儿童播放器/BabyPlayerASRServer"
(
  set -a
  source .env
  set +a
  curl --fail \
    -H "Authorization: Bearer ${BABYPLAYER_API_TOKEN}" \
    http://127.0.0.1:8011/v1/usage
)
```

健康响应应满足：

```json
{
  "status": "ok",
  "provider_configured": true,
  "lyrics_refiner_configured": true
}
```

### 9.6 测试顺序

1. `python3 -m pytest -q -p no:cacheprovider`。
2. tvOS Simulator 使用 `127.0.0.1:8011/v1` 验证 `/health`、`/usage` 和缓存未命中。
3. Simulator 播放一首短歌，验证 `/analyze -> /lyrics/reconcile`。
4. 同一首歌第二次请求必须返回 `cache_hit=true`。
5. 再配置 Mac LAN IP，在物理 Apple TV 上完成同样测试。
6. 停止本地 uvicorn 或切回生产配置后，确认 VPS 链路仍正常。
7. 最后运行 tvOS 全量测试和真机构建。

## 10. 验收标准

- Release 仍固定使用生产 HTTPS 地址。
- Debug 能显式选择本地地址，不需要修改源代码中的字符串。
- Simulator 和物理 Apple TV 都能访问本地 `/health` 和 `/v1/usage`。
- 本地数据库路径位于项目的忽略文件中，不访问 `/var/lib`。
- 腾讯和 DeepSeek 密钥没有进入 App bundle、Git diff 或日志。
- 新歌首次分析实际调用腾讯 ASR，D3 时间仍完全来自 ASR word indices。
- 第二次分析命中 ASR/AI 歌词缓存。
- 人工刷新会设置 `force_refresh=true`。
- 本地服务停止后可以一键切回 VPS。
- `git diff --check`、服务端 23 项测试、tvOS 测试全部通过。
- 不重启或修改 VPS 的支付、翻译及其他服务。

## 11. 已知陷阱

1. 物理 Apple TV 的 `127.0.0.1` 指向 Apple TV 自己，不是 Mac。
2. FastAPI 若只监听 `127.0.0.1`，物理 Apple TV 无法连接。
3. 当前 Swift 代码强制 HTTPS，未修改前本地 HTTP 会被判断为未配置。
4. `NSAllowsLocalNetworking` 不等于可以跳过所有 ATS 校验，必须做真机测试。
5. 从 VPS 同步的 `.env` 是生产配置快照，其中数据库绝对路径不能直接用于 Mac。
6. D3 请求在本地新数据库上必须先完成 `/v1/analyze`，否则 409 是正确行为。
7. DeepSeek API 本身不主动浏览网页；联网候选由 `lyrics_retriever.py` 在服务端执行。
8. 原候选歌词 timestamp 不可信；任何改造都不能让 DeepSeek 直接生成最终 timestamp。
9. 相同副歌在不同 ASR 位置是不同演唱实例，不能文本去重。
10. 不要为了本地测试修改生产 Nginx、systemd 或防火墙规则。

## 12. 当前已验证基线

在 2026-08-24 的物理 Apple TV“客厅”上，生产 D3 已真实运行：

- 歌曲：《Five Little Ducks》
- 模型：`deepseek-v4-flash`
- `song_match_confidence=0.95`
- 输出 32 行，丢弃 4 行不支持候选
- `web_search_used=false`
- ASR ranges 单调且有界
- 第二次同请求 `cache_hit=true`

服务端自动化测试当前为 23 项通过；tvOS 全量测试基线为 37 项通过。

## 13. 给下一位 AI 的提示词

### 提示词 A：直接实施本地服务模式

```text
请先完整阅读：
BabyPlayer_Project_Docs/AI_HANDOFF_LYRICS_LOCAL_SERVER.md

然后在 BabyPlayer 项目中实施“VPS 歌词服务的本地 Debug 模式”。要求：
1. Release 始终默认 https://player.wisteriasoftware.uk/v1；
2. Debug 可以安全切换到 tvOS Simulator 的 127.0.0.1:8011，或物理 Apple TV 可访问的 Mac 局域网地址；
3. HTTP 仅在 DEBUG 且仅对 loopback/.local/RFC1918 地址开放，Release 继续强制 HTTPS；
4. Base URL 不再硬编码成只能使用 VPS，ASR、旧 refine、D3 reconcile 必须共用同一配置；
5. 本地 FastAPI 使用 BabyPlayerASRServer/.env 中已有密钥，但 DATABASE_PATH 必须覆盖到本地被 Git 忽略的 SQLite，PRODUCT_ENV=development；
6. 不显示、复制或提交任何真实密钥；
7. 不修改或重启 VPS 的支付、翻译和其他服务；
8. 先审查现有代码，再规划、实现、补测试，并完成 Simulator 与真机可达性验证；
9. 验证首次请求真实执行 ASR+D3，第二次命中缓存，最终 timestamp 仍只由 ASR word indices 计算；
10. 完成后列出改动文件、测试结果、当前使用的本地地址和一键切回 VPS 的方法。
```

### 提示词 B：只诊断本地连接，不改代码

```text
请阅读 BabyPlayer_Project_Docs/AI_HANDOFF_LYRICS_LOCAL_SERVER.md，只诊断当前 BabyPlayer 为什么无法连接 Mac 本地歌词服务，不要修改文件。

依次核查：uvicorn 是否监听 0.0.0.0:8011、Mac 本机 /health、Mac LAN IP、Apple TV 与 Mac 是否同网段、Mac 防火墙、构建后 Info.plist 的 BabyPlayerASRBaseURL、Swift 是否拒绝 http、ATS、本地 Bearer Token 是否与 BabyPlayerASRServer/.env 一致。不要打印 Token，只报告每项通过/失败、证据和最小修复建议。
```

### 提示词 C：端到端歌词验收

```text
请根据 BabyPlayer_Project_Docs/AI_HANDOFF_LYRICS_LOCAL_SERVER.md，对本地歌词服务做一次真实端到端验收。优先使用一首短儿童歌曲。

验证顺序：/health -> /v1/usage -> /v1/cache -> 必要时 /v1/analyze -> /v1/lyrics/reconcile -> 第二次 reconcile 缓存命中。检查 DeepSeek 返回的每行 ASR word range 单调、有界，服务器计算的 start/end 与 ASR words 一致；检查重复副歌没有被去重；记录 confidence、行数、discarded 数、web_search_used 和 cache_hit，但不要输出完整歌词或任何密钥。不要操作 VPS 的其他服务。
```

### 提示词 D：安全切回生产 VPS

```text
请阅读 BabyPlayer_Project_Docs/AI_HANDOFF_LYRICS_LOCAL_SERVER.md，把 BabyPlayer 从本地 Debug 歌词服务安全切回生产 VPS。

要求 Release 和当前真机包使用 https://player.wisteriasoftware.uk/v1；确认构建后的 Info.plist 值正确；确认 https://player.wisteriasoftware.uk/health 正常；重新构建并安装 Apple TV；停止本地 uvicorn。不得把本地 SQLite 上传 VPS，不得提交 .env 或 BabyPlayerSecrets.xcconfig，不得重启支付或翻译服务。
```

## 14. 下一位 AI 开始前的最短检查

```bash
cd "/Users/wufengyu/Projects/AppleTV-儿童播放器"
git status --short
git pull --ff-only origin main
git check-ignore BabyPlayerASRServer/.env Config/BabyPlayerSecrets.xcconfig

cd BabyPlayerASRServer
stat -f 'mode=%Sp bytes=%z' .env
python3 -m pytest -q -p no:cacheprovider
```

如果上述任一步会显示密钥内容，应立即停止并改用只报告存在性、权限或校验结果的命令。
