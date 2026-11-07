# VoiceKey 语音输入行为对齐契约

2026-11-07 用户最新要求覆盖 P3：删除语音活动/静音及未开口自动结束，
相关专用用例退役。点按改为手动开始、再次点按或点击浮窗结束并提交；
等待定稿时重复点按不再续录或取消，长按续录及其他音频/定稿规则保留。

2026-11-07 用户明确删除多渠道模式：候选选择、并行识别模式、选择键及配置归一化相关的 P4–P8、P14、P15 为历史契约，相关生产实现及专用测试已移除。单渠道预录、续录、段落顺序、引擎池与空定稿规则继续有效，长按发送仅发送当前渠道的完整定稿。当前浮窗进出场为小点展开/收缩，见 [预览约定](dictation-preview.md)。

对照上游 `main@3ba017826eef7fac405198510b03859eb5b6c8c4`。本轮按用户“完全一致”的要求对齐当前支持渠道的输入流程；会议转写、长按发送为 OpenVoice 扩展，继续保留。新增渠道、其他平台或整套界面迁移不在此输入流程契约内。

2026-11-06 用户明确改为 [浮窗预览与一次性输入](dictation-preview.md)：删除实时上屏分支及设置开关，等待时保留预览并显示 `thinking`，完整定稿后一次性输入。以下矩阵中的实时键盘差异修正为历史规则；成功空定稿统一采用 P9 的非流式语义，错误保留临时稿。其他识别、预录、续录、候选及连接规则继续有效。

用户随后明确显示方式：“去掉波形保留弹窗，提示改为 thinking”。现在松键后移除波形，保留浮窗显示小写 `thinking` 与加载指示，完整定稿和润色完成后关闭；等待时的临时回包不覆盖此提示。整体时序沿用上游，提示文字按用户要求替换。对应回归见 [浮窗状态回归](dictation-hud-regression.md)。多渠道候选的定稿选择流程保留。

## 需求、风险和验收依据

上游来源：`app/src-tauri/src/controller.rs` 的 `hot/arm/take_primed/partial/resume/choose/Segments`，以及 `wetype.rs/qwen.rs` 的独占连接借出与归还。此前自选的英文边界空格、非流式保留空定稿等策略必须让位于上游规则。

以下矩阵先于本轮测试代码建立。每行覆盖正常与反向路径，断言实际产物（音频帧、最终文本、确认回调、停止次数、复用实例），不以内部方法调用次数作为唯一判定。

| 契约 | 风险与场景 | 精确验收 / 测试 |
|---|---|---|
| P1 按下即预录，最多缓存 50 帧；取消短按丢弃，确认录音转交缓存和后续帧 | 首音缺失、无限缓存、取消后污染下一段 | `testPrerollTransfersBoundedFramesAndTail`、`testDiscardedPrerollCannotLeakIntoNextRecording` |
| P2 预录后的旧泵不能停新录音或关闭新流 | 松手后仍有尾帧，下一段已开始 | `testOldCaptureDrainCannotFinishNextRecording` |
| P3 音量大于 0.3 或有效临时文本变化都算语音活动；重复文本和定稿不刷新活动；8 秒未开口退出 | 小声提前停、重复回包永不停、旧段迟到文本计时 | `testQuietSpeechExtendsActivityButRepeatedTextDoesNot`、`testSilenceCanBeDisabledAndInitialSilenceExpires` |
| P4 多渠道每次续录给每行增加一段，按录音顺序连接；候选等待不取消旧稿 | 部分渠道先完成、续录清空前段、共享连接互相关闭 | `testPickResumeRetainsEveryChannelsFinalsInOrder` |
| P5 识别中确认仅记待选择；所选行定稿后才上屏；错误/跳过行不提交 | 中间稿缺尾字/缺润色、错误行误提交 | `testPickConfirmationWaitsForPolishedFinal`、`testPickRejectsFailedAndSkippedRows` |
| P6 待选择行失败时改选可用定稿；继续录音清除旧待选择；完成最多一次 | 自动提交错误行、续录时误发送上一段 | `testPendingFailedChoiceFallsBackToFinal`、`testResumeClearsPendingChoice` |
| P7 数字键第一次选行、同一行再次数字键确认；方向键更新选择；记住上次渠道和选择次数 | 自动选择抢走手工选择、排序不稳定 | `testPickerDigitsHistoryAndManualSelection` |
| P8 所有渠道结束后取消旧等待超时，继续显示候选；Esc/超时隔离旧任务 | 完成的候选 15 秒后消失、旧任务污染新会话 | `testFinishedPickerInvalidatesTimeoutAndOldCallbacks` |
| P9 原样连接多段文本；空成功定稿仅流式保留临时文本；错误总保留临时文本 | 拼接擅加空格、服务端撤回仍粘贴、失败擦字 | `testTranscriptMatchesUpstreamJoinAndEmptyFinalRules` |
| P10 每次录音借出一个独占引擎；空闲引擎可预热和复用，失败/取消的不归还 | 共享并发握手、每句重建连接、旧取消关掉新连接 | `testPoolWaitsForWarmupAndNeverSharesBusyEngine`、`testPoolReusesSuccessButDiscardsFailure` |
| P11 千问旧读取消必须退出且不能消耗下一轮数据；超时/断开必须唤醒等待；分片与长回包必须完整解析 | 旧任务抢下一句首包、取消后挂起、长句丢包 | `testCancelledQwenReadCannotConsumeNextRound`、`testQwenReadTimeoutAndCloseReleaseWaiter`、`testQwenSocketReusePreservesPacketsAfterCancelledRead` |
| P12 上屏差异修正包含完整尾字；自身生成的键盘事件不得再次触发快捷键 | 润色尾字没有进入事件、续录预录被自己的事件取消 | `testStreamTyperEmitsCompletePolishedTextAndFreezesOnFinish`、`testSyntheticEventsCannotTriggerPicker` |
| P13 按下到松开的完整链路必须传递预录与尾帧；已取消的长按计时不得提前确认下一次按键 | 单测各组件通过但组合仍丢首尾、迟到计时偷启动下一段 | `testHotkeyCaptureSessionAndPolishedInputWorkTogether`、`testCancelledHoldCannotConfirmNextPress` |
| P14 多渠道只运行设置中选中的现有渠道；去重并按可用渠道顺序规范化；少于两个则回退全部；续录固定会话渠道 | 忽略用户选择、运行不支持渠道、配置变化导致续录缺段 | `testMultiChannelConfigurationMatchesUpstreamNormalization`、`testPickerUsesSelectedChannelSetAndPinsItOnResume`；依据 settings.rs:normalize/controller.rs:begin |
| P15 候选面板可成为键盘焦点并自行处理方向/数字/确认键；隐藏后已排队的显示不能使其复活 | 安全输入时全局钩子收不到选择键、完成后面板重现 | `testPickerPanelCanReceiveKeysWithoutGlobalHookAndCannotReopenAfterHide`；依据 controller.rs:begin_multi/pick_show/secure_input |

不变量：会话/段/计时三种归属均须校验；音频尾帧由其原有流排空；只提交最终可选行；连接仍须遵守 `ConnectionLifetimeTests` 的释放规则。

验证分层：合成音频帧经生产状态机的可控制测试 → `./Scripts/test.sh` → Apple Development 签名构建。目标输入框的 CGEvent 投递兼容性另做真实界面验收，不将模拟识别结果测试称为实际供应商语音准确率测试。人工评审仍待交付后进行，不执行发布/合并。

## 2026-11-05 验证结果

- `./Scripts/test.sh`：63 项通过，0 失败；`swift test`：64 项通过，0 失败。
- 三项故障注入分别破坏候选定稿等待、引擎独占借出、自身事件过滤，对应测试均拒绝故障；恢复后再次执行上述检查通过。
- 候选面板键盘能力用例先复现普通无边框 NSPanel 无法成为键盘窗口，再验证修复后的本地按键路径及隐藏代次隔离。
- 生成 `build/OpenVoice.app`，包含 arm64 与 x86_64；动态选择本机 Apple Development 证书签名，并通过 `codesign --verify --deep --strict`，确认不是 ad-hoc。没有修改已安装应用。
- 生成后自查：测试使用生产类型与可观察的文本、帧、事件、选择结果和实例归属；供应商响应及超时显式控制。键盘事件只记录、不向用户应用投递；连接只访问本机回环。
- 供应商真实录音、目标应用输入框验收及人工评审未执行，不标为通过。

## HUD 后续复核范围

最新发现并修复流式完全空结果的关闭差异，以及上游也存在的 Unicode 事件分块风险。上游可选的 Jev、live_text、提示音、音量压低及自定义长按组合键尚未迁入；已支持功能的输入流程对齐不代表功能全集一致。具体边界、修复与 73/74 项最新测试结果见 [再次行为复核](upstream-behavior-review.md#hud-修改后的再次复核2026-11-05)。

## 豆包混合回包的明确修正

按用户要求修复长语音缺润色及后续缺字：有意修正固定上游版本 `doubao.rs::Transcript` 在无索引累计回包时清空句子定稿的行为，保留纯累计输入及按 index 排序/修订、joinSentences 规则。累计最终快照优先，同时区分快照定稿与 SessionFinished，允许录音继续产生尾部；不会仅凭首句定稿永久忽略无索引回包。范围、对齐回退边界及 15 项专项/93 项基线结果见 [豆包回归](doubao-transcript-regression.md)。会话、候选、引擎池、会议扩展及长按发送约定不变。
