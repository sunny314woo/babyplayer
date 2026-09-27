# Phase 5 进度：百度授权与 Root Folder

用途：记录 Phase 5 已实现部分及外部阻塞。
主要功能：给后续开发、部署和回滚提供准确状态。
最近修改：【MODIFIED】2026-09-27 建立独立服务与私有手机页，本阶段尚未完成。

## 已实现并本地验证

- 新建 `BabyPlayerBaiduServer/`：Python、FastAPI、MySQL 原生 SQL + `pymysql`；不复用 English Follow 账号服务。
- 每台设备独立高熵设备令牌、15 分钟配对、OAuth state、服务端加密令牌、手机逐层选单 Root Folder、设备状态与目录接口。历史 Jellyfin/Samba 配置和约 70 条关联数据完全不动；不新增跨来源同名关联。
- 手机静态页位于 Wisteria 官网源码 `apps/website/landing/wisteriasoftware.uk/babyplayer/connect.html`，无首页入口。配对码只放 URL fragment，页面通过独立 API 配对。
- 5 项服务测试通过；测试使用模拟百度响应，仅验证状态和协议，不代表真实 OAuth 或播放能力。

## 当前阻塞与界限

- 用户已完成开发者实名认证，并在百度个人版控制台创建 BabyPlayer 应用。本机 Git 忽略的 `.env` 已填写 App Key 与 Secret Key，权限为 0600；服务端 OAuth 的 `client_id` 与 Chrome 中该应用的 App Key 已核对一致，未把具体值写入提交或文档。
- 已在百度应用安全设置中保存完整回调 `https://babyplayer-api.wisteriasoftware.uk/v1/oauth/callback`，用户也确认该专用域名；但实际授权入口仍返回 `redirect_uri_mismatch`。`redirect_uri=oob` 可打开百度登录页，说明错误聚焦于回调校验；真实 OAuth 尚未通过。
- 用户确认使用现有同一台服务器，但现有 `ssh wisteria` 的 22 端口连接超时；等待可连接的 SSH 信息。部署前必须核查现有 Outline 支付服务与 English Follow 服务的端口、Nginx、MySQL；BabyPlayer 用独立 `/opt/babyplayer-baidu`、库/用户、systemd unit、子域名，不重启现有两个应用。未部署服务或静态页。
- 检查百度控制台页面结构时，工具输出曾意外包含页面显示的密钥；测试可继续，正式上线前应轮换相关密钥并更新服务器环境。
- tvOS 的 Phase 4 百度入口仍为禁用状态；实体 Apple TV 仍是 Phase 2 包。待服务、域名、百度应用可用后接入扫码和状态；Phase 6 Spike 通过前不接入百度播放。
- 百度官方材料对个人版应用可否授权其他账号的说法尚需审核与实测。代码协议支持设备隔离，但不能把平台授权范围当作已获批准。

## 下个安全步骤

先解决百度回调校验并取得可连接的 SSH 信息；只读核查现有服务后配置独立 HTTPS/MySQL，部署并做真实 OAuth + 目录闭环。若个人应用无法使用所需网盘能力，停止扩大实现，向用户明确提出这一冻结需求冲突。
