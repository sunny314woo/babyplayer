# BabyPlayer ASR Server

这是 BabyPlayer 的独立 ASR 代理，与 EnglishFlow Account Server、翻译、TTS、支付和
Jellyfin 完全解耦。它可以部署在同一台 VPS，但使用独立目录、Linux 用户、systemd
进程、端口、SQLite 数据库、Bearer Token 和环境变量。

```text
/opt/babyplayer-asr                 独立程序与 .env
/var/lib/babyplayer-asr             独立 SQLite 数据库
babyplayer-asr.service              独立 systemd 服务
127.0.0.1:8011                      独立监听端口
player.wisteriasoftware.uk          独立子域名
```

同一 BabyPlayer 服务进程内有两个彼此独立的模块：

- ASR 模块保护腾讯密钥、执行每月 18,000 秒硬上限，并缓存腾讯返回的转写文字和时间戳。
- 歌词纠正模块调用 DeepSeek V4 Flash 的非思考模式，只纠正 ASR segment 文案。它不允许模型修改时间；响应时从腾讯 ASR 请求原数据重新附上时间边界。

服务不下载 Jellyfin 视频、不搜索歌词、不保存音频，也不持久化候选歌词或 DeepSeek 输出。

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
- `POST /v1/refine`：接收 ASR segments、最多 3 份网络候选纯文本和 1 份本地歌本，
  返回以原 ASR 时间戳为边界的纠正文案。

所有 `/v1/*` 请求使用独立的 `Authorization: Bearer ...`。达到 5 小时后，新的分析返回
HTTP 429、错误码 `MONTHLY_ASR_LIMIT_REACHED` 和北京时间的 `next_available_at`；已缓存
结果仍然可以读取。

## VPS 部署

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

腾讯云后付费仍应保持关闭。服务内 5 小时硬上限是第一道保护，腾讯控制台关闭后付费是
第二道保护。
