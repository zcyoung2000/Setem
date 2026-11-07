# AirPods 首尾漏录排查

2026-11-07。用户报告 AirPods 比内置设备更容易失败，并明确主要现象为
“能出文字，但经常缺开头或结尾”。

## 本机证据及边界

- 系统默认输入、播放及提示音输出均为 AirPods；输入为 24 kHz，应用收音
  目标为 16 kHz 单声道。当前输出被正确识别为耳机，静音申请没有写入设备
  静音/音量属性。最近 30 分钟日志未找到明确的启动失败或 underrun 记录。
- 独立 AudioQueue 时序探针中，冷启动首个回调约 345 ms；后续数轮约
  87–105 ms。这是从创建队列起算的回调时间，不等于全部时长的语音丢失。
- 立即停止的极短收音测试出现过 0 样本。仅在停止前调用 AudioQueueFlush
  的对照试验未体现样本数改善，因此没有采用该方式作为修复。
- 改为 AudioQueueStop(false)、停止重新入队、等待 IsRunning 变为 0，
  同类短录音可以收到原先仍在排队的音频。修改后的生产 AudioQueueSource
  在本机四轮短收音中均正常结束，排空约 131–171 ms，没有报错。

探针只在内存中消费音频，结果仅保存时序/帧数，不保存声音或向识别服务上传。
上述证据验证音频交付与停止时序，不能证明某句话在真实服务上的识别准确率，
也不能据此断言用户报告的所有缺字均出于同一原因。

原始结果位于 `/tmp/openvoice-airpods-timing-before.json`、
`/tmp/openvoice-airpods-short-before.json`、`/tmp/openvoice-airpods-drain.json`、
`/tmp/openvoice-airpods-source-after.json`。

## 修改

- 仅蓝牙麦克风在松键后保留该源的队列、分帧缓冲与输出流，让系统完成排空，
  再补齐最后一帧并结束音频流；识别定稿继续由 DictationSession 管理。
  初版全设备排空的范围已按用户对额外延迟的反馈收窄：停止时读取队列实际
  输入设备的 Bluetooth/Bluetooth LE 传输类型；内置、USB、有线及未知输入
  保留同步结束，不启动排空计时。AirPods 仅用于播放时不触发这段等待。
- 排空只影响所属源，最多等待 750 ms。超时或底层操作失败写入该段的失败
  快照，完成清理，沿用失败保留临时文字的规则。旧段排空不更新后续浮窗音量。
- 不再忽略设备选择、分配缓冲、提交缓冲、启动和停止等操作的返回错误。
- 修复预录源在 take() 前结束时清空已收音频、随后返回永不结束的流的问题。
  现在交付已缓存的帧并正确结束。

蓝牙在开麦前未交付的声音无法事后恢复；没有加入后台常驻收音或改变用户选定
的麦克风。若仍主要缺开头，可在应用的麦克风选择中固定使用 MacBook 内置
麦克风，继续用 AirPods 播放，以避开蓝牙麦克风开麦路径。

## 回归与依据

先补充预录结束回归，在旧实现上以超时失败，修复后通过。受控排空测试断言
精确最终文本 `开头和结尾。`，覆盖松键后尾帧、最后不足一帧的补零、提交等待、
续录隔离、旧音量回调、启动失败和排空超时。临时恢复立即停止后，完整定稿
回归拒绝该故障；恢复修改后执行 `./Scripts/test.sh`。

初版门禁 121 项通过、0 失败（2026-11-07 22:18）；完整日志为
`/tmp/openvoice-airpods-final-tests.log`。显式选择内置麦克风的实际收音检查也
正常完成，没有更改系统或应用的默认麦克风偏好。修改版尚未替换当前安装。
本地 Apple Development 证书动态选择的通用构建已完成，产物
`build/OpenVoice.app` 通过严格签名验证，非 ad-hoc；构建日志为
`/tmp/openvoice-airpods-build.log`。

范围收窄后新增两项回归，覆盖内置、USB、Thunderbolt、虚拟/未知输入同步结束，
Bluetooth LE 及中途输入变化。内置输入实机检查：显式选择时停止约 4.85 ms，
跟随系统默认时约 1.73 ms，没有再等约 150 ms 的排空；两种路径均读取到实际
内置传输类型。默认队列可能返回空设备 UID，因此需要查询当前系统默认输入。
结果 `/tmp/openvoice-input-route-after.json`；此轮 AirPods 已断开，蓝牙路径采用
受控回归，前一轮 AirPods 实测结果仍见上文。
收窄范围后的最终门禁 123 项通过、0 失败（2026-11-07 22:41），日志
`/tmp/openvoice-airpods-scope-final.log`。
已重新构建并验证 `build/OpenVoice.app` 的 Apple Development 签名，日志
`/tmp/openvoice-airpods-scope-build.log`；尚未替换 `/Applications/OpenVoice.app`。

- [Apple AudioQueueStop](https://developer.apple.com/documentation/audiotoolbox/audioqueuestop(_:_:))：
  false 会异步等待已排队缓冲完成，应用仍需接收排空期间的回调。
- [Apple 蓝牙耳机麦克风说明](https://support.apple.com/en-us/102217)：
  使用耳机麦克风会切换蓝牙音频工作模式；该说明解释设备差异，不作为本项目
  漏字修复已完成实机语音验收的证据。
