# BabyPlayer ASR Server

> 【MODIFIED】2026-08-23：冻结版本 B 后，本服务只负责腾讯 ASR。歌词搜索、候选比较、绑定、文本判断和校时全部留在 Apple TV 本地，不再提供 LLM/refine 服务。

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

服务只保护腾讯 ASR 凭据、执行每月 18,000 秒硬上限，并缓存腾讯返回的转写文字和句/词时间戳。
它不下载 Jellyfin 视频、不搜索歌词、不接收候选歌词、不保存原始音频，也不调用任何 LLM。

## 本地运行

```bash
cd BabyPlayerASRServer
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --host 127.0.0.1 --port 8011
```

占位符未替换时 `/health` 正常，但 `provider_configured=false`，分析接口返回 503，
不会调用腾讯。运行测试：

```bash
python -m pytest -q -p no:cacheprovider
```

## API

- `GET /health`：无需鉴权，只返回服务状态和月度硬上限，不返回敏感配置。
- `GET /v1/usage`：查看本月已用、预留、剩余秒数和下次重置时间。
- `GET /v1/cache?media_fingerprint=...`：读取已有转写，缓存命中不消耗额度。
- `POST /v1/analyze`：上传 M4A/AAC/MP3；BabyPlayer 实际固定使用 M4A。

【MODIFIED】旧 `/v1/refine` 已移除。所有 `/v1/*` 请求使用 BabyPlayer 自己的独立 Bearer
Token。达到 5 小时后，新的分析返回 HTTP 429、错误码 `MONTHLY_ASR_LIMIT_REACHED` 和
北京时间的 `next_available_at`；已缓存结果仍然可以读取。

## 缓存与额度

服务端按以下顺序保护额度：

1. 先按 `media_fingerprint` 查询当前 analysis version 的缓存。
2. 新上传进入服务后再按音频 SHA-256 查询同内容缓存。
3. 两层缓存都未命中时，才在 SQLite 事务中原子预留本次识别秒数。
4. 腾讯成功后把预留转成已用；失败则释放预留。
5. `used_seconds + reserved_seconds` 永远不能超过 18,000 秒。

因此同一首歌的重复播放、相同音频换了媒体指纹等情况不会重复消耗腾讯 ASR 额度。

## VPS 部署

把本目录上传到新的 release 目录后执行：

```bash
sudo bash scripts/deploy-vps-release.sh /home/wisteria/babyplayer-asr-release-TIMESTAMP
```

第一次部署只写入 `XX_...` 占位符。需要配置或轮换 BabyPlayer ASR 自己的凭据时，在 VPS
终端执行：

```bash
sudo bash /opt/babyplayer-asr/scripts/configure-vps-secrets.sh
```

脚本通过关闭终端回显的交互输入更新独立 ASR 配置，不输出真实敏感值，也不会读取或修改
EnglishFlow/account-server 的环境变量。

VPS 已有通配符证书时，可为 `player.wisteriasoftware.uk` 安装独立 Nginx 站点：

```bash
sudo bash /opt/babyplayer-asr/scripts/configure-nginx-player.sh
```

本地 Xcode 工程已把域名写成可提交配置。不要修改 `Info.plist` 写入真实 Token；而是复制：

```bash
cp Config/BabyPlayerSecrets.xcconfig.example Config/BabyPlayerSecrets.xcconfig
```

然后只在被 Git 忽略的 `BabyPlayerSecrets.xcconfig` 中替换占位值。真实文件不能提交。

腾讯云控制台的消费保护仍应保持。服务内 5 小时硬上限是应用层第一道保护，云端账户限制是
第二道保护。
