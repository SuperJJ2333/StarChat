# 2204 会话进入与历史滚动生命周期断言

## 恢复入口

- 目标与授权：用户原四项 emoji/icon、历史穿越、快滑与卡顿缺陷要求及“请你继续”；随后提交 debug 红屏并询问原因，明确最后操作为“进入会话或上滑历史”。本任务继续调查并修复该正常浏览场景，不增加产品功能。不具备正式移动发布、main 合并或推送授权。
- [本任务计划](../../superpowers/plans/2026-10-07-room-lifecycle-assertion.md)；[产品规格](../../superpowers/specs/2026-08-12-starchat-product-modernization-design.md)；[前任务](2026-10-07-history-icons-performance.md)及其[验证报告](../../verification/2026-10-07-history-icons-performance.md)。前任务的资源、历史连续性、服务器止损与 SSH 证据保留为各自当时事实，不因新截图重写为全部失败或全部问题已消失。
- 当前状态：**调查；原始 6268 首因未确认，未实施生产修复，未构建新包**。2204 启动 smoke 通过只证明当次启动观察；本次真实会话交互有用户红屏，未验收通过。
- 负责人：root；候选 worktree `C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat`，分支 `codex/room-lifecycle-assertion`，从文档 HEAD `2d2e9da5fa412391dce5db4a3f20d7009352aa9f` 继续。已安装 2204 的实际移动源码仍为 `3a620495ae048d3e4141f099e1926ecedc8669cd`。
- 文件所有权：room_lifecycle_repro 独占新 `apps/mobile_flutter/test/features/matrix/room_page_lifecycle_test.dart`；framework_assertion_audit 在只读生产审计之外独占新 `apps/mobile_flutter/test/features/matrix/conversation_cached_row_lifecycle_test.dart`，用**公共 Flutter 组件复刻现行首页缓存模式**，未挂载真实 MatrixHomePage，未覆盖真实首页服务或账号数据；root 在有真实 RED 和根因证据后可领取 `room_page.dart` / `timeline_scroll_anchor.dart` 的最小修复；lifecycle_record 只写本任务与本计划两个新文档，不编辑索引、前任务或源码。不得同时编辑同一文件。
- 最后更新时间：2026-10-07T20:05:37.287+08:00；下列运行状态保留各行明确的观察时间，不推断随后结果。
- 下一条具体操作：保留断言开启，在真实 RoomPage 合成数据场景和安全过滤设备捕获中寻找**最早异常**；获得具体 inherited scope、首个应用栈、同帧 controller 附着数量或独立离屏行复现后，再写并确认缺陷 RED。阻断验收 L1–L3；没有新版本保留或构建。
- 安全边界：不记录/输出真实消息正文、媒体内容、用户密钥、tokens 或原始敏感 logcat；不卸载、清数据或降级，不修改 Flutter SDK 或关闭断言，不进行金融写入/测试消息/通话。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| L1 | 进入会话或上滑历史，组件停用时 inherited 依赖正确解绑，无 6268 红屏 | 未实施；原始首因未确认 | 用户截图 `framework.dart:6268:12 _dependents.isEmpty`；保留设备日志中未取得该断言首栈 | 无新发布 | 用户已报错；具体 inherited widget 和首个应用 frame 缺失 |
| L2 | 100ms 可见性观察仅读取当前附着的实际可见行，不对脱离渲染树的气泡求坐标 | 未实施；已确认前置条件违规 | 安全静态栈：`RenderObject.getTransformTo` attached → `RoomPage._observeVisibleReadReceipts:825`；不能凭此认定 L1 首因 | 现有 2204 有设备异常 | 需真实独立 RED、最小修复及相邻已读/提及/媒体观察验证 |
| L3 | 滚动结束、窗口平移和返回最新时，列表/controller 生命周期一致 | 未实施；多个位置的来源未确认 | 安全静态栈：`ScrollController.position:172 _positions.length == 1` → `room_page.dart:5444/5483/5696` 及 `5536` | 现有 2204 有设备异常 | 需判定多附着是最早异常还是此前树更新失败的后果；不能只跳过 `.position` 来掩盖长期双挂载 |
| L4 | 根因 RED→GREEN，相关历史/锚点/读权限及最终同源共享门禁通过 | 待 L1–L3 根因后实施 | 实际 RoomPage **6 PASS/0 FAIL**，首页公共组件模式 **3 PASS/0 FAIL**，共9项诊断 PASS；覆盖不同，非全量；原缺陷未复现，不是 BUG RED 或修复证据 | 无 | 无生产修改，不重复旧同输入全量；后续修复必须新门禁，前任务5501 PASS不覆盖该真实失败输入 |
| L5 | 若交付新包，标准重建/稳定签名/保留数据安装后复测原场景 | 未开始 | 无新候选、新版本或构建；2204 原 APK 身份保留 | 无正式发布 | 模拟器原场景、手机弱网/连续快滑及 iOS 对应验证不得互相替代 |

## 版本与证据

| 平台/服务 | 实际版本/build | 来源 commit | 包名/签名渠道 | 文件位置及 SHA | 观察时间/状态 |
| --- | --- | --- | --- | --- | --- |
| 用户截图 | debug 红屏；截图状态栏 7:39 | 截图本身不含源码身份 | 模拟器 | 用户附件仅供读图，未复制真实界面进仓库 | 最后操作“进入会话或上滑历史”；不从截图时钟推算精确发生时间 |
| 实际已安装模拟器 | 0.4.35+2204；emulator-5556、PID8170、UID10090 | `3a620495ae048d3e4141f099e1926ecedc8669cd` | `com.liuhetong.mobile.debug`；固定 signer `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff` | [主区原交付 APK](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-07/history-icons-performance/delivery/ChatFlow-0.4.35-2204-x86_64-debug-rebuilt.apk)，SHA `221aca2d4ea486673b650b0a7ca4d580f9c2655c7337bd74bd8e93de6a353b5c` | 2026-10-07T19:40:47.223642+08:00 设备记录；原 18:36 install-r 保留数据 |
| 本任务源码调查 | 无新版本；文档 HEAD `2d2e9da5fa412391dce5db4a3f20d7009352aa9f` | 生产移动源未变 | 无新包 | `room_page.dart` SHA `dd86ccc67367ffc4c071315bb6217afa369d7891dfb3bbca77aa373adb3f0154`；`timeline_scroll_anchor.dart` SHA `f49f1f7308925aa2b523de3329222c658484ef6c80bd959ca9ac43cd21c40428` | 2026-10-07T19:54:02.868+08:00 快照 |

证据位于 [framework-assertion-2204](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/)：

- [只读 SDK/源码审计](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/framework-findings.md)：2026-10-07T20:01:20.658+08:00 实际文件 SHA `48465ee422d155cd2986cb155bdd9af3affddea8c76a6567b0018fb7ca118d43`；Flutter 3.44.9 / Dart 3.12.2、本地 SDK HEAD `6b182d2c7585eba26d4edce0f97630effd256c33`，SDK `framework.dart` SHA `30db928d0d6526ea368924c220fe10fc96f661d7e928f7704df2b13a9a798877`；未修改 SDK。正常 snapshot 稳定 ID 去重、两 sliver 索引不相交，不把正常 GlobalKey 使用本身视为 BUG。
- [设备静态源代码栈](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/device-secondary-source-stacks.json)明确 `raw_saved=false`。这是 attached 和多 positions 的真实异常，未包含截图 6268 的原始栈，未证明先后因果。
- [初次过滤身份](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/device-exception-source-stacks.json)记录版本/PID/时间；其目标断言 marker 为 0，不能写成首栈捕获成功。
- 历史中间诊断：[三项命令/结果/输入 hash](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/room-page-lifecycle-diagnostic-metadata.json)、[该次日志](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/room-page-lifecycle-diagnostic-final.log)记录19:51:03.4516199–19:51:14.3149170+08、3 PASS/exit0、当时测试 SHA `5fe664b70d5a8e3ad2e6d5a31d0ab5f15773cf9656792e798efea902b533b65e`；保留该历史身份，不以此 SHA 绑定后来6项结果，也不重复计入最终9项诊断。
- 最终实际 RoomPage 诊断：[说明](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/room-page-lifecycle-findings.md)、[NEW 六项回执](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/room-page-lifecycle-six-metadata.json)（实际 SHA `d4f1617a124a7dd64ee63e5f78a0021ca41b2f9bf89c122aadd83b8613d180d5`）、[六项日志](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/room-page-lifecycle-six-final.log)、[文件级 analyze 日志](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/room-page-lifecycle-analyze-final.log)。Windows/pwsh7 UTF-8、Flutter3.44.9/Dart3.12.2，cwd `U:/apps/mobile_flutter`；`flutter test test/features/matrix/room_page_lifecycle_test.dart --no-pub --reporter expanded`，20:02:17.4049407–20:02:35.3246413+08，**6 PASS/0 FAIL、exit0**；随后 `flutter analyze --no-pub test/features/matrix/room_page_lifecycle_test.dart` 至20:02:42.4506457+08，exit0/no issues，formatter完成。最终测试 SHA `9b25b91880d1c8695c3eab3bc0daa1ccba15b3449bbab19e5d47caa9fa106642`；room_page/anchor/锁身份仍与上方基线相同。覆盖1200合成事件/360×800、实际RoomPage/100ms timer、快速反向拖动、cache-anchor↔latest、MotionPageRoute push/pop/混合媒体；真实SDK held `/context` transport + limited sync + history/ballistic 后执行公共 earlier-window action，**旧 sliver center 实际被替换，覆盖现有 GlobalKey 行重排路径**；静态group及direct→group元数据变化、active拖动中真实公告服务合成响应到达并展开。六项均单position、无首框架异常，**原缺陷未复现**。前两次return-latest fixture未先进入旧窗口、一次center断言未先执行公共窗口动作导致的失败属fixture覆盖设置问题，不是产品RED；修正fixture后记录实际旧sliver center替换条件。测试未直接断言具体旧消息ID被裁掉或Element/GlobalKey实例保持，不把覆盖路径扩述为这些断言已证明。
- [缓存行模式诊断回执](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/conversation-cached-row-lifecycle-receipt.json)（实际 SHA `f08ad1da1cce46289d06e445eb888a479a4c8f4cf78083542ec8aef3ecb2b2ee`）与[日志](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/conversation-cached-row-lifecycle.log)：`flutter test --no-pub --reporter expanded test/features/matrix/conversation_cached_row_lifecycle_test.dart`，cwd `U:/apps/mobile_flutter`，19:56:48.8795272–19:56:54.0923826+08，exit0、3 PASS/0 FAIL，测试 SHA `fb702230b289ee5699d525dbac92938603eb9652048fb82ce1abc5e7347da845`。**公共 Flutter 组件复刻现行首页缓存模式**（缓存 GlobalKey + ListView.separated 无索引回调），测试重排/删除、真实 CupertinoPageRoute 覆盖合成 retained 列表、同帧 theme 变化；**未挂载真实 MatrixHomePage，未覆盖 ConversationListTile、真实首页服务、异步头像/业务状态或真实账号数据**。这是诊断 PASS，未复现截图，也不是 RED/GREEN 修复证明。
- 缓存行模式文件级 analyze：[回执](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/conversation-cached-row-analyze.json)及[日志](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/conversation-cached-row-analyze.log)，`flutter analyze --no-pub test/features/matrix/conversation_cached_row_lifecycle_test.dart`，cwd `U:/apps/mobile_flutter`，20:04:05.6407436–20:04:08.7034979+08，exit0/no issues；测试 SHA 与上述3项回执相同。仅该文件检查，不是移动源码全量 analyze。
- [安全过滤捕获](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/fresh-safe-stack.json)19:50:09.241083–20:00:10.142693+08 已结束，exec session94340 最后真实 exit0，墙钟600.901610s；487 行原始 logcat 仅在内存读取，`completed=true`、`raw_saved=false`、`records=[]`。没有取得新首栈；只能证明此捕获窗口无目标记录，不能证明用户原场景未再发生或缺陷消失。
- [索引保全](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/current-state-preservation.json)：root 于19:59:49.970841+08 向候选/主区各前插1027byte，新前缀移除后各自原 SHA 完全相同；两者原 hash 不同，未整页互相覆盖。[主区 WIP 保全](../../verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/primary-wip-preservation.json)：20:00:46.426718+08，1373项原 WIP 无 mismatch，main HEAD 仍 `be207f0fece77f0a4585790d7c0932368ac63146`。

前任务源/包、资源门禁、历史 SDK 回归和服务器证据仅按各自身份复用。本任务生产源未变，不重跑前任务同输入的5501项完整门禁；诊断测试仅有文件级 analyze 证据，不称新的完整共享门禁或编译已通过。后续任何生产源修改需要新输入比较与最终共享门禁。未进行 Android/iOS 新编译或 `verify.ps1`；前任务 `verify.ps1` 因缺 `.env/local.env` 未执行，不导入生产秘密来补环境。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 用户红屏恢复与安全设备栈调查 | 约 2026-10-07 19:39+08；精确开始未知 | 调查中 | 主动/工具 | root / audit / repro | 19:40:47 安全身份与 retained 栈；不估精确耗时 | 取最早 6268 栈或确定缺失条件 |
| safe-only logcat 捕获 | 2026-10-07T19:50:09.241083+08:00 | 2026-10-07T20:00:10.142693+08:00 | 工具/等待 | root capture | session94340 exit0；600.901610s、487内存行、0安全目标记录、raw_saved=false | 首栈仍缺，保持调查中 |
| 实际 RoomPage 历史三项诊断 | 2026-10-07T19:51:03.4516199+08:00 | 2026-10-07T19:51:14.3149170+08:00 | 工具 | repro | 3 PASS、exit0、10.8632971s；保留当时input身份 | 不计入最终9项，不当RED |
| 独立新记录与计划 | 2026-10-07T19:53:38.833+08:00 | 2026-10-07T19:56:05.803+08:00 形成待校验文档 | 主动 | lifecycle_record | 本地 Get-Date；不是前任务重做；首检发现 APK 只在主区，已更正链接 | 最终链接/范围一致性检查后交回 root |
| 缓存行模式诊断 | 2026-10-07T19:56:48.8795272+08:00 | 2026-10-07T19:56:54.0923826+08:00 | 工具 | audit probe | 3 PASS/exit0、5.212844s；公共 Flutter 组件复刻现行首页缓存模式，未挂真实 MatrixHomePage | 不追加无新依据的同类 stress，等待最早静态栈 |
| 实际 RoomPage 最终六项诊断 | 2026-10-07T20:02:17.4049407+08:00 | 测试20:02:35.3246413+08；analyze20:02:42.4506457+08 | 工具 | repro | 6 PASS/test exit0、文件级analyze exit0；NEW六项回执及新test SHA | 不追加无新依据的同类 stress，原首栈仍缺 |
| 缓存行模式文件级analyze | 2026-10-07T20:04:05.6407436+08:00 | 2026-10-07T20:04:08.7034979+08:00 | 工具 | audit probe | exit0/no issues、同test SHA | 不视为移动全量analyze |
| 最终调查事实收尾 | 2026-10-07T20:01:20.658+08:00 | 2026-10-07T20:04:40.095+08:00 定稿待交回 | 主动/并行审查 | lifecycle_record / artifact_review | 9项诊断证据和两文件级analyze已绑定；本轮诊断SPEC→QUALITY回执由root独立归档，当前待审 | 不预记审查ACCEPT或原BUG已修复 |

总墙钟：任务仍进行中，精确最早起点未知，暂不计算。并行区间不累加；诊断 fixture 返工与产品缺陷 RED 分开记录。

## 交接与回退

- 已确认：6268 是 inherited scope 停用后的依赖一致性断言；debug 显示红屏是错误呈现方式，不能因此归咎模拟器。`mounted`、`hasSize` 不等于 RenderObject `attached`；`hasClients` 不等于恰好一个 position。
- 未确认：具体 inherited widget、原始首异常及调用链、多附着从何产生、是否与正常窗口重排存在必然关系。正常 GlobalKey reparent 及单个缓存 subtree 的存在本身不是根因证明；2204 的 history clone 改动没有直接创建 controller/GlobalKey。审计的“初始 adapter 两事件同 txid”防护缺口是条件性假设，尚未证明合法 SDK/存储真实输入存在该事故条件，也没有本任务 RED，不能归因用户数据。
- 待办：L1 首因/独立 RED；L2/L3 根因修复及回归；修复后的SPEC→QUALITY及最终同源门禁、如需要的新版本标准构建与保留数据复测。当前新增诊断测试/文档有序审查另列，不等于修复源码审查。不能以隐藏断言、吞异常或切 release 完成验收。
- 已发布与候选：本任务没有新构建/安装/发布。前任务 2204 x86_64 已安装、ARM64 仅本地候选，不认定真实手机弱网/快滑验收通过。
- 回退：未改生产源码、Flutter SDK、设备数据或生产服务，无本任务生产回退动作。旧 2204 分支/包/证据保持；新测试和文档留在本任务分支，不能清理他人 WIP 或旧 S: 工作树。
- 运行中：safe-only capture exec session94340 已exit0结束，六项及三项模式测试/两文件级analyze已exit0结束，没有仍运行的采集、测试命令、隧道或构建；设备 PID8170 只是当次观测，恢复时先重读。本轮独立有序SPEC→QUALITY仅审新增诊断测试/本任务文档，当前待审，root将在上述证据目录独立归档回执；不据此预记接受，也不与未来根因修复审查混淆。无本任务 CI。恢复先检查审查结果、agent 文件所有权、当前分支/改动与证据输入 hash，不重复无新依据的同类 stress。
