# BabyPlayer 小白测试指南

更新时间：2026-08-19

## 先说结论

现在的 BabyPlayer **还不是完整 V1 成品**，而是已经完成的最小技术 Spike：

- 已有一个可构建的 tvOS SwiftUI 工程；
- 已验证可以在 Apple TV 模拟器启动；
- 已验证模拟器可以访问本机 Jellyfin；
- 已写好 Quick Connect、读取第一条视频、系统播放器和 Back 返回代码；
- 还没有完成正式的儿童首页、完整家长设置、白天/哄睡播放规则和最终 UI。

所以当前目标不是“马上给孩子使用”，而是先确认这条最重要的技术链路：

```text
Apple TV / 模拟器
    → Jellyfin Quick Connect
    → 读取一条真实视频
    → 系统 AVPlayer 播放
    → 按 Back 返回
```

## 你现在有两个测试选择

### 选择 A：先用模拟器测试（推荐）

这是最简单的方式，不需要真的有 Apple TV，也不需要签名。

1. 打开 Finder，进入：

   `/Users/wufengyu/Projects/AppleTV-儿童播放器`

2. 双击打开：

   `BabyPlayer.xcodeproj`

3. Xcode 顶部运行设备选择：

   `Apple TV 4K (3rd generation) (at 1080p)`

4. 点击左上角三角形运行按钮。

5. 程序会出现一个 Spike 页面：

   - 第一步：测试 Jellyfin 服务器；
   - 第二步：生成 Quick Connect 配对码；
   - 第三步：播放测试视频。

## Jellyfin 怎么连接

### 1. 先启动 Jellyfin

在 Mac 上打开“应用程序”，双击 `Jellyfin`。

浏览器打开：

`http://127.0.0.1:8096`

本机当前局域网地址是：

`http://192.168.3.33:8096`

如果以后路由器给 Mac 分配了新的 IP，地址中的 `192.168.3.33` 也会变化，需要改成新的 Mac 局域网 IP。Jellyfin 默认 HTTP 端口是 `8096`。

### 2. 检查视频库

进入 Jellyfin 后确认存在一个视频库：

- 类型：`家庭视频和照片`
- 文件夹：

  `/Users/wufengyu/Downloads/00-SSS-精选/00SSS 哄娃`

目前里面已有 3 个 MP4 测试视频。

如果看不到视频，进入：

`管理后台 → 控制面板 → 服务器 → 媒体库`

确认文件夹地址没有写错，然后等待扫描完成。

### 3. 在 BabyPlayer 中测试服务器

在 Spike 页面中：

1. 服务器地址填写：

   `http://192.168.3.33:8096`

2. 点击“1 测试服务器”。

如果成功，状态会显示 Jellyfin 服务器名称、版本和 Quick Connect 可用。

### 4. 生成配对码

点击“2 生成配对码”。

电视模拟器会显示一个 6 位配对码。这个页面不要关闭。

然后在 Mac 的 Jellyfin 浏览器中进入：

`设置 → Quick Connect`

输入电视上显示的 6 位码并确认。

配对成功后，BabyPlayer 会自动：

1. 获取 Jellyfin 登录授权；
2. 读取第一条视频；
3. 解锁“3 播放测试视频”按钮。

### 5. 播放测试视频

点击“3 播放测试视频”。

如果播放成功，说明 Spike 的核心链路已经跑通。

在播放器页面按 Apple TV 遥控器的 Menu/Back，应该回到 Spike 首页。

## 能不能安装到真实 Apple TV？

**技术上可以，但当前这台 Mac 还没有连接或配对真实 Apple TV。**

我刚刚检查到 Xcode 目前只识别到了：

- Apple TV 模拟器；
- Mac；
- 其他模拟器。

没有看到真实 Apple TV 设备。因此现在可以立即测试的是模拟器；真实 Apple TV 安装还差这几步：

1. Apple TV 和 Mac 连接到同一个局域网；
2. 在 Xcode 的设备窗口中让 Mac 发现 Apple TV；
3. 按 Apple TV 屏幕提示完成配对；
4. 在 Xcode 的 Signing & Capabilities 中选择你的 Apple 开发团队；
5. 顶部运行设备改成真实 Apple TV；
6. 点击运行。

当前工程的 Bundle ID 是：

`com.wufengyu.BabyPlayer`

当前工程还没有配置开发团队，所以即使现在有真实 Apple TV，也要先完成 Xcode 签名设置。

## 现在“做好了没有”？

请按下面理解：

| 项目 | 当前状态 |
|---|---|
| Jellyfin 安装 | 已完成 |
| Jellyfin 初始化 | 已完成 |
| 视频库 | 已配置，待端到端验证 |
| tvOS 工程 | 已完成最小 Spike |
| Xcode 构建 | Debug/Release 均通过 |
| Apple TV 模拟器启动 | 已通过 |
| 模拟器访问 Jellyfin | 已通过 |
| Quick Connect 真实配对 | 待验证 |
| 真实视频播放 | 待验证 |
| 真实 Apple TV 安装 | 尚未做 |
| 最终儿童首页 | 尚未做 |
| 完整 V1 | 尚未完成 |

## 最建议的下一步

你现在不用先研究签名，也不用先买或配置别的东西。

按这个顺序即可：

1. 打开 Xcode 工程；
2. 选择 Apple TV 1080p 模拟器；
3. 点击运行；
4. 在 Spike 页面点“1 测试服务器”；
5. 点“2 生成配对码”；
6. 在 Jellyfin 的“设置 → Quick Connect”输入配对码；
7. 回到模拟器点“3 播放测试视频”；
8. 按 Back 测试返回。

如果第 6 步你不想自己操作，可以把模拟器显示的 6 位码发给我；我会先告诉你将要在 Jellyfin 中批准哪个配对请求，再继续。
