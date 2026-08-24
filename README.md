# BabyPlayer

BabyPlayer 是一个给 Apple TV 使用的儿童音乐视频播放器。它从家里电脑上的 Jellyfin 读取“音乐视频”库，在电视上显示封面、播放视频，并在本机缓存在线同步歌词。

简单理解：

```text
电脑：运行 Jellyfin，保存和管理视频
Apple TV：安装 BabyPlayer，浏览和播放视频
互联网：BabyPlayer 从 LRCLIB 搜索英文同步歌词；可选通过独立 ASR 服务做声音核验
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

4. 记下电脑的局域网 IP。Jellyfin 默认地址通常是：

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

### 免费 Apple 账户的限制

不付费也可以安装到自己的 Apple TV，但 Personal Team 的安装授权 7 天后到期，到时需要重新在 Xcode 中运行安装。Apple Developer Program 会员不需要每周重新签名。具体限制见 [Apple Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)。

## 三、让 BabyPlayer 连接 Jellyfin

1. 保持电脑和 Jellyfin Server 开机，并确认 Apple TV 与电脑在同一局域网。

2. 第一次打开 BabyPlayer，输入 Jellyfin 地址，例如：

   ```text
   http://192.168.3.33:8096
   ```

3. BabyPlayer 会显示一个 Quick Connect 配对码。

4. 在已经登录 Jellyfin 的电脑或手机浏览器中打开：

   ```text
   设置 → Quick Connect
   ```

   输入电视上的配对码并批准。Quick Connect 的官方说明见 [Jellyfin Quick Connect](https://jellyfin.org/docs/general/server/quick-connect/)。

5. 批准后 BabyPlayer 会自动进入“音乐视频”首页。以后通常不需要重新配对。

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

首次搜索会立即使用排名第 1 的普通歌词，不等腾讯 ASR 或 DeepSeek。ASR 大致确认同一首歌且确定性对齐成功后，先显示“AI 校时歌词”；随后 VPS 的 D3 Lyrics Evidence Reconciler 读取已缓存的 ASR，审查最多 3 份候选，必要时只从限定儿歌来源检索新证据，再返回绑定 ASR word ranges 的最终歌词。腾讯原始 transcript 不作为默认展示字幕。点选任一候选的当下即建立 manual lock，已在运行的 ASR/alignment/DeepSeek 都不能自动覆盖。

时间调整不限次数。每次提前或延后都在当前人工调整上累加；自动偏移和
人工调整分开保存。每份歌词都有自己的调整值，切换和重启后会恢复。

未配置 AI 歌词时，BabyPlayer 仍使用歌名、来源/版本、演唱者和歌曲段时长排序，并稳定默认绑定第 1 个。配置后使用渐进流程：T1 由腾讯 ASR word timestamps + 本地全局单调 alignment 生成可立即展示的 AI v1；T2 由 VPS 两阶段完成候选评估和最终证据重建。DeepSeek 只选择文本及 ASR word ranges，服务器验证后机械换算时间。D3 失败时会回退到原有逐行 repair 或 AI v1，不会丢失普通歌词。

注意：删除 BabyPlayer App 会同时删除 Apple TV 上保存的歌词绑定与缓存；从 Xcode 覆盖安装通常会保留。

### 可选声音分析

声音分析服务与 EnglishFlow、翻译、TTS 和 Jellyfin 完全独立；实现与部署说明见
[`BabyPlayerASRServer/README.md`](BabyPlayerASRServer/README.md)，详细边界见
[`BabyPlayer_Project_Docs/ASR_LYRICS_MATCHING_DESIGN.md`](BabyPlayer_Project_Docs/ASR_LYRICS_MATCHING_DESIGN.md)。

本地 Token 不直接写入 `Info.plist`。复制
`Config/BabyPlayerSecrets.xcconfig.example` 为 `Config/BabyPlayerSecrets.xcconfig`，只在后者中填入
BabyPlayer Bearer Token；该文件已被 Git 忽略。DeepSeek Key 只填入 VPS 的
`/opt/babyplayer-asr/.env`，不进入 Apple TV 安装包。

- Apple TV 把完整歌曲段 M4A 保存到 Application Support 下的本地音频库，不会自动淘汰；
  较长曲目可另有一份最长 120 秒的 ASR 识别前段。这份完整 M4A 可供后续“纯音频 +
  同步歌词”功能直接复用。
- VPS 不保存音频或 Jellyfin URL。ASR 模块缓存不可逆指纹、转写文字与时间戳；D3 另按指纹和 reconciliation version 缓存已验证的最终 AI Lyrics，不缓存网页或音频。
- 服务端硬限制每个北京时间自然月 18,000 秒（5 小时）。达到上限后提示下月 1 日
  00:00 再次使用；已有缓存仍可继续匹配。
- 家长设置可查看每首本地歌曲音频、识别状态、总占用、本月剩余时间，并可逐首或全部删除。
- 腾讯云后付费应保持关闭。

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
- 声音：高、中高、中、低、静音；
- 歌词校时：片头跳过、拖动进度和片尾跳过后，歌词仍按视频的实际时间继续同步。

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
选择“重新搜索歌词”。声音核验置信度不足时不会自动切换，家长选对后会永久绑定。

## 当前要求

- tvOS 18.0 或更高版本；
- 能运行对应 tvOS SDK 的 Xcode；
- 可访问的 Jellyfin Server；
- 在线歌词需要 Apple TV 能访问互联网。
