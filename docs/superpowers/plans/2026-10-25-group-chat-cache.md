# 群聊加载与缓存一致性维护计划

> For agentic workers: use executing-plans for inline TDD; specification review precedes quality/security review.

**Goal:** 在上轮时间顺序修复基础上检查并修复消息加载、缓存复用问题，安全核查本仓库 C 盘 Codex 工作树。

**Architecture:** 保留 Matrix/本地加密存储权威和 40/200 消息窗口。展示缓存的复用同时受数据和分页边界约束；引用缓存按事件更新失效、按实际读取更新淘汰顺序。所有新缺陷先有失败测试，未证实的问题不改产品代码。

**Tech Stack:** Flutter/Dart、Matrix SDK、Git、PowerShell 7。

**Spec:** 用户 2026-10-25 本轮检查/修复授权；既有产品规格 `../specs/2026-08-12-starchat-product-modernization-design.md`、已批准的缓存启动/滚动契约，延续上轮 `2026-10-25-timeline-chronology.md`。

## 边界及所有权

- 父任务独占 `matrix_e2ee_client.dart`、`matrix_room_timeline_adapter.dart`、`room_timeline_controller.dart`、`message_timeline_cache.dart`、`room_page.dart`、`logical_conversation_timeline.dart`，新建 `test/features/matrix/group_chat_cache_regression_test.dart`、既有 `room_page_lifecycle_test.dart` 和本任务文档。页面范围由规格审查发现的引用状态机旧正文问题及真实 UI RED 确认后纳入；逻辑会话按原来源读取窗口外引用，通过 `red-retained-reply.log` 复现后补齐跨快照的有界路由信息。质量审查指出旧式 fallback wrapper 的兼容 seam，`red-legacy-wrapper.log` 证实后由 adapter 接管原128项有界缓存、隐藏与处置后迟到结果检查。
- 不改钱包、认证、E2EE 密钥/协议、SDK 存储、依赖或版本；本轮仍交付源码/验证，不打包发布。
- 工作树复用 maintenance-completion，基线 `20962711`，新分支 `codex/group-chat-cache-20261025`；保留主树 509 项既有删除。
- 独立代理只读盘点 worktree，不能删除、归档或修改引用；实际清理由父任务按证据逐项执行。

## 步骤

- [x] 写分页边界变化但事件相同、旧引用撤回/更新、热点引用淘汰的回归，运行并保存 RED；补关闭会话、控制器副本、隐藏历史、编辑和真实引用卡片三场景。
- [x] 仅修复已确认根因：缓存复用条件、账户监听与页面状态机对应引用失效及 LRU 读取提升，保留账户/房间隔离和容量。
- [x] 跑定向、加载/引用/窗口相邻与 5 万历史/千人群性能检查；规格→质量/安全审查后冻结源码运行 Flutter/analyze 和适用移动门禁。最终6410 PASS/9诊断SKIP、诊断变体9 PASS、移动404 PASS/1 Ruby SKIP，详见报告。
- [x] Git fetch 后逐项记录 C 盘 Codex worktree 状态；仅清理无修改、无未推送提交、已合入且无占用的树。恢复28份归档/清单的独立受限副本并核验SHA；31棵树0可安全删除，正常删除2条已合入无人检出的旧维护分支引用。其余保留。
- [x] 报告写明结果、证据输入身份、条件跳过、原生/真机缺口及清理/保留原因，源码提交0e9a760b，文档另行提交并更新候选 current-state。

## 审查重点

边界独立变化、旧历史窗口、消息撤回/编辑、更新抵达时的进行中引用解析、跨账号/房间、缓存容量、群成员通知及滚动锚点。worktree 的“较旧”不能作为删除依据；不强推、不改写历史、不提交配置和数据备份。

完整门禁发现新增失效监听对无消息身份的回执额外通知；既有性能测试单独复现后，在同一所有权文件内加事件ID条件。定向含两个原失败文件共121项通过，再进行增量规格→质量审查与冻结全量，不改变原性能断言。
