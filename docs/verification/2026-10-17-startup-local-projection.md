# 冷启动本地首屏投影验证

状态：最终普通main Debug已保数据安装；原生四场景逐帧验收及真实账号缓存命中冷启动检查PASS，可供用户测试。缓存不符合准入条件时仍保留原恢复流程。

- 工作树：`C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat`。
- 候选：Android `0.4.51+2220` Debug / x86_64 / `com.liuhetong.mobile.debug`。
- 产品源码：`d7ee45ed8168f3ccf8f68ab341123ec86c92bdcc`；测试回调修正：`4bd61e997b77a2d97c160ac14a6a2c86f9f4696c`。
- 用户授权：缓存列表/气泡可操作、后台完整恢复、文字持久排队、模拟器保数据安装。没有正式发布或真人发送授权，本次均未执行。
- 任务与批准计划：[任务](../workflow/tasks/2026-10-17-startup-local-projection.md)、[计划](../superpowers/plans/2026-10-17-startup-local-projection.md)、[缓存ADR](../adr/2026-10-17-bounded-encrypted-startup-projection.md)。

## 实现与验收边界

最小安装、账号和密钥检查后读取独立 AEAD 缓存：按账号/设备/安装/数据库代次绑定，最多40会话、每房40事件，提交及候选总空间有界。缓存只提供展示能力，原数据库预检、SDK、Olm、业务会话和发送权限检查保留。首个真实可见缓存内容帧后才放行完整恢复；同一 Client、Room、时间线和页面接收后续数据。

实际 main 在返回页面前准备已有缓存快照及本地可见资格，避免外层一秒计时器及空快照制造加载页。最小启动检查共享8秒时限；缓存不可用走原恢复流程，超时显示重试并退休旧尝试，重试复用未结束的安装检查，防止并发变更。此方案没有消除 Android/Flutter 引擎启动成本，也不承诺首次安装、缺失缓存或身份异常时无需恢复。

同 Room 恢复补齐 canonical lastEvent，保留新收到的消息和历史代次变更优先级。入房首帧增加可见帧气泡断言；正常缓存路径无需新增 RoomPage/AppHome 生命周期。文字使用现有持久 outbox，同一 txid 在通信权限就绪后派发一次；不把现有 outbox 宣称为新增加密队列。

## 证据及结果

所有详细证据位于 [本次证据目录](C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat/docs/verification/artifacts/2026-10-17/startup-local-projection/)。

| 检查 | 结果与限制 |
| --- | --- |
| 独立缓存设计与实现审查 | 领域/规格先于质量/安全，均 PASS；原审查发现的时间线及 Room 标量交接问题已修复 |
| 真实冷启动旧反例 | 2219及9d658版2220 FAIL_PERCEIVED_LOADING，原录像与失败结论保留；不能由合成PASS覆盖 |
| 首帧修正审查 | task4-firstframe-review.md PASS；测试回调修正 task4-callback-assertion-review.md PASS |
| 行为RED | 实际main持有2秒安全读取暴露加载页；持久last_event恢复后为null；修正后GREEN |
| 受影响回归 | 150 PASS＋2个命令路径加载错误；正确路径补跑39 PASS。最终启动门禁21 PASS，真实main四场景4 PASS，回调修正后再次4 PASS。原失败日志保留 |
| 共享全量基线 | 6115 PASS/9 SKIP/2测试夹具或登记失败，原退出码1；两处测试-only修正后完整对应文件6 PASS。未变输入复用，不宣称原全量命令成功 |
| 最终完整分析 | d7ee45ed full analyze无问题；之后仅测试断言API改动，专项分析无问题 |
| 边界/策略 | 原移动边界377 PASS/23 SKIP；本次相关锁屏/SDK依赖6 PASS，仓库策略PASS |
| 原生逐帧验收 | native-entry-2220-r5 PASS，driver退出0，四场景齐全，三个首帧条件true；原r4测试框架冲突FAIL保留，expectSync修正不减少断言 |
| 普通main实际账号冷启动 | main-cold-video-2220-r3 缓存命中视觉检查PASS；main_entry内容1450ms、SDK3977ms；r2准入拒绝走恢复路径，明确不计作快路径验收 |

原生场景要求：持有整个原预检与SDK打开，计数保持0；缓存列表可点、可切页、入房可滚动；网络发送0，文字已持久排队；放行后同Room/页面/锚点和txid，发送恰好1次。另覆盖全隐藏与有效空缓存。第一可见帧列表、无加载帧、第一房间帧气泡三项必须单独为true。

## 附带修正与明确限制

原生测试发现红包卡片Android字体度量导致1px溢出，已修正自适应头部高度并同步HTML/组件登记。54项Flutter组件/财务展示、5项前端专项和UI契约34组件/540页面PASS；浏览器实际渲染及放大文本无溢出。前端全量564 PASS/6 FAIL，六项发布下载页问题在未修改基线同样复现，保留失败，不宣称前端全量通过。

截图命令曾被自动审批以“blocked by policy”拒绝；改用浏览器专用工具完成内联可视检查，没有宣称保存了被拒绝的截图文件。

全仓verify.ps1因缺少本地.env未完整执行，不导入生产秘密；iOS Swift未在Windows执行，本次不声明iOS验收。真实账号录像仅作本机私有证据，不纳入Git或公开分发。

## 交付记录

最终普通main成品位于 `debug-main-2220-r2/final.apk`（本次证据目录），126064986字节，SHA256 `117230f0bc263c67a605ab6ddf812f041bfe488249b96c8d7357b96d0eaf83c0`。install-main-2220-r2 PASS，设备回读SHA一致，UID10090及首次安装时间保持。最终被动检查进程稳定、主页面前台、致命异常模式计数0。固定签名为 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`；仅使用保数据覆盖安装，不卸载或清数据。历史详细过程见任务记录及证据目录 task-4-report.md、report-before-final-delivery.md。

真实录像抽查及首帧附近帧显示原生启动画面直接进入有摘要的真实列表，之后头像、名称和网络状态在同页更新，摘要没有整批消失。原生每可见帧断言与真实录像抽查是两份独立证据；录像抽查不冒充逐帧自动检测。r3原生am start TotalTime3976ms与Dart main_entry使用不同起点，不能相减。缓存内容仍在完整恢复前2527ms出现。

r2的admissionRejected原因未进一步细分；在重新生成有效缓存后r3命中。本次不承诺所有启动都命中缓存或零引擎等待，安全准入失败仍走恢复流程。用户可在当前已安装普通Debug上强制结束再打开，切换页面、进入已有房间滚动及自行发送测试；助手未向真人发送测试消息。

公开参考：[Android离线优先架构](https://developer.android.com/topic/architecture/data-layer/offline-first)、[Telegram TDLib开发说明](https://core.telegram.org/tdlib/getting-started)。采用本地展示与后台恢复分离的方向，不推断闭源即时通讯软件的内部实现。
