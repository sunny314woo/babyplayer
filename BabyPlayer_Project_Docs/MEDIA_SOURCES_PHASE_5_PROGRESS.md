# Phase 5 进度：百度授权与 Root Folder

用途：记录 Phase 5 已实现部分及外部阻塞。
主要功能：给后续开发、部署和回滚提供准确状态。
最近修改：【MODIFIED】2026-09-28 记录独立服务器、公网页和 Apple TV 部署；真实百度授权仍待验收。

## 已实现并本地验证

- 新建 `BabyPlayerBaiduServer/`：Python、FastAPI、MySQL 原生 SQL + `pymysql`；不复用 English Follow 账号服务。
- 每台设备独立高熵设备令牌、15 分钟配对、OAuth state、服务端加密令牌、手机逐层选单 Root Folder、设备状态与目录接口。历史 Jellyfin/Samba 配置和约 70 条关联数据完全不动；不新增跨来源同名关联。
- 手机静态页位于 Wisteria 官网源码 `apps/website/landing/wisteriasoftware.uk/babyplayer/connect.html`，无首页入口。配对码只放 URL fragment，页面通过独立 API 配对。
- 5 项服务测试通过；测试使用模拟百度响应，仅验证状态和协议，不代表真实 OAuth 或播放能力。
- 【MODIFIED】独立服务已部署到现有 `license-prod` 的 `/opt/babyplayer-baidu`，只监听 `127.0.0.1:8012`；独立 MySQL 库/用户、systemd unit、Nginx 虚拟主机和 Cloudflare DNS 已生效。公网健康检查及真实 MySQL 配对/未配置状态通过。Outline `8000`、English Follow `8010`、BabyPlayer ASR `8011` 都保持 active，未更改各自代码或数据库。
- 【MODIFIED】官网私有页已从公开发布仓库同步并在 `https://wisteriasoftware.uk/babyplayer/connect.html` 验证。同步工作流原先漏检新文件，已在独立网站仓库源提交修复。
- 【MODIFIED】Apple TV 家长设置和首次启动入口已启用百度扫码绑定；电视当前安装的是原 Bundle ID/Team/Apple ID 重新签名的 Phase 5 调试包。tvOS 模拟器 117 项通过、0 失败、1 项需要真机 Samba 密码而跳过。

## 当前阻塞与界限

- 用户已完成开发者实名认证，并在百度个人版控制台创建 BabyPlayer 应用。本机 Git 忽略的 `.env` 已填写 App Key 与 Secret Key，权限为 0600；服务端 OAuth 的 `client_id` 与 Chrome 中该应用的 App Key 已核对一致，未把具体值写入提交或文档。
- 已在百度应用安全设置中保存完整回调 `https://babyplayer-api.wisteriasoftware.uk/v1/oauth/callback`，用户也确认该专用域名。起初授权入口短暂返回 `redirect_uri_mismatch`；2026-09-27 复检已进入百度登录/授权页。用户试将短数字 App ID 填入 OAuth `client_id` 时，百度明确返回 `invalid_client`；恢复为 32 位 App Key 后，`oob` 和专用回调两种预检均进入授权页。App ID 仅单独记录，不参与 OAuth。尚待浏览器用户授权、换令牌和真实目录读取。
- 真实百度账号 OAuth、文件列表和 Root Folder 还未完成；当前等电视扫码授权的实测结果。服务端已经可用，但不能把健康检查等同于百度网盘联机成功。
- 【MODIFIED】服务器选择存在待确认冲突：最初冻结要求 Amazon Lightsail；随后用户指定与 Outline、English Follow 共用“同一台服务器”。现用 `5.78.185.116` 属于 Hetzner 网络，已按后一指示隔离部署。Phase 6/7 扩展须先确认以现有服务器为准，或迁往 Lightsail。
- 检查百度控制台页面结构时，工具输出曾意外包含页面显示的密钥；测试可继续，正式上线前应轮换相关密钥并更新服务器环境。
- Phase 6 独立 Spike 尚未完成：视频 metadata、临时 dlink、302、AVPlayer Range/seek 和 10～30 分钟连续播放均未验证。Phase 5 电视包只提供扫码与状态，不把百度加入播放自动选择。通过 Spike 前不能进入 Phase 7。
- 百度官方材料对个人版应用可否授权其他账号的说法尚需审核与实测。代码协议支持设备隔离，但不能把平台授权范围当作已获批准。

## 下个安全步骤

让当前电视完成扫码 OAuth 与 Root Folder 选择，核对后台设备状态和目录边界；随后用独立 Spike 验证播放能力。若个人版应用无法使用所需网盘能力，停止扩大实现，向用户明确提出这一冻结需求冲突。
