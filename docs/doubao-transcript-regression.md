# 豆包混合回包合并回归

## 输入与要求

来源：用户反馈长语音只有末段润色，以及评审意见 `34263007-3006-4443-870e-468dca207337`。实体为同一识别会话内的带索引句子、无索引累计稿、完整累计定稿。沿用上游按 index 排序、同一 index 定稿可修订、joinSentences 的连接规则。

- D1：累计临时稿不能清除已润色句，也不能屏蔽后续新文字；断线回退可读取完整最新文本。
- D2：累计定稿按完整快照接收，随后临时稿不得覆盖已定稿部分；两种现有定稿标记均有效。录音尚未结束时允许累计快照继续增长，仅 SessionFinished 封闭整段。
- D3：累计原稿与润色稿长度可能不同，不能按润色稿字符数截取原稿，也不能重复追加原稿前缀。
- D4：句子修订和乱序定稿按各自 index 更新；旧句不能清空新句临时稿。

边界：无索引数组只取第一个候选；空文本/无效 JSON 不改变状态。测试使用生产 Transcript，显式逐包释放，不访问识别服务。无索引全文与带索引句子没有服务端范围元数据；合并优先使用已观察的句子原稿定位，缺少原稿时只允许有共同文字的对齐，不以字符长度猜切分。供应商实际回包与本次用户录音尚未抓取，不把合成测试当成在线识别质量保证。

## 风险、场景与覆盖矩阵（测试代码之前记录）

| 要求 | 风险 / Given → When → Then | 测试 | 优先级 |
|---|---|---|---|
| D1 | 首句已定稿 → 累计稿增加尾部 → 润色句和新增尾部均保留 | testCumulativeTailRemainsVisibleAfterIndexedFinal | P0 |
| D1 | 纯累计 → 全文增长 → 始终取完整累计稿 | testCumulativeResultRemainsAuthoritativeWithoutIndexedSentences | P0 |
| D1/D3 | 累计原稿 → 首句润色 → 重复累计 → 次句润色 → 中间不缺尾、最后两句均润色 | testIndexedPolishedFinalsSurviveLateCumulativeResponses | P0 |
| D2 | 句子定稿 → 两种标记的无索引全文定稿 → 迟到临时稿 → 保留完整定稿 | testCumulativeFinalSupersedesIndexedTextAndRejectsLatePartials | P0 |
| D2 | 完整累计定稿后 → 更正后的完整定稿 → 接受新定稿 | testCumulativeFinalCanBeRevised | P1 |
| D3 | 已观察带索引原稿 → 长度不同的润色句 → 更长累计原稿 → 保留润色并仅追加尾部 | testPolishingLengthChangesDoNotCutOrDuplicateCumulativeTail | P0 |
| D4 | 新句已有临时稿 → 旧句定稿/修订 → 新句不消失 | testOlderFinalCannotDiscardNewerIndexedPartial | P0 |
| D4 | 第二句先定稿 → 第一句后定稿 → 按 index 输出 | testOutOfOrderIndexedFinalsStayInSentenceOrder | P1 |
| D4 | 同句再次定稿 → 迟到同句临时稿 → 修订保留且不重复 | testIndexedRevisionRejectsLatePartialForSameSentence | P1 |
| D1/D2 | 空、损坏回包及辅助候选 → 已有内容不被清除或替换 | testEmptyResponsesAndAuxiliaryCandidatesCannotReplaceTranscript | P1 |
| D2 | SessionFinished 携带无标记全文 → 迟到临时稿 → 保留完整最终文本 | testSessionFinishedCumulativeTextIsFinal | P0 |
| D3 | 很短的句子临时稿 → 累计稿已更长 → 句子定稿 → 不重复旧临时稿后面的字 | testFinalOutgrowingIndexedPartialConsumesWholeSourceSentence | P0 |
| D3 | 英文累计稿 → 句子润色 → 追加尾部 → 原生空格和 Unicode 完整保留 | testCumulativeOverlayPreservesWhitespaceAndUnicode | P1 |
| D1 | 生产 DictationSession 收到累计新语音 → 正常结束或连接失败 → 完整文本回退并触发语音活动 | testSessionKeepsCumulativeTailOnSuccessAndFailure | P0 |
| D1/D2 | 累计前缀定稿 → 继续说话 → 尾部带索引定稿 → 前缀和新尾部均保留 | testCumulativePrefixFinalDoesNotBlockLaterSpeech | P0 |

## 验证依据（先于测试代码）

每个场景精确断言最终文本；涉及逐包显示的场景还断言对应 partial 文本，防止只在最终结果补回尾字。已有错误测试中“累计稿有新增文字但仍应只显示首句”的断言须改为完整文本。接口由实际 DoubaoEngine.Transcript.update/result 验证，测试不模拟合并方法。修复前先运行新增用例，确认真实缺字断言失败；修复后运行同组及 ./Scripts/test.sh。

工具：XCTest / SwiftPM，ai-test-generation 2.0，当前会话 Codex（未提供精确模型快照 ID）。修复前 Doubao.swift SHA-256：a548e20d17537cd8a40ba476b76183e25ee7aa591c3708adcd5e7a8e75582533。场景/断言已自查；人工评审待交付，未合并或发布。

## 执行与评审记录

- 修复前首轮 10 项中 6 项失败，累计尾部、累计定稿、迟到临时稿和旧句修订都有精确文本失败证据。补充的换行/短临时稿边界及累计前缀继续说话场景，也均先确认失败再修复。
- 修复后 `swift test --filter DictationDoubaoTests`：15 项通过；当前基线包含语音会话、采集、连接和设置窗口检查。
- 所有矩阵行已逐项自查：使用实际类型和已有 fixture，断言完整产物而非内部调用；逐包测试无真实计时等待，组合会话测试显式释放响应并覆盖正常/失败两条路径；英文换行及复合 emoji 未被重新切分或添加空格。
- 矩阵内全部 15 项的人工评审状态为 **DEFER（待人工评审）**，不将生成模型自查记为人工 KEEP；未执行远端 CI、供应商录音验收、合并或发布。
- 未观察到原稿时的文字对齐属于兼容回退，并无供应商范围保证；不能可靠定位的内容予以保留，避免猜测截断。实际回包仍按 `dictation-baseline.md` 的人工步骤验收。
