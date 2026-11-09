<p align="center"><img src="docs/icon.png" width="128" alt="Setem"></p>

<h1 align="center">Setem</h1>

<p align="center">Setem（原 OpenVoice）是 macOS 菜单栏语音输入：按住或点按快捷键说话，在浮窗中预览，定稿后一次性输入光标处。</p>

## 功能

- **四个识别渠道**：豆包输入法、微信输入法、千问输入法云端识别，以及在本机运行的本地模型（仅 Apple 芯片），可在设置中切换
- **长按说话**：按住右 ⌥ / 右 ⌘ / 右 ⌃ / Fn 开始，松开结束
- **点按说话**：自定义快捷键（单个修饰键或任意组合键），点一下开始；再次点按同一快捷键或点击浮窗停止收音，等待定稿后输入；停顿或静音不会自动结束
- **长按并发送**：可绑定第二个长按快捷键，定稿上屏后自动回车发送
- **浮窗预览**：识别中的文字只在浮窗显示，支持换行和长稿尾部预览；结束后等待完整定稿、渠道润色，再一次性输入目标输入框
- **连续语音输入**：等待定稿时可再次长按继续说，各段按录音顺序合并，保留完整定稿和润色结果；等待期间重复点按保持等待
- **预录保护**：按键按下即收音，长按确认后保留起始语音；取消短按会丢弃该次预录
- **耳机模式**：菜单栏或设置一键开启，像通话一样常开蓝牙耳机（优先 AirPods）麦克风，避免每段录音切换耳机模式丢掉开头和结尾；锁屏时释放，耳机不可用时使用电脑麦克风
- **电脑麦克风**：默认 MacBook 内置麦，可选 USB 等外接麦克风，拔出时回退内置麦，不跟随系统默认；共享有界输入恢复并保留已录内容
- **录音时静音电脑声音**：在「声音与界面」开启后，两种麦克风模式都会静音电脑播放（含耳机）；停止收音恢复原状态，默认关闭，下次录音生效；静音失败不再中断收音
- **动态浮窗**：新增文字轻柔淡入，换行时平滑增高，文字保持正常排版；收音时显示文字预览和全宽音频柱，松键后保留预览，音频柱收拢、淡化为 `thinking` 和全宽渐变光带；浮窗从小点张开，完整定稿、润色完成后缩回小点消失，支持系统「减少动态效果」

## 常用工具对比

下表为同类型桌面语音输入工具的技术特征对比。Setem 采用 Swift 原生实现，使用 MIT 许可证并免费提供。

| 工具 | 框架 | 安装体积减少 | 内存减少 | 许可证 | 价格 |
|---|---|---:|---:|---|---|
| **Setem** | Swift 原生 | 基准 | 基准 | MIT | 免费 |
| **OpenLess** | Rust + Tauri | **-92%** | **-44%** | AGPL-3.0 | 核心/BYOK 免费；云服务收费 |
| **Handy** | Rust + Tauri | **-81%** | **-46%** | MIT | 免费 |
| **VoiceInk** | Swift 原生 | **-95%** | **-58%** | GPL v3 | 自编译免费；预编译买断 |
| **Typeless** | Electron | **-99%** | **-92%** | 闭源 | 订阅制 |

## 安装

从 [Releases](../../releases) 下载 `Setem-x.y.z.dmg`，打开后将 Setem 拖到「应用程序」。

发布包为 ad-hoc 签名、未经 Apple 公证，首次运行前需解除隔离：

```bash
xattr -dr com.apple.quarantine /Applications/Setem.app
```

要求 macOS 15+。通用包，Apple 芯片与 Intel 均可直接运行，无需安装任何依赖。

## 使用

1. 启动后出现在菜单栏（麦克风图标）。图标被刘海或菜单栏管理工具挡住时，再次打开 Setem.app 即可弹出设置
2. 按提示授予 **辅助功能**（监听快捷键、上屏）和 **麦克风** 权限
3. 在设置中选择渠道、快捷键、麦克风，然后在任意输入框中说话

设置窗口按「识别渠道」「快捷键」「声音与界面」「权限」分为四页。渠道对比位于「识别渠道」页，可录音一次并比较各渠道的实际识别结果与耗时。

| 设置项 | 默认值 |
|---|---|
| 识别渠道 | 豆包输入法 |
| 长按快捷键 | 右 ⌥ |
| 点按快捷键 | 右 ⌘ |
| 长按并发送 | 右 ⌃ |
| 浮窗大小 | 紧凑（可切换标准，提供更宽预览与稍大字号） |
| 去除末尾标点 | 关闭；开启后，输入前仅移除末尾的一个标点，保留句中标点 |
**本地模型**：首次选择「本地模型」渠道时会先询问是否下载引擎库（约 8MB，来自上游 [offline-libs](https://github.com/J3n5en/voicekey/releases/tag/offline-libs) Release）和模型（约 177MB，来自字节 CDN），保存在 `~/Library/Application Support/OpenVoice/offline/`。之后断网也能用；识别时会在后台进程中占用约 1GB 内存，空闲 5 分钟后自动释放，也可随时在设置中删除。当前发布包只重命名为 Setem，为兼容原 OpenVoice 的配置和数据，本地存储路径暂不迁移。

单个修饰键可同时作为长按键和点按键：快速点一下为点按，按住超过 0.3 秒为长按。设为组合键的点按快捷键会被 Setem 拦截，不再传给前台应用。
长按并发送与长按快捷键一样通过选择器选择；如果与长按或点按快捷键冲突，会自动换到可用按键。

## 从源码构建

```bash
./build.sh            # 产物在 build/OpenVoice.app（arm64 + x86_64 通用包；发布包重命名为 Setem.app）
```

- 只需 Xcode 命令行工具；Opus 由 `Scripts/opus.sh` 从官方源码编译为通用静态库，首次构建自动下载并校验
- 本地自动生成并复用 `OpenVoice Self-Signed` 固定签名证书；可用 `SIGN_IDENTITY` 指定证书，`-` 为 ad-hoc
- `VERSION` / `BUILD` 环境变量设置版本号
- 打包 DMG：`./Scripts/dmg.sh build/Setem.dmg`（窗口布局与背景见 `Scripts/dmg/`）
- 调试识别链路：`build/OpenVoice.app/Contents/MacOS/OpenVoice --test doubao|wetype file.wav`
- 渲染听写预览（不收音、不上屏）：`build/OpenVoice.app/Contents/MacOS/OpenVoice --preview-hud --hud-text "明天下午四点开会，请带上完整测试报告。" --thinking --snapshot /tmp/openvoice-preview.png`
- 语音与音频回归基线（含快捷键预录、定稿确认、续录、连接复用）：`./Scripts/test.sh`；见 [语音输入回归基线](docs/dictation-baseline.md) 与 [上游流程对齐契约](docs/dictation-parity.md)

## 发布

推送 `v*` 标签后，GitHub Actions 自动构建并创建 Release：

```bash
git tag v0.2.0 && git push origin v0.2.0
```

## 实现

| 文件 | 内容 |
|---|---|
| `Doubao.swift` | 豆包：设备注册、WebSocket + protobuf 流式识别 |
| `WeType.swift` | 微信：secp128r1 ECDH、AES-256-ECB、snappy、protobuf 流式识别 |
| `Offline.swift` | 本地模型：资源下载与校验、识别子进程管理 |
| `CHanbao/` | 在 macOS 进程内加载安卓 ELF 引擎库（ELF 加载器 + bionic 兼容层） |
| `Audio.swift` | AudioQueue 采集 16kHz 单声道、音量计算、设备枚举 |
| `System.swift` | 全局快捷键（CGEventTap）、上屏 |
| `DictationHUD.swift` / `DictationPreviewTextView.swift` | 浮窗预览、文字淡入、从小点展开与收缩退出 |
| `Core.swift` | Opus 编码、protobuf 编解码、WebSocket 封装 |
| `Scripts/icon.swift` | 将 `docs/icon.png` 生成各尺寸 App 图标 |

音频以 20ms 一帧 Opus 编码后上传。识别设备身份在本机运行时生成，保存在 `~/Library/Application Support/OpenVoice/`。

## 声明

本项目通过分析输入法客户端协议实现，仅供学习与个人使用，与字节跳动、腾讯无关。接口可能随时变更或失效；语音会发送到对应厂商的服务器。

## 致谢

本项目基于 [VoiceKey](https://github.com/J3n5en/voicekey) fork 而来，感谢原作者 [J3n5en](https://github.com/J3n5en) 的出色工作。
