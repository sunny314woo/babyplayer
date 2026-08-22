# Mac Mini 与 Apple TV 的 Xcode 配对和 BabyPlayer 部署手册

本文记录已经在“客厅”Apple TV 上验证成功的完整流程，供以后更换 Mac、使用 Mac Mini，或重新安装 Xcode 后部署 BabyPlayer。

## 1. 本次验证成功的环境

| 项目 | 当前配置 |
| --- | --- |
| Apple TV 名称 | 客厅 |
| Apple TV 型号 | Apple TV 4K，A2843，128 GB（AppleTV14,1） |
| Apple TV 系统 | tvOS 26.6 |
| Mac 开发工具 | Xcode 26.6（Build 17F113） |
| Mac 网络 | Wi-Fi |
| Apple TV 网络 | Wi-Fi |
| 局域网 | Mac 与 Apple TV 连接同一个 Wi-Fi，没有使用网线 |
| Mac VPN | VPN 可以保持开启，但不能让局域网发现和局域网流量被隧道接管 |
| Apple TV VPN | 关闭 |
| 已安装应用 | BabyPlayer，Bundle ID 为 `com.wufengyu.BabyPlayer` |

这里最重要的不是两台设备都必须使用 Wi-Fi，而是它们必须位于同一个可互相访问的局域网。本次实际成功的配置是两边都使用同一个 Wi-Fi。

## 2. 配对前检查

### 2.1 检查 Wi-Fi 和 VPN

1. 在 Mac 菜单栏打开 Wi-Fi，确认连接的是家里的目标 Wi-Fi。
2. 在 Apple TV 打开 `设置 → 网络`，确认连接的是同一个 Wi-Fi。
3. Apple TV 上的 VPN 保持关闭。
4. Mac 上的 VPN 可以保持开启，但需要关闭会接管局域网流量的隧道功能，或开启“允许局域网连接/绕过局域网”。不同 VPN 软件可能把它称为：

   - TUN 模式；
   - 增强模式；
   - 虚拟网卡模式；
   - 代理局域网流量；
   - 禁止或绕过 LAN。

   目标只有一个：访问同一 Wi-Fi 中的设备时，流量直接走本地网络，不进入 VPN 隧道。

如果 Xcode 找不到 Apple TV，最简单的判断办法是临时完全退出 Mac VPN，再重新打开 Xcode 的设备窗口。如果关闭 VPN 后马上能发现电视，说明 VPN 的局域网绕过规则仍需调整。

还要确认路由器没有启用“访客 Wi-Fi”“客户端隔离”或“AP 隔离”。这些功能会让连接同一个 Wi-Fi 的设备仍然无法互相发现。

### 2.2 安装并准备 Xcode

在新的 Mac Mini 上：

1. 从 Mac App Store 安装或更新 Xcode。
2. 第一次打开 Xcode，等待附加组件和 tvOS 支持文件安装完毕。
3. 打开 `Xcode → Settings → Accounts`，登录用于开发的 Apple 账户。
4. 如果登录、输入 Apple ID 密码或输入 Mac 管理员密码，必须由使用者本人完成。
5. 打开项目文件 `BabyPlayer.xcodeproj`。

Xcode 版本必须支持 Apple TV 当前安装的 tvOS。若设备系统比 Xcode 新，先更新 Xcode，再继续配对。

## 3. Apple TV 上打开正确的配对入口

使用 Apple TV 遥控器依次打开：

```text
设置
└── 遥控器与设备
    └── 其他设备
        └── 遥控器 App 与设备
```

部分系统翻译可能把最后一项显示为 `Remote App and Devices`，也可能使用“其它设备”而不是“其他设备”，含义相同。

进入这个页面后先不要退出，让 Apple TV 停留在该页面，然后回到 Mac 操作 Xcode。

注意：页面中一开始只有 iPhone 或 iPad、没有 Mac，通常不代表 Apple TV 设置错误。这个页面也用于普通遥控器 App 配对；Mac 的 Xcode 配对需要由 Xcode 端主动发起，不能只等 Mac 自动出现在电视的已有设备列表里。

## 4. 在 Xcode 中发起配对

1. 在 Mac 的 Xcode 菜单栏打开：

   ```text
   Window → Devices and Simulators
   ```

2. 选择窗口顶部或左侧的 `Devices`。
3. 等待“客厅”Apple TV 出现在 `Discovered` 或设备列表中。
4. 选择“客厅”，点击 `Pair`、`Connect` 或对应的配对按钮。
5. Apple TV 会显示一组 PIN/验证码。
6. 在 Xcode 的配对输入框中输入电视显示的 PIN，然后确认。
7. 等待 Xcode 将状态变成 `Paired` 或 `Connected`。

PIN 是临时的配对凭证。建议由使用者看着电视并亲自输入；Codex 可以负责打开窗口、找到设备和点击配对，但应在 PIN 或账户密码输入处交还给使用者。

本次在 tvOS 26.6 上没有单独的“开发者模式”开关；完成上述无线配对后即可由 Xcode 安装应用。

第一次连接时，Xcode 可能继续显示以下状态：

- Preparing device support；
- Preparing shared cache symbols；
- Enabling developer disk image services；
- Connecting to device。

这些属于首次准备过程，可能需要几分钟。保持 Xcode、Apple TV 和 Wi-Fi 不变，等待完成即可。

## 5. 在新 Mac Mini 上配置项目签名

配对成功后，在 Xcode 中：

1. 在项目导航区选择蓝色的 `BabyPlayer` 工程。
2. 在 `TARGETS` 下选择 `BabyPlayer`。
3. 打开 `Signing & Capabilities`。
4. 勾选 `Automatically manage signing`。
5. 在 `Team` 中选择自己的开发团队。免费账户通常显示为“姓名（Personal Team）”。
6. 等待 Xcode 自动生成 `Xcode Managed Profile` 和 `Apple Development` 签名证书。

如果提示 Bundle Identifier 已被占用，把 `com.wufengyu.BabyPlayer` 改成只属于当前账户的标识，例如：

```text
com.你的英文名.BabyPlayer
```

免费 Personal Team 可以把应用安装到自己的 Apple TV，但签名授权通常需要定期重新生成。应用无法打开或授权过期时，重新连接 Apple TV，在 Xcode 中再次运行即可。

## 6. 构建、安装并运行 BabyPlayer

1. 回到 Xcode 顶部工具栏。
2. 确认运行 Scheme 是 `BabyPlayer`。
3. 点击运行设备菜单，把模拟器改为实体设备 `客厅`。
4. 点击左上角的 ▶︎，或按 `Command-R`。
5. Xcode 会依次完成签名、编译、安装和启动。
6. 工具栏显示 `Running BabyPlayer on 客厅` 时，部署成功。
7. 查看电视画面；BabyPlayer 应该已经自动打开，并且应用图标会保留在 Apple TV 主屏幕。

本次实际安装后的设备端结果为：

```text
Name         Bundle Identifier         Version   Bundle Version
BabyPlayer   com.wufengyu.BabyPlayer   0.4       1
```

以后只更新 BabyPlayer 代码而没有更换 Mac 时，通常不必重新输入配对 PIN。连接同一个 Wi-Fi，选择“客厅”，再次按 `Command-R` 即可覆盖安装；应用的数据通常会保留。

## 7. Codex 应该怎么操作

在新的 Mac Mini 上，把项目放入工作目录后，可以直接在 Codex 中输入：

> 请检查这台 Mac 的 Xcode 和 tvOS 支持，发现并配对同一 Wi-Fi 上名为“客厅”的 Apple TV，然后把 BabyPlayer 构建、安装并运行到这台电视。遇到 Apple ID、Mac 密码或电视 PIN 时停下来让我输入。

Codex 可以按下面的顺序执行：

1. 检查 Xcode 版本和开发者目录：

   ```bash
   xcodebuild -version
   xcode-select -p
   ```

2. 检查项目 Scheme、tvOS 构建设置、Bundle Identifier 和签名状态。
3. 通过 Xcode 的 `Window → Devices and Simulators` 查找“客厅”。
4. 如果设备未出现，检查两边 Wi-Fi、Apple TV VPN、Mac VPN 的局域网绕过设置，以及 Apple TV 是否仍停留在“遥控器 App 与设备”页面。
5. 选中设备并发起配对。
6. 在出现 Apple ID 密码、Mac 管理员密码或电视 PIN 时暂停，由使用者完成输入。
7. 配对后用以下命令再次确认设备连接：

   ```bash
   xcrun devicectl list devices
   ```

8. 在 `Signing & Capabilities` 中选择用户的 `Personal Team`，等待 Xcode 自动签名。
9. 把 Xcode 的运行目标改为“客厅”，点击运行并监控构建结果。
10. 安装后查询设备应用列表，确认 BabyPlayer 已存在：

    ```bash
    xcrun devicectl device info apps --device <从设备列表中取得的设备标识>
    ```

Codex 能完成 Xcode 界面导航、签名团队选择、构建、安装、日志检查和设备端验证。下面这些操作需要使用者配合：

- 用 Apple TV 遥控器打开正确菜单并让电视停留在配对页；
- 查看电视上显示的 PIN；
- 输入 Apple ID 密码或 Mac 管理员密码；
- 处理电视屏幕上需要遥控器确认的提示。

## 8. 找不到 Apple TV 时的排查顺序

按以下顺序检查，通常最快：

1. 确认 Mac 与 Apple TV 都连接同一个 Wi-Fi；本次成功配置没有使用网线。
2. 确认 Apple TV VPN 已关闭。
3. 确认 Mac VPN 没有接管局域网；不确定时临时完全退出 VPN。
4. 确认 Apple TV 停留在：

   ```text
   设置 → 遥控器与设备 → 其他设备 → 遥控器 App 与设备
   ```

5. 在 Xcode 中关闭再打开 `Window → Devices and Simulators`。
6. 保持电视配对页开启 30 秒至 1 分钟，等待 Bonjour/mDNS 发现。
7. 确认没有连接访客 Wi-Fi，路由器没有开启 AP/客户端隔离。
8. 如果 macOS 防火墙询问是否允许 Xcode 接收入站连接，选择允许；如果此前拒绝，在 `系统设置 → 网络 → 防火墙 → 选项` 中检查 Xcode。
9. 重启 Xcode；仍无法发现时，再重启 Apple TV 和 Mac 的 Wi-Fi。
10. 设备出现但系统支持失败时，更新 Xcode 并完成首次组件下载。

## 9. 已配对但无法安装时的排查顺序

### 提示需要 Development Team

打开：

```text
项目 → BabyPlayer Target → Signing & Capabilities
```

勾选自动签名并选择自己的 `Personal Team`。

### 一直显示 Updating Provisioning

确认 Mac 能访问互联网、Apple 账户已登录，然后等待 Xcode 完成证书和描述文件生成。不要在更新过程中反复取消。

### Apple TV 显示已连接，但运行目标中没有“客厅”

关闭运行目标菜单后重新打开；再到 `Devices and Simulators` 确认设备状态是 `Connected`。首次配对后共享缓存和设备支持文件未准备完时，设备可能暂时不可选。

### Build Succeeded，但电视没有打开应用

在 Apple TV 主屏幕查找 BabyPlayer 图标并手动打开；同时检查 Xcode 调试控制台是否显示启动错误。也可以让 Codex 用 `devicectl device info apps` 验证是否已经安装。

## 10. 更换 Mac Mini 时必须重新做什么

Apple TV 与旧 Mac 已配对，不代表会自动信任新的 Mac Mini。换机器后至少需要重新完成：

1. 安装和初始化 Xcode；
2. 登录 Apple 开发账户；
3. 在 Apple TV 配对页面和新 Mac Mini 的 Xcode 中重新配对；
4. 输入新的电视 PIN；
5. 为项目选择开发团队并重新签名；
6. 选择“客厅”并重新运行安装。

完成一次后，后续更新通常只需要保持两边连接同一个 Wi-Fi，然后在 Xcode 中按 `Command-R`。
