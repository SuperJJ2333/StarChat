# iOS 2234 消息时间顺序与冷启动提示

## 恢复入口

- 目标及授权：用户反馈 0.4.65（2234）普通旧消息落在底部、上滑优先出现失败/数周前消息，要求冷启动不出现“文字将在本机保存……”；补充两条 9 月 27 日消息无失败标记。授权为这三项缺陷修复。
- 计划：[timeline-chronology](../../superpowers/plans/2026-10-25-timeline-chronology.md)。
- 当前状态：源码修复与本地验证完成；独立规格→质量/安全复审通过。未打包、未合并/推送、未发布。
- 工作树：C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat；分支 codex/ios2234-timeline-order-20261025；基线 3aa09bfb。
- 文件所有权：见计划；主工作树既有删除/修改不属于本任务。
- 交付授权：用户最后确认“先交付源码修复和验证结果”，本轮不生成新 IPA。
- 源码提交：`29384fed`；最终输入清单 SHA256：`c54619ce1e21ed04b3fdac3520bacbf07328184abbc33031fcaa24f46ffca9d5`。
- 2026-10-25 13:16（Asia/Hong_Kong）；下一步：用户先审阅源码与报告。如后续授权打包，以此提交生成新 build 候选，补齐 iOS 原生/设备验收；不要继续使用 2234 身份覆盖原包。

## 验收台账

| ID | 预期 | 状态 | 真机缺口 |
| --- | --- | --- | --- |
| C1 | 普通旧缓存不能挤到最新消息后，默认最新窗口 | RED/GREEN，晚到普通旧行与同时间稳定排序通过 | 用户原例待新包复测 |
| C2 | 上滑按时间展示，失败消息在所属时间段出现 | RED/GREEN；200 条窗口、锚点及两端可达性通过 | 长历史上滑待复测 |
| C3 | 无本机保存提示，离线文本仍可安全持久化 | RED/GREEN；本地保存、SDK handoff、无越权网络请求通过 | 冷启动待复测 |
| C4 | 就绪/输入区高度变化不跳行或误计滚动 | RED/GREEN；空闲、拖动、惯性、最新边缘通过 | iPhone 键盘/就绪切换待复测 |

## 调查证据与边界

CodeGraph 实际查询覆盖 RoomTimelineAdapter.snapshot 动态实现、_SdkRoomTimelineCapability._refreshWindowSource/snapshot/_mergeAccountOutgoingWork、RoomTimelineController._snapshot、Timeline.events/requestHistory。SDK snapshot 和 controller 原有测试明确要求保留非单调 SDK 次序；普通旧事件晚加入原始列表后会位于最新展示边缘。另一路将所有旧 pending 合并在已截取窗口之外，可提前露出历史失败气泡。原始 SDK 顺序承担分页职责，只修展示顺序。

基线工件仍是 0.4.65（2234），SHA256 5cb972096c2331574133812b386b2b86fb94befb09f07e12e9a34c71768b1288；新源码修复未构建/发布，不能归入原工件验证。

验证详情及失败轨迹见[源码修复报告](../../verification/2026-10-25-ios2234-timeline-chronology.md)。未修改钱包、认证、金融、E2EE、SDK 原始事件/分页/持久化、依赖锁和工件版本。

## 阶段计时

| 阶段 | 时间/依据 | 结果 |
| --- | --- | --- |
| 调查 | 2026-10-25；早期精确起点未记录，不估计 | 两条展示排序路径及提示已定位 |
| 首轮核心 RED | 12:38:57–12:39:08 +08:00 | red-all-receipt.json，6 项预期失败 |
| 最终定向 | 13:02:05–13:02:17 +08:00 | height-gesture-green-receipt.json，74 PASS |
| 冻结全量及 analyze | 13:02:31–13:14:31 +08:00，工具运行 | 6388 PASS / 9 SKIP / 4 夹具 FAIL；source_stable=true |
| 最终移动边界/UI | 13:03:42–13:04:45 +08:00，与 Flutter 并行 | 404 PASS / 1 Ruby SKIP；UI 契约通过 |
| 夹具补验 | 13:14:41–13:14:51 +08:00 | 4 PASS；其他输入哈希相同，复用未受影响全量结果 |
| 诊断开启变体 | 13:14:51–13:15:05 +08:00 | 9 PASS；默认关闭用例在本变体条件跳过 |

全量中的产品回归已修复后重新冻结运行；最后只补齐私有测试 Fake，避免重跑输入未变的其余 6388 项。所有失败/取消保留原证据。调查起点未知，总墙钟不估成精确分钟；上述并行时段不能相加作为总耗时。

## 交接

证据目录：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/timeline-chronology。不记录真实消息正文。无需生产迁移；回退为本修复提交的正常 revert。此时未启动 CI 或发布。
