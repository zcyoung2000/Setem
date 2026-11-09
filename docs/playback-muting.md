2026-11-09 更新：当前静音覆盖耳机和扬声器。播放控制失败独立告警，保留监听以便控制恢复后继续静音；不能停止麦克风。断开的设备按 UID 保留原状态，重连后恢复，完成后移除监听。两种输入模式与回归见 [麦克风路由契约](microphone-routing.md)。下文 2026-11-07 的耳机排除和播放失败停录描述为历史设计，已退役。

# 录音期间静音

2026-11-07。用户接受录音期间暂时静音，以避免 VoiceProcessingIO 每次约1.5秒的初始化，并要求耳机不静音。

## 行为

设置 → 声音与界面 → **录音时静音电脑声音**，默认关闭。沿用原 `suppressPlayback` 偏好，保留已启用用户的选择；中途更改设置在下次硬件收音时生效。

收音前静音实际默认播放输出和系统提示音输出；停止收音时恢复，不等识别/润色完成。预录取消、松开长按、再次点按、点击浮窗、启动失败、识别失败及正常退出均回收相应所有权。普通收音和开启静音的收音都使用原有 AudioQueue 路径，不再建立 VoiceProcessingIO、系统音频采集或后台常驻麦克风；移除准备麦克风提示及专属慢启动包装。

通过 Core Audio 流终端类型、内置耳机设备 UID 和耳机数据源判断耳机，跳过该设备。不能用 Bluetooth/USB 连接类型判断耳机，蓝牙音箱也需要静音。系统未报告耳机类型的设备按外放处理，不能保证识别所有第三方耳机。监听录音期间的输出/设备/数据源变化，切换耳机时恢复原外放，切换外放时静音新设备。多输出设备展开到实际子设备，系统提示音单独走扬声器时仍处理扬声器。

优先使用设备静音属性；不支持时使用主音量或每声道音量，结束时恢复各自原值。原本静音的不主动打开；恢复时如果用户已改变所控制的值则保留其调整。恢复前核对 UID，避免设备数字 ID 回收后误改另一台设备。

不支持系统静音/音量控制的外放明确报错，不静默收录未静音的播放声。收音中切到不支持的设备，结束本段流、保留尾帧并报告失败；其错误快照不能停止或污染下一段。只对当前默认播放、系统提示音及其多输出子设备操作，其他应用自行指定的独立输出不在覆盖范围。

`PlaybackSilencer` 为听写与渠道对比共享引用计数。一个录音结束不能提前恢复另一个录音仍需静音的输出；状态只在开始/结束及设备变化时更新，闲置没有音频处理或轮询。正常退出清理全部静音所有权。硬件断开或进程被强制终止时无法保证恢复未连接设备的硬件状态。

## 验证

2026-11-08 现场：点按快捷键失效时，进程 CPU 约105%，3秒线程采样的
全部主线程样本均位于 `PlaybackSilencer.routeChanged`，主要耗在 Core Audio
监听的移除/添加；原始证据 `/tmp/openvoice-live-unresponsive-sample.txt`。
设备通知处理中无条件重订阅会放大通知，使主队列无法及时处理快捷键和
浮窗退出。修复验收：同一路由反复通知不得重新订阅；实际设备集合变化时
只增删变化的监听；停止后迟到通知不得恢复监听。保持耳机切换、引用计数、
失败回滚和尾帧语义，运行完整 `./Scripts/test.sh`。

修改前新增受控回归失败：100次路由通知产生101次监听注册。修改后
静音/Recorder专项14项通过；最终完整门禁125项、0失败（00:15:20），
日志 `/tmp/openvoice-route-loop-final-tests.log`。已构建并严格验签本机
Apple Development 签名的通用安装包；此时仅准备安装包和旧版备份，
未替换运行中的应用。真实耳机/多输出设备切换仍未作实体硬件验收。

同类卡顿复核发现第二条可受控复现的路径：系统禁用 event tap 时如果
漏掉松键，旧 `HotkeyMonitor` 只重新启用钩子，仍保留 downCode/长按计时
和 active 状态，导致预录/长按持续占用麦克风或恢复后第一次点按无效。
新增两项回归在修改前共12处断言失败。恢复时清除旧按键及计时归属，
预录走 disarm，已确认长按走正常 end 等完整定稿；手动点按录音继续
遵守显式停止规则。覆盖超时/系统禁用、迟到计时、精确尾帧及最终文字、
恢复后第一次点按与长按；已有点按测试扩展系统中断组合。

另以修改前/后的生产 Core Audio 监听分别进行2秒被动探针：均收到0次
设备通知，均正常退出，因此这次被动探针没有复现现场，也不作为故障
消除的硬件证明。结果 `/tmp/openvoice-route-review/real-hardware-results.json`。
复核了 HUD 设置通知合并、音频回调队列、WebSocket 取消及离线工作线程，
未找到第二处相同的全量监听重注册；此结论不保证所有主线程原生调用
都无短时延迟。

复核后的最终完整门禁127项、0失败（2026-11-08 00:21:34），日志
`/tmp/openvoice-similar-stalls-full-tests.log`。两条修复均已纳入重新构建的
Apple Development 签名通用安装包，并通过严格签名校验；安装记录仍为
`installed: false`，本机实际录音及实体设备切换验收待安装后进行。

使用隔离偏好、模拟输出设备与受控音频源覆盖：默认关闭、逐段快照、静音先于收音、立即恢复后仍可消费精确尾帧 `[101, 102]`、启动失败清理和重试、正常析构、耳机/未知类型/外放混合、设备切换、多个录音所有权、用户原有静音/音量调整、部分声道操作失败回滚、系统提示音输出、收音中设备失败、迟到失败不能停止下一段，以及原生开关重开持久化。旧回声引擎的专属初始化/聚合转换测试随实现退役，其余听写与设置门禁保留。

本机实际 Core Audio 控制验证：当前一个非耳机输出，三轮静音属性均从0变1、结束后恢复0；静音申请耗时1.70–7.86毫秒。只读取/切换输出控制，没有录制、保存或上传音频；原始结果 `/tmp/openvoice-mute-hardware.json`。该数字不包含普通麦克风启动、识别网络或最终输入耗时。本机无其他实体耳机可作切换验收，耳机/多输出切换采用受控回归，不冒充所有设备的实机验证。

最终 `./Scripts/test.sh` 共116项、0失败（2026-11-07 18:58），包含6项 Recorder、6项静音所有权及10项原生设置用例；完整日志 `/tmp/openvoice-mute-final-tests.log`。

动态选择本机 Apple Development 证书构建 arm64 / x86_64 通用发布包，并严格验证签名。已检查激活发布设置窗口：新开关、耳机/恢复说明完整，原生工具栏无额外焦点环，四项控件右侧对齐；截图 `/tmp/openvoice-mute-settings-active.png`。

已备份旧版到 `/Users/Henry/Library/Application Support/OpenVoice/AppBackups/20261107-190057/OpenVoice.app`，替换并启动 `/Applications/OpenVoice.app`。安装包通过严格签名验证且可执行文件与构建版哈希一致；SHA-256 `0768d57aa144973d4aa18d4d90330f7015949e61b599b95e4c5da67e4dad0d99`。安装记录 `/tmp/openvoice-mute-install.json`。

## 依据

- [Apple Core Audio mute property](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertymute)
- [Apple AudioObjectSetPropertyData](https://developer.apple.com/documentation/coreaudio/audioobjectsetpropertydata(_:_:_:_:_:_:))
- 本机 SDK `AudioHardwareBase.h` 的 `kAudioStreamPropertyTerminalType`、`kAudioStreamTerminalTypeHeadphones`，及 `AudioHardware.h` 的设备/数据源/静音属性。
- [Wispr Flow 官方静音说明](https://docs.wisprflow.ai/articles/7231650589-auto-mute-music-while-dictating-on-macos-how-audio-detection-works)，作为该产品行为的实际采用例，不作为本项目耗时或全部设备兼容性证据。
