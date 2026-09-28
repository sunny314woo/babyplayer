# BabyPlayer 百度网盘独立服务

用途：承载 BabyPlayer 的设备绑定、百度 OAuth 和 Root Folder 协议。
主要功能：服务端保管百度凭证，给 Apple TV 与未来 Android 提供相同的版本化状态/目录接口。
最近修改：【MODIFIED】2026-09-28 确认 Hetzner 为正式承载服务器，废弃旧 Lightsail 部署要求。

## 边界

- 独立于 English Follow 的 `account-server`，使用自己的 MySQL 数据库、服务进程和密钥。
- 同一主机部署时使用独立目录 `/opt/babyplayer-baidu`、独立 systemd unit、独立数据库用户与库、独立 HTTPS 子域名；部署前在服务器核对端口占用。不得重启或改写 Outline 支付服务与 English Follow 服务。
- 每台设备单独生成高熵令牌；每台设备只绑定一个百度账号、一个 Root Folder。其他设备各自授权，数据不混用。
- 手机配置页放在官网的 `/babyplayer/connect.html`，不加入公开导航。链接内的 15 分钟配对码位于 URL fragment，不发给静态站点服务器。
- 设备/配对令牌在 MySQL 只存 SHA-256 摘要；百度 access/refresh token 和回跳配对码以 Fernet 加密。百度 Secret 只放服务端环境。
- 【MODIFIED】OAuth 回调 URL 会带短时 code/state；专属 Nginx 站点关闭访问日志，Uvicorn 使用 `--no-access-log`，避免把它们写入日志。API 响应统一 `Cache-Control: no-store`。
- 此服务不代理视频，不缓存或下载视频。正式播放链必须等独立 Spike 验证 Range、302、seek 和连续播放。

## API v1

| 请求 | 认证 | 用途 |
| --- | --- | --- |
| `POST /v1/pairings` | 首次无；重连用 `Bearer <device_token>` | 生成 15 分钟配置链接；仅首次返回设备令牌 |
| `GET /v1/pairings/me` | `Pairing <pairing_code>` | 手机查询授权/选目录状态 |
| `POST /v1/oauth/start` | `Pairing <pairing_code>` | 获取百度授权地址及单次 state |
| `GET /v1/oauth/callback` | 百度 code + state | 换令牌，加密存储，跳回手机页 |
| `GET /v1/pairings/folders?path=/...` | `Pairing <pairing_code>` | 手机逐层读取文件夹 |
| `POST /v1/pairings/root` | `Pairing <pairing_code>` | 验证并保存 `path` + `fs_id` |
| `GET /v1/devices/me` | `Bearer <device_token>` | `unconfigured/offline/online` 与 Root Folder |
| `GET /v1/devices/folders?path=/...` | `Bearer <device_token>` | Root Folder 以下的文件夹/视频模型 |

返回目录项的稳定字段为 `id`、`name`、`path`、`kind`、`size`，`kind` 为 `folder` 或 `video`。`root_folder` 为 `{id,path}`。未来 Android 可直接复用这些字段。目录层级没有产品限制。无视频播放 URL API 是刻意的：Phase 6 Spike 未通过前不写正式播放接口。

## 本地验证

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest tests -q
```

测试用可替换的百度网关和内存存储运行，不要求真实账号或密码。涵盖 OAuth 回调、Root Folder、旧配置恢复、未配置/离线、授权失效、目录删除、越界目录、短时配对过期与设备隔离。**这不是百度真实 API 验收。**

## Hetzner 部署与验证

【MODIFIED】服务器决策：用户已确认原 Amazon Lightsail 服务器停用。BabyPlayer 与 Outline、English Follow 共用现有 Hetzner 主机 `license-prod`，但使用独立 `/opt/babyplayer-baidu`、MySQL 库/用户、systemd unit、`127.0.0.1:8012` 和 HTTPS 子域名。旧文档中的 Lightsail 描述均为已废弃的历史计划，不再作为部署目标。

1. 百度开发者完成实名认证、创建 BabyPlayer 应用并确认 `basic,netdisk` scope、回调域名及个人应用的授权范围。网页 OAuth 的 `client_id` 对应 App Key；短数字 App ID 仅用于识别控制台应用，不能填入 `BABYPLAYER_BAIDU_CLIENT_ID`。
2. `babyplayer-api.wisteriasoftware.uk` 指向现有 Hetzner 主机的独立 BabyPlayer Nginx 站点并启用 HTTPS。
3. 在独立 MySQL 数据库执行 `schema.sql`。生产环境配置 `.env.example` 中的变量，生成 Fernet 密钥并保存在服务器；不提交 `.env`。例如 `python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'`。
4. 以独立 systemd unit 常驻运行 `uvicorn babyplayer_baidu.main:app --host 127.0.0.1 --port 8012`，由专属 Nginx 站点反代。`GET /health` 用于探测。`8011` 是已有 BabyPlayer ASR，不能占用。
5. 将官网私有页面部署后，使用真实百度账号做 OAuth、列目录、保存 Root、电视自动恢复测试。之后才进入 Phase 6 播放 Spike。

【MODIFIED】2026-09-28 已在现有服务器创建独立 `/opt/babyplayer-baidu`、专属 MySQL 库/用户、`babyplayer-baidu.service` 与 HTTPS 站点。公网 `/health` 返回 200；真实 MySQL 的未配置设备配对状态已通过。官网私有页已由独立网站发布仓库同步并从正式域名验证。Outline `8000`、English Follow `8010`、ASR `8011` 和 BabyPlayer `8012` 四个服务均保持 active。电视 Phase 5 Release 包已用原账号重新签名、安装并启动；完整百度 OAuth、目录选择及播放仍需真实设备验收。

## 百度官方依据

- [OAuth 2.0 授权码流程](https://openauth.baidu.com/doc/doc.html)
- [百度网盘官方 Go SDK 的目录列表实现](https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/file_list.go)
- [百度网盘开放平台申请入口](https://yun.baidu.com/open/platform)
