# BabyPlayer ASR Server

这是 BabyPlayer 的独立 ASR 代理，与 EnglishFlow Account Server、翻译、TTS、支付和
Jellyfin 完全解耦。它可以部署在同一台 VPS，但使用独立目录、Linux 用户、systemd
进程、端口、SQLite 数据库、Bearer Token 和环境变量。

## 当前开发状态

当前为个人内测的最小闭环：只有一台 Apple TV 使用这台 VPS，不提供用户系统、登录、
订阅、支付、家庭共享或多租户功能。接口和数据库仍保留独立 Bearer Token 边界，未来
增加逐设备 Token 或配对码时，可以在不影响腾讯 ASR、DeepSeek 校正和本地歌词逻辑的
前提下扩展。

```text
/opt/babyplayer-asr                 独立程序与 .env
/var/lib/babyplayer-asr             独立 SQLite 数据库
babyplayer-asr.service              独立 systemd 服务
127.0.0.1:8011                      独立监听端口
player.wisteriasoftware.uk          独立子域名
```

同一 BabyPlayer 服务进程内有三个边界清晰的模块：

- ASR 模块保护腾讯密钥、执行每月 18,000 秒硬上限，并缓存腾讯返回的转写文字和时间戳。
- 兼容歌词修复模块保留原 `/v1/refine` limited-repair contract，供新 D3 链路失败时回退。
- D3 Lyrics Evidence Reconciler 从服务端缓存读取 ASR，两阶段调用 DeepSeek 完成候选审查和最终 word-range 映射；必要时通过独立限域检索器获取新的候选证据。

服务不下载 Jellyfin 视频、不保存音频。网页候选只存在于当次请求内存；最终通过服务端验证的 AI Lyrics 会按媒体指纹和 reconciliation version 写入 SQLite 缓存。

## 本地运行

```bash
cd BabyPlayerASRServer
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --host 127.0.0.1 --port 8011
```

占位符未替换时 `/health` 正常，但 `provider_configured=false` 和/或
`lyrics_refiner_configured=false`，对应接口返回 503，不会调用腾讯或 DeepSeek。运行测试：

```bash
python -m pytest -q -p no:cacheprovider
```

## API

- `GET /health`：无需鉴权，只返回服务状态，不返回密钥。
- `GET /v1/usage`：查看本月已用、预留、剩余秒数和下次重置时间。
- `GET /v1/cache?media_fingerprint=...`：读取已有转写，缓存命中不消耗额度。
- `POST /v1/analyze`：上传 M4A/AAC/MP3；BabyPlayer 实际固定使用 M4A。
- `POST /v1/refine`：接收 `original_lines` 及其 `aligned_words`、ASR transcript 和集中计算的 evidence；返回 `line_identifier / original_text / suggested_text / should_modify / evidence / confidence`。响应 contract 不存在时间戳字段。
- `POST /v1/lyrics/reconcile`：D3 主接口。Apple TV 只传 `media_fingerprint`/`song_title`/最多 3 份候选；服务器读取 ASR 缓存，必要时限域检索，验证 DeepSeek 返回的 ASR word ranges 后生成最终时间。`force_refresh=true` 可忽略 AI Lyrics 缓存重新分析。

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
DeepSeek Key 只存在 VPS `.env`，Apple TV 继续只持有 BabyPlayer Bearer Token。
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
