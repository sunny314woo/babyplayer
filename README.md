# BabyPlayer

BabyPlayer 是一个给 Apple TV 使用的儿童音乐视频播放器。它从家里电脑上的 Jellyfin 读取“音乐视频”库，在电视上显示封面、播放视频，并在本机缓存在线同步歌词。

当前版本的主要能力：

- 从 Jellyfin 的“音乐视频”库浏览并播放儿童音乐视频；
- 普通同步歌词、ASR 识别歌词、DeepSeek 歌词校准，以及按已有结果生成简体中文双语字幕；
- 播放页和家长设置中的双语菜单：可自动按“双语优先”选择，也可手动切换英文、中文、双语或关闭；
- 识别到可信人声边界后，按歌曲保存智能跳过片头/片尾的设置；没有分析结果时仍可使用 Jellyfin 章节或家长手工秒数。

简单理解：

```text
电脑：运行 Jellyfin，保存和管理视频
Apple TV：安装 BabyPlayer，浏览和播放视频
互联网：BabyPlayer 从 LRCLIB 搜索同步歌词；可选通过独立 ASR 服务做人声识别、歌词校准和翻译
```

Jellyfin 不需要、也不能作为服务器安装在 Apple TV 上。平时播放时，电脑和 Jellyfin 需要保持开机运行。

## 一、准备 Jellyfin

1. 在电脑上安装并启动 Jellyfin Server，完成管理员账户设置。可参考 [Jellyfin Quick Start](https://jellyfin.org/docs/general/quick-start/)。

2. 在 Jellyfin 管理后台新建媒体库，内容类型必须选择“音乐视频”（Music Videos），然后加入视频所在文件夹。BabyPlayer 只读取这个类型，不会混入“家庭视频和照片”。可参考 [Jellyfin Music Videos](https://jellyfin.org/docs/general/server/media/music-videos/)。

3. 建议用正确歌名命名视频，例如：

   ```text
   Twinkle Twinkle Little Star.mp4
   Rain Rain Go Away.mp4
   ```

   歌名越准确，歌词候选越可靠。

4. 记下电脑的局域网 IP。macOS 上如果使用 Wi-Fi，通常可以在终端执行：

   ```bash
   ipconfig getifaddr en0
   ```

   命令输出的内容就是当前电脑的局域网 IP，例如 `192.168.1.14`。如果 `en0` 没有输出，先执行下面的命令，找到 Wi-Fi 或以太网对应的 `Device`（例如 `en1`），再把设备名代入：

   ```bash
   networksetup -listallhardwareports
   ipconfig getifaddr en1
   ```

   也可以查看所有网卡的 IPv4 地址：

   ```bash
   ifconfig | rg "inet "
   ```

   选择与 Apple TV 在同一局域网的地址，例如 `192.168.1.x` 或 `10.x.x.x`；不要选择 `127.0.0.1`、`localhost` 或 VPN 地址。

   Jellyfin 默认地址通常是：

   ```text
   http://电脑局域网IP:8096
   ```

   例如 `http://192.168.3.33:8096`。不要在 Apple TV 上填写 `127.0.0.1` 或 `localhost`，那会指向 Apple TV 自己。Jellyfin 的默认 HTTP 端口是 8096，详见 [Jellyfin Networking](https://jellyfin.org/docs/general/post-install/networking/)。

## 二、把 BabyPlayer 装到真实 Apple TV

完整的配对、VPN、Codex 操作和 Mac Mini 重新部署步骤见 [Mac Mini 与 Apple TV 的 Xcode 配对和 BabyPlayer 部署手册](APPLE_TV_XCODE_PAIRING_AND_DEPLOYMENT.md)。

### 第一次安装

1. 在 Mac 上安装 Xcode，然后打开本项目的 `BabyPlayer.xcodeproj`。

2. 在 Xcode 打开 `Xcode → Settings → Apple Accounts`，登录你的 Apple 账户。

3. 在左侧选择工程，再选择 `BabyPlayer` Target，打开 `Signing & Capabilities`：

   - 勾选 `Automatically manage signing`；
   - `Team` 选择你的账户；
   - 如果 Bundle Identifier 冲突，把 `com.wufengyu.BabyPlayer` 改成只属于你的名称，例如 `com.你的名字.BabyPlayer`。

4. 让 Mac 和 Apple TV 连接同一个局域网。

5. Apple TV 打开：

   ```text
   设置 → 遥控器与设备 → 其他设备 → 遥控器 App 与设备
   ```

6. Mac 的 Xcode 打开：

   ```text
   Window → Devices and Simulators → Devices
   ```

   在 `Discovered` 中选择 Apple TV，点击配对，并输入电视显示的验证码。完整步骤见 [Apple：Pair a wireless device with Xcode](https://help.apple.com/xcode/mac/current/en.lproj/devbc48d1bad.html)。tvOS 不需要另外打开“开发者模式”，配对成功即可，见 [Apple Developer Mode 说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

7. 回到 Xcode 顶部，把运行设备从模拟器改成你的 Apple TV，然后点击 ▶︎，或按 `Command-R`。

Xcode 会自动签名、编译、安装并启动 BabyPlayer。Apple 官方的实体设备运行说明见 [Running your app on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)。

### 手动一键重新签名并部署

项目内置了一个不依赖 AI 的命令行脚本。脚本地址：
`Scripts/deploy-to-apple-tv.command`。它使用 Xcode 的 Automatic Signing 重新生成/更新开发签名，
构建 tvOS App，通过 `devicectl` 安装到已配对的 Apple TV，并启动 BabyPlayer。

对于当前这台已经配对并成功部署过的 Mac 与 Apple TV，日常更新只需要唤醒 Apple TV、确认两边在同一个
Wi-Fi，然后执行下面这一条命令即可。不需要每次重新配对，也不需要每次打开 Apple TV 的配对页面。

首次使用、更换 Mac，或配对关系失效时，才需要完成这些人工准备：

1. 安装完整 Xcode，不是只有 Command Line Tools；打开 Xcode 并登录 Apple 账户。
2. 在 Xcode 的 `Window → Devices and Simulators` 中完成 Apple TV 配对。
3. Mac 和 Apple TV 连接同一个局域网；首次配对时让 Apple TV 保持唤醒，并准备输入电视 PIN。
4. 确认项目 Target 的 Team 与 Bundle ID 是当前 Apple 账户可用的值。当前工程默认是
   `RD2D85V483` 与 `com.wufengyu.BabyPlayer`，如果你的账户不同，可以修改工程设置，或使用脚本的环境变量覆盖。

完成准备后，在终端执行单条命令即可：

```bash
"/Users/wufengyu/Projects/AppleTV-儿童播放器/Scripts/deploy-to-apple-tv.command"
```

如果当前就在项目目录，也可以执行：

```bash
./Scripts/deploy-to-apple-tv.command
```

默认会寻找名称为“客厅”的 tvOS 设备。Apple TV 改名或存在多台设备时，指定名称、CoreDevice ID
或 UDID：

```bash
./Scripts/deploy-to-apple-tv.command --device "客厅"
```

常用选项：

- `--debug`：构建 Debug 版本；默认构建 Release 版本；
- `--no-launch`：只安装，不自动启动；
- `--help`：查看完整参数和环境变量。

脚本实际输出的签名 App 包位于
`.derivedData-apple-tv/Build/Products/Release-appletvos/BabyPlayer.app`。这个 `.app` 就是供
`devicectl` 直接安装的已签名 tvOS App 包，不需要另行制作 IPA。

脚本不会代替首次 Apple ID 登录、Apple TV 配对、电视 PIN、Mac 管理员密码或 Xcode 弹窗确认。
若 Apple TV 不在线、未配对、与 Mac 不在同一局域网，脚本会在查找设备或安装阶段停止；重新连接设备后
再次执行同一条命令即可。若构建阶段提示证书或 Provisioning Profile，先打开 Xcode 手动运行一次
BabyPlayer，让 Xcode 完成账户授权和 Automatic Signing 初始化。

### 自动定时部署（暂不启用）

当前先不注册定时任务，先确认上面的手动命令可以稳定完成一次完整部署。后续适合使用 macOS 的
`launchd` 注册当前用户的 LaunchAgent，例如每 3 天运行一次，或每 7 天运行一次；电脑开机后
登录用户会话时由 `launchd` 拉起检查脚本。检查逻辑应当是：

1. 用 `devicectl list devices --json-output` 检查已配对的 Apple TV 是否可连接；不可连接时记录日志并跳过，避免无意义构建。
2. 检查最近一次签名 App 内的 Provisioning Profile 到期时间，以及本机可用的 Apple Development 证书。
3. 在到期前的安全窗口内调用上面的部署脚本；部署成功后写入时间戳和结果日志。
4. Apple TV 不在线时等待下一次检查；自动任务不能替代首次配对，也不能可靠唤醒一台完全离线的电视。

免费 Personal Team 通常只有约 7 天的设备安装授权，因此 3 天周期比 7 天周期更有余量；付费开发者账户
的证书/profile 周期不同，仍应以本机实际 profile 的到期时间为准。等手动脚本验证通过后，再根据你希望的
策略选择“固定每 3/7 天部署”还是“只在剩余时间低于阈值时部署”。

### 免费 Apple 账户的限制

不付费也可以安装到自己的 Apple TV，但 Personal Team 的安装授权 7 天后到期，到时需要重新在 Xcode 中运行安装。Apple Developer Program 会员不需要每周重新签名。具体限制见 [Apple Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)。

## 三、让 BabyPlayer 连接 Jellyfin

1. 保持电脑和 Jellyfin Server 开机，并确认 Apple TV 与电脑在同一局域网。可以先在电脑浏览器打开 `http://127.0.0.1:8096`，确认 Jellyfin 正在运行。

2. 在电脑终端执行 `ipconfig getifaddr en0`，取得电脑当前局域网 IP。然后在 Apple TV 第一次打开 BabyPlayer，输入 Jellyfin 地址：

   ```text
   http://电脑局域网IP:8096
   ```

   例如电脑当前 IP 是 `192.168.1.14`，就输入 `http://192.168.1.14:8096`。不要输入 `localhost` 或 `127.0.0.1`，因为在 Apple TV 上它们指向的是 Apple TV 自己。

3. 点击“连接并生成配对码”，BabyPlayer 会显示一个 Quick Connect 配对码。

4. 在已经登录 Jellyfin 的电脑或手机浏览器中打开：

   ```text
   设置 → Quick Connect
   ```

   输入电视上的配对码并批准。Quick Connect 的官方说明见 [Jellyfin Quick Connect](https://jellyfin.org/docs/general/server/quick-connect/)。

5. 批准后 BabyPlayer 会自动进入“音乐视频”首页。以后通常不需要重新配对。

### 更换网络后重新连接

电脑更换 Wi-Fi、路由器或网络环境后，局域网 IP 可能会变化；Jellyfin 服务器没有更换，也不代表 IP 一定不变。此时重新执行：

```bash
ipconfig getifaddr en0
```

把新 IP 与 `:8096` 组成新的 Jellyfin 地址，例如 `http://192.168.1.25:8096`。在 Apple TV 的“家长设置”中选择“重新配对”，输入新地址并再次批准 Quick Connect。若 IP 经常变化，可以在路由器中为这台电脑设置 DHCP 地址保留。

## 四、播放时选择歌词

1. 播放一个音乐视频，按遥控器调出播放条。

2. 打开“字幕与歌词”按钮。

3. 这里可以：

   - 打开或关闭字幕；
   - 查看当前视频最接近的同步歌词候选，最多 3 个，并可额外使用 1 份本地歌本纯文本；
   - 根据匹配分、歌词时长差和歌词片段选择正确版本；
   - 选择“重新搜索歌词”刷新在线结果；
   - 使用“提前/延后 0.1 秒或 0.5 秒”校准时间。
   - 在第一句开始时暂停，选择“把第一句对齐到当前位置”，一次消除 MP4 片头偏移。

家长设置中的“在线歌词”现在只有两个总开关：`自动选择（双语优先）`或`关闭`。开启时，
播放页会根据当前已有结果自动选择：有合规的简体中文翻译则显示中英双语，否则显示原文的
英文或中文；关闭后不显示歌词。播放页的“字幕与歌词”菜单仍可以临时切换英文、中文、
中英双语或关闭，具体选项会根据当前曲目已有内容显示。手动选择会锁定自动结果，直到再次
选择其他字幕来源或重新进入播放页。

如果这首曲目已有有效的 DeepSeek 校准结果，每次新进入播放页默认使用 DeepSeek；当前播放
中仍可切回普通歌词。双语翻译只附着在已有的 DeepSeek 英文时间轴上，不修改英文歌词的
顺序、文本或时间。

当焦点位于系统进度条或功能键排时，再按一次上方向键会立即收起播放控件，
画面只保留视频和字幕。下一次方向键可重新唤起控件；Back/Menu 仍保持退出播放器的现有行为。

首次搜索会使用排名第 1 的普通歌词。当前版本不会在播放、搜索、单曲循环或重新进入播放器时
擅自调用腾讯 ASR 或 DeepSeek。只有家长在“歌词分析”中明确点击后，才会启动分析链。

需要声音分析时，在独立的“歌词分析”菜单人工执行：

1. `ASR 识别歌词`：读取缓存或运行腾讯 ASR；ASR 成功后自动进入 DeepSeek，DeepSeek 成功后直接启用为这首视频的默认字幕；
2. `DeepSeek 校准歌词`：保留分阶段手工入口；已有 ASR 时可单独重跑，成功后也会自动启用；
3. `采用腾讯 ASR 字幕` / `采用 DeepSeek 校准字幕`：仍然保留，可随时手工 A/B 切换已保存结果。

播放画面角落会显示 ASR 和 DeepSeek 处理阶段；自动启用或手工采用成功后，结果卡保留 5 秒自动消失。ASR 失败时不进入
DeepSeek；DeepSeek 失败时保留当前字幕和已生成的 ASR，可以手动重试或采用 ASR。
如果分析期间家长又手动选了其他字幕，较新的手工选择优先，DeepSeek 只保存不覆盖。

一次 ASR 分析还会在 Mac 本地先经过“人声分离 + 人声活动检测”：从完整原视频提取 vocals
音轨，再规划包含人声的时间窗口，最后按原视频时间轴调用腾讯 ASR。它的作用是减少伴奏、
前奏和片尾无声部分造成的识别噪声与额度消耗；它不是实时字幕，也不能凭空恢复 ASR 没有
识别到的演唱。具体实现使用 Audio Separator、Silero VAD、Voice Window Planner 和腾讯
ASR，详见 [`BabyPlayerASRServer/README.md`](BabyPlayerASRServer/README.md)。

ASR、DeepSeek 和固定的普通歌词可以共存并反复切换。DeepSeek 只选择文字和 ASR word ranges，
最终时间由服务器机械换算；ASR 没有识别到的演唱目前不能由 DeepSeek 恢复。

时间调整不限次数。每次提前或延后都在当前人工调整上累加；自动偏移和
人工调整分开保存。每份歌词都有自己的调整值，切换和重启后会恢复。

未配置声音分析服务时，普通歌词搜索、人工固定和时间调整仍可独立使用。

注意：删除 BabyPlayer App 会同时删除 Apple TV 上保存的歌词绑定与缓存；从 Xcode 覆盖安装通常会保留。

### 可选声音分析

声音分析服务与 EnglishFlow、翻译、TTS 和 Jellyfin 完全独立；实现与部署说明见
[`BabyPlayerASRServer/README.md`](BabyPlayerASRServer/README.md)，详细边界见
[`BabyPlayer_Project_Docs/ASR_LYRICS_MATCHING_DESIGN.md`](BabyPlayer_Project_Docs/ASR_LYRICS_MATCHING_DESIGN.md)。
当前质量问题、代码审查、竞品/开源项目对比和后续路线见
[`BabyPlayer_Project_Docs/SMART_LYRICS_AUTO_SUBTITLE_AUDIT_2026-08-24.md`](BabyPlayer_Project_Docs/SMART_LYRICS_AUTO_SUBTITLE_AUDIT_2026-08-24.md)。
下一位 AI 接手 Mac 本地测试前还应完整阅读
[`BabyPlayer_Project_Docs/AI_HANDOFF_LYRICS_LOCAL_SERVER.md`](BabyPlayer_Project_Docs/AI_HANDOFF_LYRICS_LOCAL_SERVER.md)。

本地 Token 不直接写入 `Info.plist`。复制
`Config/BabyPlayerSecrets.xcconfig.example` 为 `Config/BabyPlayerSecrets.xcconfig`，只在后者中填入
BabyPlayer Bearer Token；该文件已被 Git 忽略。腾讯与 DeepSeek 密钥只填入这台 Mac 的
`BabyPlayerASRServer/.env`，不进入 Apple TV 安装包。

- `8011/v1` 不是 Debug 补丁，而是 Debug 与 Release 共用的正式 Mac 本地 AI 服务入口。
  App 不保存固定 ASR IP，也不配置 VPS Base URL。
- Apple TV 会从当前已配对的 Jellyfin 地址只取主机名：若 Jellyfin 是
  `http://192.168.1.14:8096`，ASR、DeepSeek 和翻译自动使用
  `http://192.168.1.14:8011/v1`。没有任何静默 VPS 回退。
- 更换 Wi-Fi 或路由器时，先用 `ipconfig getifaddr en0` 查看 Mac 新 IP，再仅更新并重新配对
  Apple TV 中的 Jellyfin `:8096` 地址；AI 服务会同步换到同一主机的 `:8011/v1`，无需改工程配置。
- 首次配置 Mac 后运行 `BabyPlayerASRServer/scripts/install-local-development-service.sh`，让
  `8011` 服务随登录启动并在异常退出后自动恢复。`-1004` 表示 Apple TV 无法连接 Mac 的
  `8011`，应检查同一局域网、LaunchAgent、防火墙和路由器客户端隔离。
- Apple TV 不建立永久音频库。双语字幕、人工绑定和片头片尾结果会按媒体 ID/内容指纹写入
  tvOS 私有 Caches；正常退出设置、播放或覆盖安装不会重新生成。Mac 本地 SQLite 同时保存
  可重建的 ASR/DeepSeek 结果；只有卸载 App 或 tvOS 清理 Caches 时，电视副本才可能需要恢复。
- Mac 本地服务不保存 Jellyfin URL。ASR 模块缓存不可逆指纹、转写文字与时间戳；D3 缓存最终
  AI Lyrics。D3 缓存现已绑定实际 ASR word timeline/VAD 标记和候选内容哈希，
  不会再把旧 word ranges 套到新证据上。
- D3 现会按 ASR 时间确定性归一化模型乱序/重叠行，并自动回收 DeepSeek 漏掉但有人声证据的 ASR 词。
  这能防止副歌被 LLM 默默删除，但 ASR 本身完全没识别的演唱仍无法凭空生成时间。
- Wheels 最新实测已按用户真值把前奏旋律、汽车声和节奏视为无人声；ASR 质量过滤和
  DeepSeek 的首句都从实际开唱的 22.45 秒开始。
- 服务端硬限制每个北京时间自然月 18,000 秒（5 小时）。达到上限后提示下月 1 日
  00:00 再次使用；已有缓存仍可继续匹配。
- 腾讯云后付费应保持关闭。

### 智能跳过片头片尾

当一次声音分析得到可信的首句和末句人声位置后，BabyPlayer 会保存保守的智能边界，并在
该歌曲的“AI 功能”菜单中显示“智能跳过片头片尾”。每首歌默认开启；家长可以在播放页
对当前歌曲单独关闭或重新开启，选择会持久保存。

边界的优先级如下：

1. Jellyfin 已标注的 `intro` / `opening` / `片头` 和 `outro` / `ending` / `credits` / `片尾` 章节；
2. 已通过人声识别确认的智能边界（至少跳过 3 秒，并保留可播放主体）；
3. 家长设置中的“手工片头（备用）”和“手工片尾（备用）”。

智能边界只影响播放起点和接近片尾时的自动结束，不会重复叠加到歌词时间轴。重新分析或
媒体时长发生明显变化时，旧边界会被拒绝；如果分析不足以确认边界，则不显示智能跳过开关。

本地开发模式可在 `BabyPlayerASRServer/LyricsTestOutputs/` 保存完整提取音频、ASR/DeepSeek JSON
和 SRT。该目录已被 Git 忽略，但包含媒体和歌词内容，只应用于受控调试并定期清理。

### 内置 Super Simple Songs 曲目库

项目内的 `BabyPlayer/BabyLyricsCatalog.json` 可以在构建前预置已授权的 SSS 曲目和 LRC。内置库的候选与 LRCLIB 一起评分；分数最高的仍然排在第 1 个。

```json
{
  "tracks": [
    {
      "id": -1001,
      "trackID": "sss-example-official-v1",
      "title": "Example Song",
      "aliases": ["Example"],
      "artist": "Super Simple Songs",
      "source": "Super Simple Songs",
      "version": "Official",
      "duration": 120.0,
      "plainLyrics": "First line\nSecond line",
      "syncedLyrics": "[00:05.20]First line\\n[00:09.80]Second line"
    }
  ]
}
```

- 内置曲目 `id` 使用负数，避免与 LRCLIB ID 冲突。
- `syncedLyrics` 可为 `null`；此时该条目只提供标准歌名、别名和艺术家线索，歌词仍从 LRCLIB 搜索。
- `plainLyrics` 可保存已获授权的纯文本歌本。它不占用 3 个在线同步候选名额；声音分析
  可用它核验曲目，并在词级时间戳覆盖率足够时在 Apple TV 本地自动校时。
- 只应打包自己有权使用和分发的歌词文件。

## 五、其他播放控制

播放条上还有：

- 播放模式：单曲循环、顺序循环、随机播放，以及 30 分钟定时播放；
- 智能跳过片头片尾：在已有可信分析边界的曲目中可按曲目开关；
- 歌词校时：片头跳过、拖动进度和片尾跳过后，歌词仍按视频的实际时间继续同步；
- 播放倍速：0.8×、1×、1.5×、2×、3×。

从首页直接点一首歌时，默认无限单曲循环，直到定时结束或手动退出。

## 六、常见问题

### 一直显示“准备宝宝视频”

依次检查：

1. 电脑上的 Jellyfin 是否正在运行；
2. Apple TV 和电脑是否在同一局域网，且没有连接访客 Wi-Fi；
3. 地址是否使用电脑局域网 IP 和 `8096` 端口；
4. Jellyfin 管理后台是否启用了 Quick Connect；
5. 配对码是否已经过期；过期后返回上一步重新生成。

### 首页没有更新视频

确认视频在 Jellyfin 的“音乐视频”库中，然后在 BabyPlayer 顶部选择“刷新媒体库”。它会要求 Jellyfin 重新扫描，再读取删除、移动或改名后的结果。

### 某首歌没有歌词或歌词不正确

在该视频的播放页打开“字幕与歌词”，先看最多 3 个同步候选和可选本地歌本；不合适时
选择“重新搜索歌词”。如果需要声音分析，点一次“ASR 识别歌词”；DeepSeek 成功后会自动切换并保存绑定。tvOS Caches
属于可清理存储，如果系统删除缓存，可从 Mac 本地服务恢复或重新生成，但当前人工绑定仍可能需要重新选择。

## 当前要求

- tvOS 18.0 或更高版本；
- 能运行对应 tvOS SDK 的 Xcode；
- 可访问的 Jellyfin Server；
- 在线歌词需要 Apple TV 能访问互联网。
