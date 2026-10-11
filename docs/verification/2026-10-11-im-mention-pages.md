# R7a 提及正文固定页扫描

## 恢复入口与授权

- 按已批准 `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md` R7a，主任务授权此子任务实现、测试及提交；不部署。
- 独立工作树 `C:/Users/Administrator/.codex/worktrees/im-mention-pages/StarChat`，分支 `codex/im-mention-pages`，起点 `8475a0b4`；为保留已经释放的 R8cap 接线，先 cherry-pick `ffe49562` 为 `b611c1ba546d8a87d3419b4bbd446bce3e6b9daf`。只把此后的 R7a 提交交给集成者。
- 所有权：`room_mention_store.dart`、`unread_mention_tracker.dart`、新 `mention_history_scan.dart`、提及测试；`matrix_e2ee_client.dart` 已获 R8 owner 释放，只调整扫描组合。未改 AppHome/main、媒体、密钥或加密合同。
- 当前：专项 51 PASS，7 个修改 Dart 文件范围 analyze exit 0、无问题；等待主任务独立 SPEC → QUALITY 审查。全量 Flutter、原生构建/真机由最终候选统一执行。

## 根因、实施与兼容边界

旧 `scan()` 通过 `room.getTimeline()` 持续累积正文，每次加载历史后将累计 Event 列表重新 ingest。100k 懒生成夹具在第二页已实际保留 512 个 Event，超过 256 预算，先得到预期 RED。

新 reader 通过 SDK 公有 `openTimelineIdSnapshot` 固定 scan head 和初始 read marker，以 256 IDs 发现目标区间；需要网络历史时只调用 `Room.requestHistory(historyCount: 256)`，随后从原 tail 之后继续打开 snapshot，不重新纳入并发到达的新 head。先定位边界并注册稳定顺序，再由 `next(limit: 256)` 读取当前正文页，消费后 `release()` 清空页内引用。每个正文仅加载一次，ID 发现、顺序注册和正文消费均为线性工作量。

主任务明确接受本批保留 O(N) ID 元数据，同时要求元数据注册也逐页许可/取消。`registerOrder()` 每 256 IDs 获取共享 MaintenanceActivity 许可，先按已知锚点确定 rank，再逐页注册；tracker 的最大 rank 为内存缓存，解码旧字段重建，不增加 JSON schema。原实时 ingest coalescer 保持；扫描页使用 `persist: false`，整轮只做一次 metadata JSON 写入，避免每页重新编码累计数据。

所有正文页持有共享 maintenance lease，消费释放；交互期间不启动下一页，500ms 安静后恢复。25ms 取消检查可结束挂起的本地读或维护等待，迟到读结果不 ingest。取消回调在每次读取结束后移除，避免把每个已完成 Event 的 Future 结果留到整轮取消。checkpoint 只在整个固定区间处理完成后更新；写入前撤销会恢复内存原 head，外部清空历史更新的 head 不被扫描覆盖。

R7d 兼容边界：继续使用 `chat-mentions-v2:<account>:<room>` 与原 pending/viewed/orders/timelineOrders/boundary/completedScanHead 字段。`registerTimeline` 增加可选 `newestOrder` 参数，供固定区间分段注册；原调用行为保留。本批 reader 保留 ID 列表/去重 metadata，tracker 仍保存历史 IDs，最终 JSON 编码仍 O(N)；**仅正文常驻有界，不声称总内存固定或元数据已经压缩**。R7d 可基于本输入做版本化迁移，不能截断 viewed。

## 门禁与证据

证据目录：`docs/verification/artifacts/2026-10-11/im-mention-pages/`。

| 场景 | 结果 | 证据 |
| --- | --- | --- |
| 100k 旧累计正文超过预算 | RED：实际 512 > 256；保护性取消后报告失败 | body-bound-red.log |
| 1k / 10k / 100k 正文页 plateau | 峰值页 256；保留旧 page 对象也不保留已消费正文；每 payload 读取一次 | focused-green.log |
| 固定 head/read marker、不可达 marker、并发新 head、远端历史追加 | GREEN；固定 head 不前移，未知边界可恢复，正文不重读 | focused-green.log |
| 已查看/撤回、普通回执、late decrypt、恢复排序 | 新边界用例及原文件全部通过 | focused-green.log |
| 500ms quiet、挂起读取消 ≤200ms | 注入测试时钟 GREEN，取消后无 checkpoint/迟到 ingest | focused-green.log |
| checkpoint 写入前撤销 | RED→GREEN；内存与持久记录无候选 head | checkpoint-red.log / focused-green.log |
| ID 注册每 256 页许可/取消 | 先 RED：整段同步注册；后 GREEN：第 256 ID 后交互暂停并取消，不进入 payload | metadata-gate-red.log / focused-green.log |

在 `apps/mobile_flutter` 执行：

```text
flutter test --no-pub test/features/matrix/mention_history_scan_test.dart test/features/matrix/mention_scan_cancellation_test.dart test/features/matrix/mention_timeline_order_test.dart test/features/matrix/unread_mention_tracker_test.dart test/features/matrix/room_mention_ingest_coalescer_test.dart test/features/matrix/search_mention_cache_regression_test.dart test/features/matrix/mention_wiring_regression_test.dart --reporter expanded
```

exit 0，**51 PASS**，无跳过。新 reader 使用真实 SDK snapshot 契约的 `ListTimelineIdSnapshot`，Room/数据库/历史响应为注入合成夹具；不把这些结果当作 SQLCipher 原生历史或设备 heap/profile 结果。`integration_test/cache_first_fast_history_test.dart` 已接入合成提及分页组，尚未运行设备 gate。

Windows 10.0.19045 / PowerShell 7.6.5，全部 terminal 为 pwsh + UTF-8 无 BOM，Python UTF-8。Flutter 3.44.9 (`6b182d2c75`) / Dart 3.12.2，`C:/src/flutter`；从既有 local.properties SDK 路径复用。离线 enforce-lockfile pub get exit 0，无依赖变动/全局缓存修改；锁身份见 input-hashes.json。不因任务拆分重复全量 gate；隔离树没有 `.env`，不导入生产配置运行 verify.ps1。

## 阶段与下一步

- 11:42–11:46+08：隔离树、R8 owner 释放及 SDK snapshot/维护接口核对。
- 11:48–11:53+08：正文预算 RED→GREEN、固定边界与取消夹具。
- 11:54–12:00+08：原专项、checkpoint RED→GREEN、按 root 要求补 ID 注册逐页 RED→GREEN。
- 精确主动/工具时长未连续计时；测试日志执行约 6 秒不等于任务总墙钟。

下一步：按冻结输入完成独立规格审查后质量审查，修复发现项，再交主任务合入。回退只回退扫描器接线/实现，不清库、不删除聊天正文或恢复密钥、不重建账号。最终真机快滑/键盘/切房、弱网与原生 SDK 读写仍待最终候选验收。
