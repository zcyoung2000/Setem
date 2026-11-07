# 电脑播放声抑制与 TLS 排查

2026-11-07，基于用户已经删除会议转录的当前代码实施。

设置「声音与界面 → 抑制电脑播放声音」是原生开关，默认关闭。
每次硬件录音开始时快照开关和麦克风 UID；中途切换不打断当前录音，
下次收音生效。按键预录、长按松手、点击浮窗或再次点按结束、等待定稿、
长按续录及长按发送仍共用现有 DictationCapture / DictationSession 链路。
渠道对比使用同一个 Recorder，也应用此设置。

系统初始化在本机约需 1.5 秒，不能放在 CGEvent tap 或 UI 线程内。
开启时浮窗先显示「正在准备麦克风…」，提示消失后再开始说话；硬件在
后台的串行队列启动。准备期间结束会立即关闭对外音频流，排队清理设备，
旧设备关闭之后才允许新录音启动；关闭开关后紧接着录音同样遵守此顺序。
每段独立保存启动错误，完成时报告错误，不取消正在等待的其他段定稿。

关闭时仍用 AudioQueue 的 16 kHz / 单声道 / Int16 采集路径。
开启时使用 AVAudioEngine 的 VoiceProcessingIO，通过系统播放参考做
声学回声消除。只采麦克风，不创建系统音频采集、不恢复会议功能。
关闭自动增益，避免放大残余背景声；其他音频 ducking 使用 advanced + min。
电脑继续播放，macOS 可能调低播放音量；不同麦克风/扬声器组合的效果不同，
不能承诺消除所有播放声或其他设备发出的声音。失败明确提示切换麦克风
或关闭开关，不静默退回未处理的录音。

VoiceProcessingIO 要求客户端输入/输出格式一致。本机实测初版由于
默认输出格式与输入不匹配，在 start 报 -10875；现把静音混音器到输出
节点的连接显式配置为单声道输入格式，且不把麦克风连接到扬声器监听。
聚合设备可能暴露 9 个声道，不能使用默认扬声器布局降混：实机对照
发现有声音的 tap 经默认转换后变成零。有效的离散 9 声道回归在修复前
因音频内容为零而失败。现以单声道作为 IO 客户端格式，转换器显式映射
处理后麦克风的第 0 声道；2/9 声道样本的音量与精确尾帧均有回归。
设置列表排除本应用的临时 VPAUAggregateAudioDevice。
tap 输出转换成既有 20 ms 帧；每次收音独占转换器/帧接收器，锁保护
push 与 finish，结束时补齐尾帧，迟到回调不能影响下一次收音。

依据：[Apple setVoiceProcessingEnabled](https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:))、
[Apple other-audio ducking](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration)、
本机 AVAudioIONode.h 与 AudioUnitProperties.h。

## 验证

新增七项 Recorder 回归：默认关闭/逐次快照设置、录音中不替换源、失败清理
及重试、保留精确尾帧且拒绝旧 tap、48 kHz 双声道及 9 声道 Float32 转标准帧。
新增原生设置开关交互、关闭/重开持久化及再次关闭的回归。
慢启动受控回归在实施异步化前失败；修复后即使设备启动仍被门闩阻塞，
快捷键回调也已返回。取消准备/切换回普通录音回归验证先关闭旧设备，
迟到 ready 不改变新状态；两个 Session 回归验证精确保留其他段定稿，
旧启动失败不能停止新录音。

Apple Development 签名的本地临时探针使用当前生产录音源码，连续执行
普通 → 抑制 → 普通 → 指定麦克风抑制，各收音 1.2 秒，依次得到
61、60、63、60 个有效帧，均为 320 样本。开启时调用方返回耗时分别为
0.214、0.093 毫秒；设备实际就绪约 1.49、1.50 秒。只统计帧数/音量，
不保存或上传收音内容。记录为 `/tmp/openvoice-echo-async-hardware.json`。

最终 `./Scripts/test.sh` 共 111 项、0 失败（2026-11-07 17:35），包括
7 项 Recorder、16 项 Session 和 10 项原生设置回归。

已检查激活的原生发布设置窗口：新开关默认关闭，四项控件右边缘对齐，
原生工具栏无额外焦点环。截图为 `/tmp/openvoice-echo-settings-active.png`。
最终通用发布包（arm64 / x86_64）以本机 Apple Development 证书签名，
严格签名校验通过；已备份旧版至 `AppBackups/20261107-174127/OpenVoice.app`，
替换并启动 `/Applications/OpenVoice.app`。安装版与构建版可执行文件哈希
一致，安装记录为 `/tmp/openvoice-echo-install.json`。

修正格式后的低音量合成语音播放实验以相同文件执行普通 → 抑制 → 普通，
每轮约 3.5 秒，丢弃前 60 帧后 RMS 分别为 0.08327、0.007805、0.09695。
另一个临时探针仅旁路系统语音处理，同一 IO/帧转换链路 RMS 为 0.03187，
确认输入没有被静音或格式转换成零；旁路代码不进入产品。
此为本机播放场景的结果，包含系统 ducking，不等同于纯回声消除指标，
不能外推为所有设备和真人同时说话时的抑制比例。
记录为 `/tmp/openvoice-echo-playback-active-verified.json`、
`/tmp/openvoice-echo-playback-bypass-verified.json`。

## TLS 截图排查

本机系统日志在 15:34:56、15:35:17、16:36:17 记录三次 -1200，底层
均为 -9816。Apple SDK SecBase.h 将 -9816 定义为 errSSLClosedNoNotify，
即对端没有通知便关闭连接。15:34:56 的详细日志显示握手连接经过 utun4，
约 18.3 秒后失败，HTTP 尚未交换数据（0/0 bytes）；16:51:02 的另一条
连接证书校验为 OK，TLS 1.3 / HTTP 1.1 成功。

Core.WebSocket 使用系统 URLSession 默认 TLS 校验；微信新建客户端失败
会关闭 socket，复用失败和取消路径已有独立回归。未找到可以确认导致
截图错误的代码缺陷。证据更符合网络/隧道或服务端提前断连，但无法仅凭
客户端日志确定是哪一端。按用户要求，本轮不改连接/证书/重试行为。

日志为 `/tmp/openvoice-echo-tls-system.log`、
`/tmp/openvoice-echo-tls-detail.log`。
