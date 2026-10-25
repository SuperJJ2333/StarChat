# 群聊消息加载与缓存维护

## 恢复入口

- 目标与授权：2026-10-25 用户要求检查并修复消息加载/缓存、优化多人群聊，同时核查本地 Codex worktree 的冗余落后分支。延续上轮“先交付源码与验证”，不打包、签名、发布或推送。
- 计划：[群聊缓存维护](../../superpowers/plans/2026-10-25-group-chat-cache.md)；基线 `20962711c90b58d84e69a79a4147d636c5e691d9`，已包含上轮时间顺序修复 `29384fed`。
- 当前状态：本轮源码修复与安全清理完成；规格→质量/安全含增量复审、最终完整Flutter及适用移动门禁通过（Ruby条件跳过保留）。源码提交 `0e9a760b13c8b7c53a141c4be89b4bf3663ee24a`。
- 工作树：C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat；分支 `codex/group-chat-cache-20261025`。父任务独占计划中的 6 个展示/缓存生产文件、2 个测试文件与文档；独立代理只写审计/审查证据。
- 主树 `main@b89f0c43` 既有 509 项删除等改动保留。未合并或改写历史。
- 更新时间：2026-10-25 14:53 +08:00；下一步：交付本候选源码，后续按用户要求准备新构建与iPhone保数据升级/多人群聊真机验收；不要把本轮宿主测试当作已发布修复。

## 验收台账

| ID | 场景与预期 | 当前实现及证据 | 发布/真机 |
| --- | --- | --- | --- |
| CACHE-1 | 空页结束/边界变化时 pending 仍按原时间正确显示 | 本地及账户队列双向边界 RED→GREEN；缓存复用包含边界 | 源码候选，未真机 |
| CACHE-2 | 引用撤回、隐藏、更新后不显示旧缓存 | 账号监听→房间缓存→控制器→页面状态机完整失效链；关闭重进及迟到解析回归 | 真实 Flutter 页面三场景通过；不是 iPhone 验收 |
| CACHE-3 | 热门引用复用及有界群聊窗口 | 256 项 LRU 读取提升；40/200 窗口、50,000 历史及 1,000 sender pool 合成测试 | 不代表真实千人服务器压测 |
| CACHE-4 | 合并旧房间后远距离引用可复用/失效 | 原 source 权威 find、256 项有界路由 hint；专门 RED→GREEN | 源码候选 |
| CACHE-5 | 旧式适配器引用兼容，纯回执无额外消息刷新 | fallback 128项预算、隐藏/处置防护；监听仅在存在事件ID时通知，两条原性能断言RED→GREEN | 源码候选 |
| WT-1 | 只清理满足全部安全条件的 C 盘本项目树 | 31 棵盘点，安全候选 0；9 dirty、23 未合入/远端不可达，集合重叠；2条已合入无人检出的旧维护分支用branch -d清理并记录恢复SHA | 0工作树删除、2引用删除、0强制操作 |
| WT-2 | 历史归档独立副本可恢复 | 原 D 盘副本缺失已恢复：28 文件 / 9,892,541,569 bytes，历史/源前后/目标 SHA 相同，受限 ACL | 原件保留，未入 Git |

## 版本与证据

本轮没有构建包。Android2233 / iOS2215 的历史发布身份及 0.4.65+2234 既有未签名 IPA 身份保留；本轮没有查询实时生产状态，旧 IPA 不包含本轮和上轮之后的源码修复。

证据根：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/group-chat-cache/，Git 忽略。规格初审 BLOCKED、全量回执通知2项FAIL及取消原件保留；补充修复后规格及质量/安全两轮增量均PASS。最终定向 `green-receipt-refresh.log` 为121 PASS/exit0（9整文件）；最终完整Flutter6410 PASS/9诊断开关SKIP/0 FAIL、analyze exit0，运行前后源码稳定；诊断开启变体9 PASS覆盖默认跳过项。最终移动404 PASS/1 Ruby SKIP、UI34/540 PASS、格式8文件0变化，delivery-validation.json确认审查/运行/交付8文件身份一致及主树未变。完整结果见[验证报告](../../verification/2026-10-25-group-chat-cache.md)。

环境前置：Python3.12.10、Flutter3.44.9/Dart3.12.2、既有 Olm/SQLCipher DLL SHA、任务 V: 短路径映射；`scripts/verify.ps1 -PreflightOnly` exit0。本机短信有效期只在测试进程设15，不修改配置校验或 .env。

## 阶段计时

| 阶段 | 已记录时段（UTC+08） | 结果 |
| --- | --- | --- |
| 初始调查/CodeGraph/Git盘点 | 起点未记录，精确主动耗时未知 | 主树图作调用链参考；候选无索引，以当前源码/实测为准 |
| 最初有效 RED | 13:52:23–13:52:33 | 5 个行为失败；随后扩至 7 FAIL/1 PASS |
| 初次缓存 GREEN | 13:57:10–13:57:18 | 8 PASS |
| 相邻门禁 | 14:03:14–14:07:13 | 626 PASS，属较早候选；不是最终全量证明 |
| 归档恢复（独立并行组） | 14:10:15–14:11:08 | 28 文件匹配旧 SHA，ACL复核 |
| 规格审查与补充修复 | 详细 RED/GREEN receipts；主动耗时未知 | 闭合5初审项及1多source兼容回归 |
| 先前定向 | 14:17:57–14:18:15 | 80 PASS，后续兼容扩展至114 PASS |
| 全量暴露回执刷新回归 | 14:28:42–14:38:28 | 6408 PASS/9 SKIP/2 FAIL；保留 failed-full* |
| 回执定向 RED→GREEN | 14:38:53–14:39:30 | 5 PASS/2 FAIL→9文件121 PASS |
| 最终移动/UI | 14:40:14–14:40:57 | 404 PASS/1 Ruby SKIP、UI34/540 PASS |
| 最终冻结全量 | 14:41:57–14:52:54 | 6410 PASS/9诊断SKIP、analyze0、source_stable=true；不将重叠时段简单相加 |
| 源码提交及交接核验 | 14:53 | 0e9a760b，8文件审查/测试输入SHA一致，主树516条状态一致 |

初期 Fake 缺少 enableResidentWindow、单条格式 lint、页面测试全局缓存未隔离/在 widget fake-async 外清理导致的返工日志保留；最后 UI RED 为三个旧正文真实展示失败，无 drainTimeout。所有门槛未通过均如实保留，不用绿色最后一条覆盖旧失败。

## 交接与回退

- 本轮仅改设备端展示缓存/消息投影，不改资金、认证、E2EE 密钥协议、SDK持久化、锁/版本。
- 外部备份：D:/StarChat-maintenance-backups/2026-10-22-worktrees；`backup-receipt.json`绑定历史和复制校验。含配置/数据，仅当前用户与SYSTEM，不提交。
- interactive-cache-startup 的其余约81.79GB忽略材料尚未保全并关联6个未归档chat；保留承载树。
- PID187384 flutter_tester 仍持维护树句柄，创建于12:54:42、原父进程已不在；无法确认是本任务创建，未关闭。
- 需要真机验证：冷启/上下翻历史/失败气泡/大群突发、窗口外引用撤回/隐藏/编辑后重新解析、保数据升级。前次 iOS 原生 Outbox 两项 MEDIA_STORAGE_UNAVAILABLE 缺口按旧报告保留。
- 回退使用普通 revert；不清用户缓存，不改写历史。
