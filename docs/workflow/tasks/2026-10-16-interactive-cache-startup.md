# Android 0.4.48 启动与入房交互缓存

## 恢复入口

- 用户要求：冷启动直接使用本地会话列表，恢复期间可切页/进房；入房先展示缓存气泡，可滚动/发送；改进 Debug 安装模拟器供用户测试。
- 授权范围：客户端改进及模拟器 Debug 安装；未要求公开发布。
- 当前阶段：实现及Debug交付完成；0.4.49+2218已保数据安装emulator-5556，用户人工功能验收待反馈。
- 源码基线：活动树 `C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat`，HEAD `74cf7217`，分支 `codex/android-consent-20261016`。primary main `5c83a08a` 不是最新移动基线。两树均有其他任务文档改动，实施须隔离。
- 负责人：root；工作树 `C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat`，分支 `codex/interactive-cache-startup-20261016`。计划：[交互缓存实施](../../superpowers/plans/2026-10-16-interactive-cache-startup.md)。下一步：用户在模拟器强停冷启、切页入房、恢复期间滚动与发送文字；按反馈继续复现，不重复构建已验证包。
- 更新时间：2026-10-16T23:21:28+08:00。开始精确时间未知；调查工具在本轮聊天留存，未估算耗时。

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

用户已批准上述方案实施。新工作树interactive-cache-startup，分支codex/interactive-cache-startup-20261016，基线74cf7217。Task1房间→Task2启动→Task3交付。根负责文档/构建，实施代理单写，独立审查。

2026-10-16T21:36:52.8318365+08:00 Task1 commits44f079ba+981ac950；Task2单写进行中。证据：[交付验证](../../verification/2026-10-16-interactive-cache-startup.md)，详细时间账本在 artifacts/2026-10-16/interactive-cache-startup/progress.md。Debug目标0.4.49+2218，无生产发布。

2026-10-16T22:57:39.1246897+08:00 Task1/Task2 independently reviewed; final-review fixes2f6b625c plus pinned-window continuation c29597e0 (78focusedPASS) await scoped re-review. Next: frozen full Flutter/analyze, then conventional rebuilt/signed Debug2218 install-r. Full runs2/3 interrupted, no passing full gate or new APK yet. Root owns V mapping while scoped tests complete.

## 最终交付（2026-10-16 23:19+08）

产品源码c29597e0，Debug0.4.49+2218，固定75b31签名x86_64成品SHA e5de14ae36afbdf8f465ac5411ba8d76b39cc3a762c8a56d88e2f7e8b86115a6，125983066字节。full-4完整6075PASS9SKIP0FAIL/fullanalyze0，独立SPEC→QUALITY通过；Apktool常规重建及代码/资产/清单一致性、验签、对齐均通过。安装2216→2218，UID10090/首次安装时间保留，设备APK哈希一致，主入口启动ok；当前进程fatal0，截图确认原消息列表可见。

| 验收 | 实现/自动证据 | 人工缺口 |
|---|---|---|
| S1缓存首页/导航 | Task2及fix1专项与全量通过 | 用户冷启动真实体验 |
| S2气泡/滚动/恢复 | Task1、最终固定窗口78项及全量通过 | 用户当前房间体验 |
| S3持久文字排队 | 队列开启/验证竞争、派发前readiness、同txid回归通过 | 用户实际发送与收件端 |
| S4隔离/取消 | 账号/owner/generation/销毁/撤回边界与全量通过 | 实体机/完整设备矩阵 |
| D1重建安装 | 成品/安装收据/被动运行通过 | 正式发布未授权；无iOS包 |

构建7分2.772秒、最终全量12分12.880秒、安装启动21.059秒；前序返工及计时见报告/progress。必要本地安全检查仍可能显示初始加载；早期队列仅文字。HTML全量6项既有基线失败、verify缺.env未启动、P3诊断归因延期均在报告说明。无运行命令或自有映射/服务；保留工作树及APK，不合并、不发布、不清数据。

## 2026-10-17 用户验收反馈：S1冷启动加载感未达标

用户反馈2218冷启动仍显示全屏加载，要求参考其他IM分析原因。本轮只读核实模拟器version0.4.49/2218；源码7747e54a（产品c29597e0）。不将上一轮自动通过等同用户验收通过，S1体验验收重新记为FAIL_USER_REPORT。

源码确认：InstallationStartupGate.await widget.start()完成前不展示实际child，1秒显示spinner，3秒显示阶段文案（正在启动畅聊/正在打开本地聊天）。main.startApplication仍await openStartupMatrixClient→MatrixClientFactory.create→initializeClient。initializeClient只传waitForFirstSync:false，SDK默认waitUntilLoadCompletedLoaded:true，仍await设备密钥/rooms/accountData/discovery，并此前await加密初始化。因此2218主要解耦了后段恢复，未将独立首屏缓存展示移出前段整客户端初始化。启动门测试33/71附近还断言等待时应显示加载，故6075PASS不证明用户要求的无业务整页加载。

未对各阶段作新设备计时，不把结构性阻塞推断成某一操作的毫秒占比。参考官方TDLib异步缓存与增量更新（https://core.telegram.org/tdlib/getting-started）、Matrix/Element X首屏最小数据+后台扩展（https://www.matrix.org/blog/2023/09/matrix-2-0/）、Android本地数据源驱动UI（https://developer.android.com/topic/architecture/data-layer/offline-first）。不声称知道微信/WhatsApp闭源内部实现。

下一可执行方向：拆分最小账号安全检查/有界加密首屏投影与完整SDK恢复，首页不依赖后者；本地快照必须按账号/安装代次隔离并在退出撤销时失效。增加从真实应用入口、持有慢SDK恢复的验收：已有缓存直接显示真实列表，可导航进房/滚动，文字持久排队，不出现业务全屏加载。量测冷进程→首个缓存行可交互，而非只测am start或最终截图。不可仅删除文案、延长启动屏、展示不可交互截图，或盲目把SDK默认等待开关设false。
