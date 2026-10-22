# Android 0.4.48 启动与入房交互缓存

## 恢复入口

- 用户要求：冷启动直接使用本地会话列表，恢复期间可切页/进房；入房先展示缓存气泡，可滚动/发送；改进 Debug 安装模拟器供用户测试。
- 授权范围：客户端改进及模拟器 Debug 安装；未要求公开发布。
- 当前阶段：只读调查完成，具体设计待确认；没有产品代码修改、构建或安装。
- 源码基线：活动树 `C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat`，HEAD `74cf7217`，分支 `codex/android-consent-20261016`。primary main `5c83a08a` 不是最新移动基线。两树均有其他任务文档改动，实施须隔离。
- 负责人：root；本轮仅拥有本记录。下一步确认交互缓存设计，建立本任务计划/隔离工作树后测试先行。
- 更新时间：2026-10-16T20:51:22+08:00。开始精确时间未知；调查工具在本轮聊天留存，未估算耗时。

## 已核实事实

1. `installation_startup_gate.dart` 在 prepare/reconcile/start 完成前不创建应用内容；1秒显示安全占位，3秒显示具体阶段。`main.dart` 的 startApplication 在返回应用前等待 retained Matrix DB 打开。不能仅删除文案解决阻塞。
2. `app_home.dart` `_buildMessagesTab` 在 Matrix 未 ready 时使用 `previewOnly: true`，`matrix_home_page.dart` 显式禁用缓存会话点击与入房；旧2216批准规格明确只读预览，不等于本次交互预览完成。
3. `room_page.dart` 等待 `openLogicalRoomTimeline` 后才创建 controller；空列表/controller为空时展示“正在读取本机消息…”。需把首屏缓存投影及输入排队与完整时间线挂载分离，同时保持账号/租约/隐藏消息/权限边界。
4. adb只读确认 emulator-5556 在线，存在 `com.liuhetong.mobile.debug`；未卸载、清数据、发送消息或改网络。

## 拟议验收

- S1：已有有效本地账号，安全本地检查后展示缓存列表；后台同步期间可切tab/进入已有会话。
- S2：缓存房间先绘制近期气泡，恢复不清屏、不重置滚动位置；历史按页读，取消过期请求。
- S3：本地安全存储就绪后，发送持久入队并显示待发送，通信就绪后沿现有权限和E2EE链路发送；不冒称服务端已送达、不重复发送。
- S4：退出/切账号/撤销/密钥不可用不泄漏旧缓存，不跳过安装连续性检查；首次无缓存和失败状态如实展示。
- D1：聚焦RED/GREEN、共享门禁/分析、规格再质量审查、固定签名常规重建，保数据install-r；用户自行功能测试。无新包交付事实。

设计边界：正常已登录且有缓存路径减少整页加载；冷进程仍须读取磁盘/安全存储，不承诺所有设备绝对零延迟。发送点击可立即入队，不意味着恢复前已完成网络投递。

2026-10-16T21:22:40.7050500+08:00：用户已批准并正在实施。活动工作树 C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat，分支codex/interactive-cache-startup-20261016。Task1房间缓存与文字发送衔接44f079ba+981ac950已通过独立规格/质量复审（初审两P1均修复，74项修复回归通过）。Task2启动首页实施中。候选预留0.4.49+2218；尚未构建或安装，模拟器仍0.4.47/2216。完整进度以活动树docs/verification/artifacts/2026-10-16/interactive-cache-startup/progress.md为准。

2026-10-16T21:54:54.2079379+08:00 隔离工作树 interactive-cache-startup 的候选源码e163acd9已冻结；Task1规格/质量复核通过，Task2专项71PASS、分析clean且独立复核中；移动边界377PASS23SKIP。完整Flutter回归开始，尚未构建/安装。实际证据入口仍为该工作树 docs/verification/artifacts/2026-10-16/interactive-cache-startup/progress.md；本任务最终Debug计划0.4.49+2218，安装保数据，无生产发布。

2026-10-16T22:47:42.1817835+08:00 交互缓存任务继续在独立工作树 interactive-cache-startup：源码2f6b625c已修复本地队列竞态、首屏40条解密结果合并、按钮缓存刷新及过期租约回调；专项63PASS/分析clean。完整门禁发现夹具与滚动适配后已修正，但最终复核仍发现固定滚动窗口的解密结果未同步，正在原范围内补齐。之前full-2(6025PASS9SKIP23error+1挂起)和full-3均不是通过门禁；最终源码须复核通过后再全量。尚未构建/安装任何2218新包，模拟器仍2216。证据/后续操作以工作树 progress.md 为准，V盘映射由本任务持有。
## 2026-10-16 23:21+08 最新恢复入口：交付完成

0.4.49+2218 Debug已保数据install-r至emulator-5556，UID10090/firstInstall2026-09-26 04:06:20保持，设备APK SHA与验证成品一致，启动ok及当前进程fatal0，消息列表可见。产品源码c29597e0（interactive-cache-startup工作树），最终6075PASS9SKIP0FAIL/fullanalyze0，独立SPEC→QUALITY通过；固定75b31签名、常规重建、语义/资产/清单检查全部通过。APK SHA e5de14ae36afbdf8f465ac5411ba8d76b39cc3a762c8a56d88e2f7e8b86115a6，125983066字节。

[完整交付报告](C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat/docs/verification/2026-10-16-interactive-cache-startup.md)。下一步由用户在模拟器冷启、切页入房、滚动及恢复期间发送文字验收；未发送真人消息、未发布、无iOS构建。必要本地安全检查仍保留。源码/成品保持，自己创建的V/W映射、浏览器服务及构建测试进程均已结束，不需重复构建或清数据。

## 2026-10-17 用户验收反馈：S1冷启动加载感未达标

用户反馈2218冷启动仍显示全屏加载，要求参考其他IM分析原因。本轮只读核实模拟器version0.4.49/2218；源码7747e54a（产品c29597e0）。不将上一轮自动通过等同用户验收通过，S1体验验收重新记为FAIL_USER_REPORT。

源码确认：InstallationStartupGate.await widget.start()完成前不展示实际child，1秒显示spinner，3秒显示阶段文案（正在启动畅聊/正在打开本地聊天）。main.startApplication仍await openStartupMatrixClient→MatrixClientFactory.create→initializeClient。initializeClient只传waitForFirstSync:false，SDK默认waitUntilLoadCompletedLoaded:true，仍await设备密钥/rooms/accountData/discovery，并此前await加密初始化。因此2218主要解耦了后段恢复，未将独立首屏缓存展示移出前段整客户端初始化。启动门测试33/71附近还断言等待时应显示加载，故6075PASS不证明用户要求的无业务整页加载。

未对各阶段作新设备计时，不把结构性阻塞推断成某一操作的毫秒占比。参考官方TDLib异步缓存与增量更新（https://core.telegram.org/tdlib/getting-started）、Matrix/Element X首屏最小数据+后台扩展（https://www.matrix.org/blog/2023/09/matrix-2-0/）、Android本地数据源驱动UI（https://developer.android.com/topic/architecture/data-layer/offline-first）。不声称知道微信/WhatsApp闭源内部实现。

下一可执行方向：拆分最小账号安全检查/有界加密首屏投影与完整SDK恢复，首页不依赖后者；本地快照必须按账号/安装代次隔离并在退出撤销时失效。增加从真实应用入口、持有慢SDK恢复的验收：已有缓存直接显示真实列表，可导航进房/滚动，文字持久排队，不出现业务全屏加载。量测冷进程→首个缓存行可交互，而非只测am start或最终截图。不可仅删除文案、延长启动屏、展示不可交互截图，或盲目把SDK默认等待开关设false。
