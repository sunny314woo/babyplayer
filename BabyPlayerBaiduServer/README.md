# BabyPlayer 百度网盘独立服务

用途：承载 BabyPlayer 的设备绑定、百度 OAuth 和 Root Folder 协议。
主要功能：服务端保管百度凭证，给 Apple TV 与未来 Android 提供相同的版本化状态/目录接口。
最近修改：【MODIFIED】Phase 5 建立本地可测试闭环；真实百度授权与部署仍待开发者实名认证、应用审核及 Lightsail 地址。

## 边界

- 独立于 English Follow 的 `account-server`，使用自己的 MySQL 数据库、服务进程和密钥。
- 同一主机部署时使用独立目录 `/opt/babyplayer-baidu`、独立 systemd unit、独立数据库用户与库、独立 HTTPS 子域名；部署前在服务器核对端口占用。不得重启或改写 Outline 支付服务与 English Follow 服务。
- 每台设备单独生成高熵令牌；每台设备只绑定一个百度账号、一个 Root Folder。其他设备各自授权，数据不混用。
- 手机配置页放在官网的 `/babyplayer/connect.html`，不加入公开导航。链接内的 15 分钟配对码位于 URL fragment，不发给静态站点服务器。
- 设备/配对令牌在 MySQL 只存 SHA-256 摘要；百度 access/refresh token 和回跳配对码以 Fernet 加密。百度 Secret 只放服务端环境。
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

## Lightsail 部署前置

1. 百度开发者完成实名认证、创建 BabyPlayer 应用并确认 `basic,netdisk` scope、回调域名及个人应用的授权范围。网页 OAuth 的 `client_id` 对应 App Key；短数字 App ID 仅用于识别控制台应用，不能填入 `BABYPLAYER_BAIDU_CLIENT_ID`。
2. 确定 `babyplayer-api.wisteriasoftware.uk` 或替代域名，指向独立 Lightsail 常驻 FastAPI 服务并配置 HTTPS。
3. 在独立 MySQL 数据库执行 `schema.sql`。生产环境配置 `.env.example` 中的变量，生成 Fernet 密钥并保存在服务器；不提交 `.env`。例如 `python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'`。
4. 以 systemd 常驻运行 `uvicorn babyplayer_baidu.main:app --host 127.0.0.1 --port 8011`，由 Nginx 反代并限制配对接口速率。`GET /health` 用于探测。
5. 将官网私有页面部署后，使用真实百度账号做 OAuth、列目录、保存 Root、电视自动恢复测试。之后才进入 Phase 6 播放 Spike。

当前代码与静态页只在本地；百度授权入口预检已通过，但完整授权和目录读取尚未完成，现有 `ssh wisteria` 连接仍超时。未获得可访问服务器并完成真实闭环前，不能宣称已部署或已联机。电视上的已安装包仍为 Phase 2，不能扫码百度。

## 百度官方依据

- [OAuth 2.0 授权码流程](https://openauth.baidu.com/doc/doc.html)
- [百度网盘官方 Go SDK 的目录列表实现](https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/file_list.go)
- [百度网盘开放平台申请入口](https://yun.baidu.com/open/platform)
