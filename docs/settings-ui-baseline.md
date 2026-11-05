# 设置界面回归基线

## 来源与需求

2026-11-05，原生设置页重构后，用户反馈「声音与界面」标签外出现蓝色外圈，且此前多次遇到类似问题。输入为用户截图，以及提交 7b2d7a5 的 SettingsView.swift / SettingsWindow.swift。

- F1：保留五页布局和原生控件；窗口激活、切页、重新打开后，不出现标签或按钮外的蓝色焦点环。
- F2：保留选中状态、键盘焦点、Tab 导航、方向键操作、快捷键录制和无障碍操作。控件的蓝色选中填充和开关状态属于正常反馈。
- F3：设置窗口与渠道对比弹窗遵循同一规则。新增控件与系统生成的工具栏控件也需要覆盖。
- F4：Scripts/test.sh 必须覆盖设置界面回归，本地、CI 和发布使用同一入口。
- F5：同组设置行的右侧控件实际可见边缘对齐。固定宽度容器内的原生控件必须使用尾部对齐；不能仅检查容器边框。

实现约束：只调整焦点外观，不能通过关闭系统键盘导航、移除控件的焦点能力、隐藏所有蓝色或全局修改 AppKit 类来掩盖问题。可编辑文字的焦点与光标需要保留。

## 风险与覆盖矩阵

| 风险 | 场景 | 优先级 | 需求 |
|---|---|---|---|
| 非激活窗口截图漏掉焦点环 | 激活真实设置窗口，让原生标签控件成为 first responder，再逐页切换 | P0 | F1 |
| SwiftUI 修饰符遗漏原生工具栏 | 检查实际生成的标签控件，而非仅验证 SwiftUI 状态 | P0 | F1/F3 |
| 去掉焦点能力导致键盘失效 | 标签控件仍可成为 first responder；通过原生无障碍操作切页；快捷键录制退出仍可用 | P0 | F2 |
| 修饰符作用域没有覆盖弹窗 | 打开渠道对比，再关闭并重开窗口 | P1 | F1/F3 |
| 回归没有进入发布门禁 | 默认测试入口执行 SettingsWindowTests | P0 | F4 |
| 系统原生控件的实际宽度小于容器宽度 | 对照开关、提示框样式分段控件与麦克风菜单的可见右边缘 | P1 | F5 |

## 场景

1. 打开并激活真实 SettingsWindow，聚焦系统生成的标签控件，依次切换五页，再关闭和重新打开。标签的选中反馈正常，外部焦点环消失。
2. 聚焦标签控件，通过原生无障碍操作切换选中页。控件仍可成为 first responder，当前页和系统分段控件的选中值保持一致。
3. 从「识别渠道」打开渠道对比，确认弹窗仍可通过原生关闭按钮和 Esc 退出；快捷键页录制退出继续由原有回归覆盖。
4. 检查「声音与界面」三行右侧控件的可见右边缘。使用当前 SDK 的 release 窗口核对，不能以布局容器的宽度或旧系统的控件外观代替。

## 判定依据

自动验证实际控件的焦点绘制配置、first responder、原生无障碍切页及持久化设置；弹窗在聚焦控件后接收窗口内 Esc 事件并关闭。测试宿主不保证成为系统前台应用，因此自动用例不将 makeKeyAndOrderFront 调用视为窗口已经激活，也不冒充真实键盘导航的端到端验收。

最终外观使用激活窗口的系统截图核对。原生材质及焦点环可能由窗口合成器绘制，不能仅凭未激活的离屏缓存位图宣称通过。人工验收需覆盖点击五个标签、Tab/Shift-Tab 导航、系统支持的方向键选择、打开渠道对比及关闭后重开；保持正常的原生选中反馈与文字编辑焦点。

## 原因与修复

顶部 TabView 生成了原生 NSSegmentedControl。修复前控件可成为 first responder，focusRingType 为默认值；获得键盘焦点时，系统会在选中标签外额外绘制蓝色焦点环。前一次验收未覆盖激活后的焦点状态，因此交互测试通过仍遗漏了外观问题。

在 SettingsView 与 ChannelCompareSheet 的根视图应用 SwiftUI 的 focusEffectDisabled()。该规则继承给子视图和系统生成的控件，不逐个禁用按钮焦点，不修改用户的系统键盘设置，也不使用全局类替换。原生标签控件修复后 focusRingType 为 none，仍接受 first responder。API 依据：[focusEffectDisabled](https://developer.apple.com/documentation/swiftui/view/focuseffectdisabled(_:))、[focusRingType](https://developer.apple.com/documentation/appkit/nsview/focusringtype)。

同日补充：提示框样式的分段 Picker 使用 140 点宽度的容器，新系统原生控件按其较小的实际宽度绘制；容器默认居中，导致控件右端比同组开关缩进约 20 点。保留原生 Picker，将容器改为 trailing 对齐；正常系统留白及控件样式由系统决定。该项属于布局微调，使用现有回归和实际 release 窗口截图验证。

对齐修复后的默认基线仍为 78 项、0 失败。重新生成并验证 Apple Development 签名的通用构建；激活 release 窗口的系统截图确认，分段控件已移动到同组控件的右侧对齐位置，原生样式保留。截图产物为 /tmp/openvoice-settings-aligned.png。

## 自动用例与执行

默认入口为 ./Scripts/test.sh，本地、CI 和发布均执行 SettingsWindowTests：

- testFocusedNativeTabsDoNotDrawAnExteriorFocusRing：打开、原生无障碍切换五页、聚焦实际标签控件，再关闭重开；检查无外圈绘制、仍可聚焦、系统选中值和当前页面一致。
- testComparisonSheetStillClosesWithEscapeAfterFocusingControls：打开真实对比弹窗，聚焦实际控件并发送 Esc；弹窗必须关闭。
- 保留三个既有设置回归：设置持久化及窗口上边缘稳定、多渠道至少两个及流式禁用、切页/关窗释放快捷键录制。

新增焦点环用例在修复前确实失败：实际原生控件的 focusRingType 为 default，而预期为 none。两处根视图修复后通过。2026-11-05，默认基线共 78 项，0 失败；其中设置回归 5 项，听写/音频/连接基线仍为 73 项。此结果不等同于供应商识别质量保证或远端 CI 已运行。

本机通用 release 构建包含 arm64 / x86_64，动态选择 Apple Development 证书签名，并通过 codesign --verify --deep --strict。使用 --focused 模式激活 release 窗口、聚焦「声音与界面」标签，再用系统窗口截图核对：标签外没有蓝色焦点环，控件的正常蓝色选中填充保留。截图产物为 /tmp/openvoice-settings-focus-fixed.png。

## 验证与评审

输入来源为本次用户截图；修复前 SettingsView.swift SHA-256 为 3871e8f71a01296aae1fd90d4cfd706cbf394a00f7b8b26173dc4136514bbf4a，SettingsWindow.swift 为 e8210aad226bdb7813fbba3f9015d8d04618ee2786c16fdd0875a1f424fe24e3。

生成工具为本会话 Codex，运行环境未提供精确模型快照；技能为 ai-test-generation 2.0。需求、风险、场景与判定依据先于新增测试代码记录。编译与本地执行验证了所有实际 API 和选择器；两个新增测试的代理自查结论均为保留：各自对应 F1/F2、F2/F3，使用隔离设置并清理窗口，不向用户应用投递按键。人工评审待交付后进行，不将代理自查记为人工通过。

预览支持 --preview-settings 输出路径 --settings-tab audio --focused。--focused 会激活预览窗口并聚焦原生标签栏；系统截图须在预览窗口显示期间采集，离屏输出只用于布局参考。
