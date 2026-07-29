# BabyPlayer V1 本地设计稿

这套设计稿用于替代 Figma 交付，包含 14 个 tvOS 1920×1080 页面/状态、Focus 样式和基础遥控器流程。

## 打开方式

预览服务当前使用 macOS 当前用户后台任务运行，只监听本机 `127.0.0.1:4173`。

可以双击：

```text
start-preview.command
```

停止服务可以双击：

```text
stop-preview.command
```

也可以在项目根目录临时运行：

```bash
python3 -m http.server 4173 --directory BabyPlayer_Design_Prototype
```

然后打开：

```text
http://127.0.0.1:4173
```

## 操作

- 首页：方向键在选项卡、白天行、哄睡行和家长齿轮之间移动；Enter 开始对应模式播放。
- 首次配置：Enter 前进到下一步。
- 家长设置：上下方向键移动；Focus 到“内容适用性标签”后按 Enter 进入标签页面。
- Esc：返回首页；标签页中 Esc 返回家长设置。

## 截图

`screenshots/` 目录中包含每个页面的 1920×1080 PNG，可直接评审或分享。
