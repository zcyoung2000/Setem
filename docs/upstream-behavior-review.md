# 与 VoiceKey 原项目的行为复核（2026-11-05）

对照：[J3n5en/voicekey main@3ba017826eef7fac405198510b03859eb5b6c8c4](https://github.com/J3n5en/voicekey/tree/3ba017826eef7fac405198510b03859eb5b6c8c4)。范围由用户确认：“对齐语音输入流程，保留本项目扩展”。本项目继续使用原生 Swift，保留会议转写、长按发送和现有外观；不迁入新识别渠道、Tauri 界面或自动更新。

## 已对齐的输入流程

| 场景 | 对齐后的行为 | 上游依据 / 本地实现 |
|---|---|---|
| 长按起始、取消短按 | 按下即开麦，保留最多 50 帧预录；长按 300ms 确认后转交预录，取消则丢弃。旧计时不能确认新按键 | controller.rs:arm/take_primed、hotkey.rs / DictationCapture、HotkeyMonitor |
| 松键尾帧 | 每段音频由其原有流排空，旧泵不会写入或关闭下一段 | Gate::Forward / DictationCapture |
| 低音量点按输入 | 音量大于 0.3 或临时文本确实变化均刷新语音活动；重复文本和定稿不刷新。未开口 8 秒结束；支持关闭静音结束 | controller.rs:partial/speaking/check_silence / DictationActivity |
| 单渠道等待时续录 | 保留各段定稿，按录音顺序连接；固定开始时的渠道和上屏模式；旧回调和旧超时不得影响新会话 | controller.rs:resume/Segments / DictationSession |
| 多渠道参与配置 | 只运行选定的现有渠道，至少两个；去重并按平台可用渠道顺序规范化，无效配置回退全部；会话内续录固定该组合 | settings.rs:normalize、controller.rs:begin / Channel.selectedMulti、DictationPicker |
| 多渠道续录 | 候选未关闭时可继续说，每个渠道追加一段并保留前文；继续录音清除旧的待确认状态 | controller.rs:resume / DictationPicker |
| 未定稿候选确认 | Listen/Wait 只记录待选择、停止收音，等所选行定稿后上屏；不提前提交中间稿 | controller.rs:choose / DictationPicker.choose |
| 候选失败与选择 | Error/Skip 拒绝提交；待选择渠道失败则等待或改选可用定稿；手动选择不被更早完成的渠道抢走 | controller.rs:done/choose / DictationPicker |
| 数字键与历史 | 数字键选中，已选行再次按同一数字确认；方向键/回车选择；保存上次渠道，按选择次数稳定排序 | controller.rs:pick_key/begin_multi/choose / DictationPicker、PickHUD |
| 安全输入下的候选按键 | 无边框候选窗口可接收键盘焦点，窗口内自行处理方向、数字与确认键，不依赖全局钩子；隐藏使排队的显示作废 | controller.rs:begin_multi/secure_input / PickPanel、PickHost、PickHUD |
| 结果全部完成 | 取消识别等待超时并保持候选；Esc 取消且不补写；异常超时保留选中行的已识别文字 | controller.rs:done/abort / DictationPicker |
| 拼接与空定稿 | 多段原样连接，不额外添加英文边界空格；空成功定稿仅流式保留临时文本，失败保留临时文本；定稿后拒收迟到临时文本 | controller.rs:Segments / DictationTranscript |
| 连接预热、复用 | 每段独占借出引擎，等待预热完成；成功且未取消才归还空闲池。千问复用前取消并等待旧读任务结束；释放最后持有者时关闭资源 | wetype.rs/qwen.rs / DictationEnginePool、QwenInbox、连接析构 |
| 润色上屏与事件过滤 | 最后润色稿按差异修正到键盘事件；自身事件带原版相同标记，快捷键钩子忽略，避免打断预录或误触发确认 | platform/mac.rs / StreamTyper、TextInserter、HotkeyMonitor |

千问原始 WebSocket 还补上可取消的单读泵、真正的等待超时、分片合并和 64 位长度回包解析，避免在复用时抢包或截断长结果。渠道对比工具使用同一独占池，取消后的旧任务不能覆盖新一次对比。

## 保留的本项目扩展

- 会议转写及暂停、恢复、回退、归档流程保留；离线会议分片仍使用独占 worker。
- 长按发送保留。单渠道等待全部分段最终完成后发送；多渠道采用第一个无错误的非空定稿。全部失败时退出等待并提示，不自动回车。
- 原生设置、HUD 风格及现有快捷键配置继续使用；候选只补充本轮输入流程需要的状态和数字键提示。

## 验证与边界

需求、风险、场景和精确断言见 [对齐契约](dictation-parity.md)。语音/连接/会议音频基线 63 个测试通过；本机全量 swift test 64 个测试通过，原有会议窗口动画测试单独运行也通过。没有修改会议窗口生产代码或放宽其断言；此前该窗口用例的失败保留在历史记录中。

测试使用可控制识别响应、经生产控制器传递的合成音频帧、真实 CGEvent 产物以及真实本机回环 TCP/WebSocket。没有自动向微信或 super.engineering 输入框重放语音，也未访问供应商识别接口，故不将这些结果当作识别准确率或所有输入框兼容性的证明。

CI 与发布构建使用同一个语音回归入口；本次没有推送、发布或替换已安装应用。人工评审与目标输入框实机验收待进行。
