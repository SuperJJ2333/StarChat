# iOS 2234 聊天时间顺序源码修复

## 交付范围

用户报告 0.4.65（2234）冷启动显示旧缓存在最新消息下方、向上翻历史优先显示失败及数周前气泡，要求移除“文字将在本机保存……”提示；已明确两条 9 月 27 日消息没有失败标记。2026-10-25 用户选择本轮只交付源码及验证，不生成 IPA。

源码修复提交：`29384fed`；候选分支：`codex/ios2234-timeline-order-20261025`；基线 `3aa09bfb`。工作树 C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat。主工作树既有改动保留，未合并/推送或部署。

## 根因与改动

1. 原投影与测试明确保留非单调 SDK 次序；缓存恢复/历史补入的普通旧事件也会位于列表尾部。现在对展示引用按消息时间稳定排序，再截取最新窗口；同时间保留输入次序。最新消息指针也按最大消息时间取值，原 SDK 列表、持久化和游标不变。
2. 发件箱/账户 pending 原在窗口截取后不受范围限制地合并。现在旧失败消息保留原创建时间，仅在其所属时间段出现；短冷缓存尚有未加载历史时不提前展示。历史固定窗口中仍能看到对应失败消息并保留重试入口。
3. 满 200 条窗口的 pending 合并保持实际阅读锚点、连续时间顺序及 200 条上限；裁掉的首尾参与翻页状态，先翻完当前源窗口溢出再请求下一窗口。
4. 删除自动显示的本机保存提示组件。离线文本持久化、恢复派发与权限守卫保持，真实组件回归验证离线保存且不发起网络业务请求。
5. 冷启动从本地投影切到 SDK 就绪时，输入区高度变化会使倒序列表上移约 29px。现在在布局前补偿一次，并同步阅读坐标；不把补偿误计为滚动方向或距离。空闲阅读、持续拖动、惯性滚动、最新边缘均有回归。

CodeGraph 查询实际覆盖 snapshot 的动态实现及 _SdkRoomTimelineCapability、RoomTimelineController、Timeline.events/requestHistory 调用关系；候选树未建索引，改动以实际源文件与运行测试核对。未改变钱包、认证、E2EE、依赖锁、SDK 存储或原工件身份。

## 验证

原始日志目录（Git 忽略）：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/timeline-chronology/。

| 检查 | 当前证据 |
| --- | --- |
| 普通消息非单调/窗口、旧失败行、提示 RED | red-all.log：6 个预期失败，退出 1 |
| 短缓存、固定历史及最新指针 RED | red-short-head.log / red-pinned.log：预期行为失败 |
| 满窗口阅读锚点 RED | red-full-window.log：event-0 被裁成 event-1 |
| 裁剪边缘翻页 RED | red-overflow.log：event-0 的 hasEarlierWindow 为 false |
| 最终定向 | height-gesture-green.log：74 PASS、0 FAIL，退出 0；覆盖两端可达性、固定 live head pending 尾部以及四种滚动/高度状态 |
| 相邻首次 | adjacent.log：3 个失败保留；时间戳读取预算及两项旧排列假设夹具，后续定向修复 |
| 性能及适配器 | performance-green.log：退出 0；原阈值和身份断言未放宽 |
| 已读回执 padding/正文 | padding-green3.log：退出 0；负向及正向控制均通过 |
| 冷启动高度 RED/GREEN | red-viewport-height.log：450px 变为 421px；height-layout-green.log 原两项真实 AppHome handoff 已通过；最新完整结果见下行 |
| 规格→质量/安全审查 | review.md：两项窗口边界及高度坐标记账发现已闭合；最终复审无 P0–P2 或较小事项 |
| 原冻结完整 Flutter | full.log：6388 PASS、9 条件 SKIP、4 FAIL，退出 1；698.384 秒；full-receipt.json 确认 source_stable=true |
| 4 项夹具失败补验 | emoji-fixture-green.log：4 PASS、0 FAIL，退出 0；只补 _NudgeTimeline.canRequestFuture=false，原断言不变 |
| 9 项诊断变体 | diagnostics-enabled.log：ANNOUNCEMENT_DIAGNOSTICS=true，9 PASS、1 SKIP，退出 0；此处跳过的默认关闭测试已在全量通过 |
| 静态分析 | full-analyze.log 与最终 final-analyze.log 均 No issues found，退出 0 |
| Python 3.12 前置检查 | verify-preflight.log：退出 0；锁、stdin、配置/模块导入通过 |
| 最终移动边界/UI契约 | mobile-frozen.log：404 PASS、1 条件 SKIP（Ruby / CocoaPods hook），退出 0；ui-frozen.log：34 components / 540 screens，退出 0；60.57 秒 |

早期完整测试发现两项冷启动 handoff 回归后主动取消，保留 cancelled-full.log、full-cancellation.json，不能当作通过。固定窗口 pending 尾部另有 red-pinned-tail.log 的真实失败。中间两版高度修正及新增测试选取底部行导致的失败也保留；最终用布局前一次性修正，选择在各测试高度内均可见的阅读行，原 ±1px、真实冷启动 ±8px 断言未放宽。

最终完整运行中的 4 项失败均源于动态表情测试私有 Fake 缺少 SDK 已有的 canRequestFuture 接口。全量结束后只补这一个 getter，重跑整文件 4 项全部通过；未降低产品判断或断言。fixture-revalidation.json 逐文件核对：产品源码、平台、锁、其他测试均与冻结全量相同，仅该夹具文件改变。因此结果按“原全量 + 夹具补验”闭合 6392 个默认场景，另补诊断开启 9 项；不将原失败运行改称一次全量通过，也未再次重复全部用例。

最终输入清单 final-inputs.json 的 SHA256：`c54619ce1e21ed04b3fdac3520bacbf07328184abbc33031fcaa24f46ffca9d5`。原全量清单 SHA256：`924e40525bcbc3174b8e9f529db907640d09f4e5836777e0cac1f8d468975b8a`。补验与复用边界经只读规格、质量/安全复审确认；无剩余源码阻塞项。

命令：证据目录 run-focused.ps1（可指定 Targets/Name）、run-full.ps1；完整 Flutter 为 flutter analyze --no-pub 和 flutter test --no-pub --concurrency=4 --reporter=json。Python 为 .venv312/Scripts/python.exe -m pytest tests/mobile -q 及 scripts/verify_ui_contract.py。

完整 scripts/verify.ps1 的未变服务端、infra、生产锁/开发锁、脚本与测试部分复用 [2026-10-23 维护环境门禁](2026-10-23-maintenance-environment.md) 的退出 0 证据；impact-reuse.json 验证 da86cf77 至候选无这些输入差异。本轮运行该入口 PreflightOnly，并补跑移动边界/UI契约及 Flutter 全量与上述夹具补验，不声称重新运行了约 49 分钟的整个 verify。

环境：Windows、Python 3.12.10、Flutter 3.44.9/Dart 3.12.2。本机验证继续采用短信有效期进程变量 15，未改变校验。Olm/SQLCipher DLL 哈希与前次相同；完整测试期间相关源文件逐一哈希记录，结束核对漂移。

## 尚未验收与下一步

本轮没有生成或发布新包，也没有在 iPhone 上复测。旧 2234 IPA 不包含这次源码修复。未来打包使用新 build 身份，经企业签名后在保留数据的设备上复核：

- 冷启动普通会话，最后可见消息为当前最新缓存，旧普通消息处于其原日期。
- 连续上滑跨日期，历史与失败气泡顺序一致；上下往返与迟到恢复均保持阅读位置。
- 冷启动无本机保存提示，断网输入仍可靠保存，恢复连接不重复发送。

前次 2234 iOS 原生门禁的两项 MEDIA_STORAGE_UNAVAILABLE Outbox 错误仍按原报告保留，本轮源码/宿主测试不能替代 macOS 构建、真机 Outbox、保数据升级和签名验收。

无需数据迁移或清理用户缓存。回退采用正常 revert，不改写历史。
