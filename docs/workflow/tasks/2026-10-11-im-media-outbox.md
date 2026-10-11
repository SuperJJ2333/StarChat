# R8 持久附件发送任务记录

## 恢复入口

- 目标/授权：用户已批准 IM remediation，根任务分派 R8/B2 持久媒体与生产接线；不部署、不打包。原生 helper 由根任务所有。
- 关联：docs/superpowers/plans/2026-10-11-im-reliability-remediation.md（集成 im-reliability 树）、原 client-plan-notes B1/B2；不改变 E2EE/托管/密钥边界。
- 当前状态：候选已完成本地专项，待独立双审和原生/共享候选验收。
- 负责人/树：review_r1_r2；C:/Users/Administrator/.codex/worktrees/im-media-outbox/StarChat。
- 所有权：core/outbox/media_outbox_store.dart、media_outbox_recovery_service.dart；Matrix media_outbox_sender/pending_view；AppHome/RoomPage/MatrixE2eeClient；对应八个单元/组件测试及一个原生 integration 入口。未改 native、依赖锁、共享 plan/current-state。
- 版本：base 4662f576d4c717f0a605e118ffe4c54da1226e5c，加预算原提交 82a8eca515b81a8747d2a45ea6992a3b0af8a8d8（本树 03b22fc0）。自有冻结输入见 [SHA 清单](../../verification/artifacts/2026-10-11/im-media-outbox/input-hashes.json)，最终提交由根任务交接消息提供。
- 最后更新时间：2026-10-11 05:28 UTC；下一步：冻结提交交根任务，SPEC/domain 后 Quality/Security，集成 native 后执行 media_outbox_persistence_native_test.dart。

## 验收台账

| ID | 场景/预期 | 实现/证据 | 发布/缺口 |
| --- | --- | --- | --- |
| R8-B2-source | 先 intent、受控原件、copy/flush、低空间/上限拒绝 | 64 KiB、16 MiB reserve、512 MiB/owner、128 pending；store/故障测试 | 未发布；native 保护待实际平台 |
| R8-B2-owner | 固定 account/home/generation、权限与 ACK 同 txid | public binding、前后身份复核；真实 SDK transaction fixture | 群加密/HTTP/local DB 使用 double |
| R8-B2-recovery | 700 次 interruption，恢复或可操作失败 | 7×100 SQLite/files reopen；35 专项总门禁 | 不等价于 OS 杀进程/真实设备 |
| R8-B2-fair | A 慢房不阻 B，新 C/重试仍准入 | 2 房真实 Future 槽；扫描锁不持有 transport；行为 RED→GREEN | 与生产真实网络组合待设备 |
| R8-B2-ui | 离页、重开、可见失败/重试/取消、明确预算错误 | camera 真 RoomPage、pending-view widget、coordinator/source fixture | 没有宣称完整 AppHome device gate |
| R8-B2-format | prepared/asFile/音频时长/视频尺寸不丢 | 数据库版本 2；SDK m.file、prepared video 无二次转码 | 可选缩略图允许重建 |
| R8-B2-native | 真实 FFI/保护/备份/重开 | 新无 mock integration 入口 | Windows 未运行，根任务 Android/iOS 必须执行 |

## 版本与证据

[验证报告](../../verification/2026-10-11-im-media-outbox.md) 包含具体命令、退出码、double 范围与门禁复用。Windows 10.0.19045.0，Flutter 3.44.9、Dart 3.12.2，锁文件未改。最终 35 PASS/0 skip；16 文件 analyze 0；62 相邻 PASS/0 skip。源码与日志哈希在 input-hashes.json。无包名/签名/镜像/生产观察，因为本任务未发布。

## 阶段计时

| 阶段 | 起止 UTC | 分类 | 结果/时间来源 | 下一步 |
| --- | --- | --- | --- | --- |
| 调查/契约 | 精确开始未记录；contract 首次写入 04:10:05 | 主动/工具 | 文件时间；不据此反推完整工时 | 实现 |
| test-first/接线/返工 | 已知证据区间 04:11:19–05:21 左右；完整边界未知 | 主动/工具/返工 | 保留 RED/早期 fixture 修正日志；不估成精确分钟 | 最终门禁 |
| 相邻门禁 | 05:15:55–05:16:09 | 工具 | adjacent-final.txt 创建/最后写入时间；进程 exit 0 | 输入不变复用 |
| 最终门禁（同组并行） | 05:22:26–05:23:23 | 工具 | 35 PASS；analyze 同始至 05:22:37 exit 0 | 文档/冻结 |
| 原生/共享门禁 | 待根任务 | 外部依赖 | 未执行，不能记完成 | Android/iOS 候选 fixture |

完整任务墙钟未知；以上为证据文件可观测区间，不相加冒充人工耗时。camera fixture 曾因 FakeAsync/实际 I/O 等待方式失败，后改为实际 I/O + pump；早期误差不当产品 RED。父审反馈的公平性/扫描锁为真实产品缺口，均追加行为 RED 后修复。

## 交接与回退

- 已确认：只改发送尾端不足以覆盖 prepare 前死亡，故把持久 intent 前移至视频 resolver、编辑 export 与 forward download 前；prepared source 需要独立保留 asFile/已准备语义。
- 两房调度若仍 await 全部 transport 会阻新扫描/计时重试；修复锁仅覆盖 discovery/admission，真实所有权保留在共享 flights/room slots。
- 仅候选、无生产备份/发布/隧道；没有运行中的本任务测试进程。根任务持有共享门禁/原生 CI。
- 回退候选 commit 不删除 pending 原件或数据库；新库独立且 schema additive。回退版无法恢复这些新任务，不能将保留文件视为可淘汰 cache。
- 恢复时先检查冻结 SHA/输入清单、根任务原生门禁结果和独立双审；不要依据当前文档宣称 R8 已可发布。

## 独立审查返工（2026-10-11 05:57 UTC）

根任务要求先冻结四阻断修复：resolver 意图写入阻塞、重试计时器较晚截止、替换实例取消活动 copy、旧 flight 迟到成为孤儿。实现和 RED→GREEN 见 four-boundaries-review-fix.md；新增真实准备 2 槽与跨 SQLite handle 的 128 原子 intent 上限门禁。已知返工区间由 review-regressions-behavior-red.txt 至 four-boundaries-final.txt 文件时间给出，不反推主动工时。当前下一步为独立复审；非默认 gallery duration 兼容分支按根任务指示留在当前发布范围之外。

## 同 txid 增量修复（2026-10-11 06:21 UTC）

独立复审暴露 duplicate preparing 导致原件被 source-incomplete 误伤；已按固定 root/owner scope/txid join 真实 preparation Future，8 个不可变字段先核对。最终同次 45 PASS、18 文件 analyze 0，700 故障迭代重跑。日志开始/结束时间和 SHA 见 duplicate-input-hashes.json；下一步为根任务触发 reviewer 增量 SPEC/domain→QUALITY，随后共享候选/原生门禁。未运行部署/打包，optional duration 继续排除。
