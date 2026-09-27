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

- Chrome 中已登录的百度网盘个人版控制台创建应用时，实际提示“请先完成开发者实名认证后再创建应用”（另有 `user not auth ,not allow create`）。需要账号所有者本人完成身份认证；没有 App Key/Secret、获批回调或真实授权。
- 尚待用户确认 Lightsail 主机、API 子域名和 SSH 连接；未部署服务或静态页。
- tvOS 的 Phase 4 百度入口仍为禁用状态；实体 Apple TV 仍是 Phase 2 包。待服务、域名、百度应用可用后接入扫码和状态；Phase 6 Spike 通过前不接入百度播放。
- 百度官方材料对个人版应用可否授权其他账号的说法尚需审核与实测。代码协议支持设备隔离，但不能把平台授权范围当作已获批准。

## 下个安全步骤

开发者实名认证并提交 BabyPlayer 应用；确认回调/权限及用户提供的独立服务器地址；配置 HTTPS/MySQL，部署并做真实 OAuth + 目录闭环。若个人应用无法使用所需网盘能力，停止扩大实现，向用户明确提出这一冻结需求冲突。
