# Swift 渠道回迁记录（maint/swift-backport）

本记录对应 2026-10-02 legacy 冻结后 `main` 分支中，豆包、微信、千问、豆包离线四个既有渠道的协议与通用改进回迁。未合并 `main`，未新增渠道，未引入第三方 Swift 依赖。

## 逐项落实

1. **豆包设备注册 endpoint**：注册地址从 `log.snssdk.com` 改为 `log-klink.zijieapi.com`；删除 settings 拉取流程，改用官方客户端 1.4.6 内置 ASR app key，并保留上游注释说明 settings 下发 key 会被部分设备拒绝。上游：`181a136`、`82ae4f2`。文件：`Sources/VoiceKey/Doubao.swift`。
2. **豆包客户端身份**：`version_code`、`manifest_version_code`、`update_version_code` 对齐 `100406010`，`version_name` 为 `1.4.6`，`openudid` 改为 16 位十六进制随机数。上游：`82ae4f2`。文件：`Sources/VoiceKey/Doubao.swift`。
3. **豆包设备指纹随机化**：注册请求的 brand、model、Android/API、build、resolution、dpi、rom/rom_version、User-Agent 全部来自 17 个真实机型组成的设备池；随机 profile 随 `did` 缓存，旧缓存缺省回落 Pixel 7 Pro。上游：`18e8be7`。文件：`Sources/VoiceKey/Doubao.swift`。
4. **豆包识别参数与累积结果**：`enable_asr_threepass` 改为 `false`，twopass 保持 `true`；解析无 `index` 的 cumulative `results[0]`，按整段中间结果覆盖展示，同时保留原有按句定稿逻辑，定稿句与未定稿句拼接，避免重复/丢字。上游：`82ae4f2`。文件：`Sources/VoiceKey/Doubao.swift`。
5. **豆包 WebSocket 头**：Swift 原实现已有 `x-custom-keepalive: true`，本次保留；`proto-version: v2` 不变，User-Agent 改为随随机设备 profile 变化。上游上下文：`18e8be7`（连接头见 `main:crates/core/src/doubao.rs`）。文件：`Sources/VoiceKey/Doubao.swift`。
6. **豆包失败重注册与重放**：`SessionFailed` 且本次没有任何识别结果时，清除 `doubao.json`、重新随机注册设备，并用留底的原始录音完整重试一次；第二次仍失败则再次清除身份并合并原始与重试错误，避免循环。上游：`652b407`。文件：`Sources/VoiceKey/Doubao.swift`。
7. **千问 asr-only**：删除润色/翻译输出状态与对应 `transform`、text send/complete 分支；attach 的 `ai_polish_mode` 固定 `off`，结果只读取 ASR `content.text`；设置界面移除“千问输出”。上游：`72468d2`。文件：`Sources/VoiceKey/Qwen.swift`、`Sources/VoiceKey/Settings.swift`。
8. **微信协议**：已核对，`WeType.swift` 的注册、ECDH、AES、snappy、protobuf、语音请求协议均未改动；仅接入通用 leading-silence 音频层。文件：`Sources/VoiceKey/WeType.swift`。
9. **豆包离线**：已核对模型/引擎库 URL、大小、SHA-256/MD5 校验、下载移动方式、worker 子进程启动、100ms 喂入、空闲 5 分钟释放均与 main 一致；仅将 worker 停止从 SIGTERM 后不等退出改为 SIGKILL 后 `waitUntilExit()`，与上游 kill+wait 等价，避免残留僵尸进程。上游：`c2a262c`。文件：`Sources/VoiceKey/Offline.swift`。
10. **识别超时保留文字**：记录当前中间结果；非流式模式超时/失败时插入已有文字，流式模式保留已上屏内容；全部渠道对比模式超时时保留当前选中的候选。上游：`abb0ea8`。文件：`Sources/VoiceKey/AppDelegate.swift`、`Sources/VoiceKey/System.swift`。
11. **保留开头语音**：新增 `withLeadingSilence`，豆包/千问/微信先发送 200ms 静音给服务端 VAD 起音，再按 20ms 释放握手期间缓存的原始帧；离线引擎与 main 一致不垫静音，依赖 AsyncStream 在 worker begin 阶段缓存原始帧，均不丢弃字头。上游：`18e8be7`。文件：`Sources/VoiceKey/Audio.swift`、`Doubao.swift`、`Qwen.swift`、`WeType.swift`、`Offline.swift`。
12. **录音结束释放麦克风**：已核对，无差异。Swift `Recorder.stop()` 先 `AudioQueueStop`，同步收尾帧流并置空 continuation，再 `AudioQueueDispose`，当前实现已正确释放 AudioQueue/麦克风。上游：`6011a19`、`b0b301a` / PR #7。文件：`Sources/VoiceKey/Audio.swift`。
13. **蓝牙麦克风就绪后刷新列表**：已核对，无差异。Swift 设置页每秒调用 `Microphone.all()` 重新读取 CoreAudio 设备与输入通道；蓝牙设备从 0 通道变为可用后会自动出现，无需重连或重开页面。上游：`7077f25`。文件：`Sources/VoiceKey/Settings.swift`、`Audio.swift`。
14. **固定自签名签名**：新增本地固定证书生成脚本与专用 keychain 导入脚本；首次构建自动生成 `build/signing/voicekey.p12`（密码在同目录 `.password` 文件，均被 git ignore），后续构建复用同一证书。构建时优先 `SIGN_IDENTITY`，固定证书生成/导入/签名失败则回退 ad-hoc 并输出原因。上游证书思路：`11baced`（`main:Scripts/gen-cert.sh`）。文件：`build.sh`、`Scripts/gen-cert.sh`、`Scripts/ensure-signing-cert.sh`。

## 验证

- `./build.sh`：通过，生成 universal `build/VoiceKey.app`，实际使用 `VoiceKey Self-Signed` 固定证书签名；未触发 ad-hoc 回退。
- `codesign --verify --verbose=2 build/VoiceKey.app`：通过。
- 冒烟测试：仓库内未找到 wav 样例，未执行 `--test` 冒烟。

## 备注

- 固定证书位于 `build/signing/`；重新编译可复用。若删除该目录，会生成新的自签名证书，macOS 授权可能需要重新确认，因此请按需备份。
- 专用签名 keychain 只在用户钥匙串搜索列表中挂载，证书本身不提交到 git。

## 复查修复

- 千问按 main 语义以 `newRoundId` 标记 ASR 定稿，不再在首个 partial 后提前返回；同时为复用 Session 的会话状态加锁，避免收发任务并发读写。
- 豆包重放留底加锁；二次失败错误始终保留首次 `SessionFailed` 原因；握手任意失败均清除设备缓存。
- 离线引擎移除额外的 200ms 前导静音，与 main 输入一致。

## macOS 27 界面适配

- 修复 SwiftPM 在包最低平台为 macOS 15 时把 Mach-O `LC_BUILD_VERSION.sdk` 也记成 15.0 的问题；构建时显式记录当前 Xcode SDK 版本，保留最低系统 macOS 15。文件：`build.sh`。
- 设置窗保留标准标题栏与 grouped Form，避免 full-size Liquid Glass 嵌入红绿灯和点击时整窗抖动；打开设置时显式激活 accessory app 并置前窗口。录音 HUD 与多渠道候选浮层在 macOS 26+ 切换为 Liquid Glass，旧系统回退 `regularMaterial`。文件：`Sources/VoiceKey/AppDelegate.swift`、`Settings.swift`、`System.swift`。
