# R8 持久附件发送候选验证

本候选把文件、相机、语音、相册、编辑导出、视频和媒体转发接入独立持久原件目录，先保存 intent/source，再进入发送协调器。进程中断后保留固定 txid；未获确认的事件可以重传 blob，但事件 transaction URL 不变。闪照保留原有不落盘边界。

## 源码与契约

- 工作树：im-media-outbox；集成基线 4662f576d4c717f0a605e118ffe4c54da1226e5c；预算前置原提交 82a8eca515b81a8747d2a45ea6992a3b0af8a8d8，本树 03b22fc082e61b65a937fe1c868d6d140d59518b。
- [冻结契约](artifacts/2026-10-11/im-media-outbox/contract.md)、[输入 SHA-256](artifacts/2026-10-11/im-media-outbox/input-hashes.json)、[任务记录](../workflow/tasks/2026-10-11-im-media-outbox.md)。输入清单包含 16 个自有源码/测试文件、依赖锁、预算及相关 SDK 输入。
- 原件每 owner 512 MiB，128 条非终态上限，16 MiB 空间保留；64 KiB copy/flush；失败/部分写入也计入磁盘占用。此上限不表示历史账号总量或 tombstone 元数据有相同全局上限。
- 真实 transport 最多同时占用 2 个房间；扫描锁不等待 transport。取消与换账号不会靠 UI timeout 释放仍在使用的文件或槽位。服务端 429 截止也约束手动重试。

## 本地门禁

环境：Windows NT 10.0.19045.0，PowerShell 7 UTF-8 无 BOM，Flutter 3.44.9 / framework 6b182d2c75 / Dart 3.12.2。pub get --offline --enforce-lockfile 完成，pubspec.lock 未修改。命令的 working directory 为 apps/mobile_flutter；下列日志来自原始进程输出，退出码分别为 0。

1. 最终 35 项专项全部通过，含 7 个边界各 100 次真实 SQLite/文件重开（共 700 次 synthetic interruption）。命令：flutter test --no-pub test/core/outbox/media_outbox_store_test.dart test/core/outbox/media_outbox_recovery_service_test.dart test/core/outbox/media_outbox_sdk_transaction_test.dart test/core/outbox/media_outbox_fault_boundaries_test.dart test/core/outbox/pending_media_directory_test.dart test/features/matrix/media_outbox_coordinator_test.dart test/features/matrix/media_outbox_camera_entry_test.dart test/features/matrix/media_outbox_pending_view_test.dart。证据：[focused-after-scan-lock.txt](artifacts/2026-10-11/im-media-outbox/focused-after-scan-lock.txt)。0 failure / 0 skip。
2. 16 个自有源码、测试及原生入口文件 dart analyze：No issues found。证据：[analyze-after-scan-lock.txt](artifacts/2026-10-11/im-media-outbox/analyze-after-scan-lock.txt)。输入清单列出完整路径。
3. 62 项相邻测试通过：video_forward_backend_test、canonical_send_guard_test、media_transfer_budget_test、media_transfer_admission_test、media_upload_preflight_test、matrix_media_upload_limit_test（均位于 test/features/matrix）。命令同为 flutter test --no-pub 加这六个完整路径。证据：[adjacent-final.txt](artifacts/2026-10-11/im-media-outbox/adjacent-final.txt)。最后一次修改仅 recovery 和相关专项测试，以上 Matrix/RoomPage/预算输入保持不变，因此复用这一门禁；0 failure / 0 skip。

## RED → GREEN 与证据范围

初始缺少持久库/API 的 RED 为编译失败，分别见 store-red、recovery-red、coordinator-red、pending-view-red、prepared-semantics-red、deferred-export-red-verified。deferred-export-red 的更早一次存在 fixture import 错误，不能充当产品行为 RED。它们之后均由最终专项覆盖。

真实行为 RED 包括：取消 copy 时 .part 仍被使用（copy-cancel-red）；慢房间阻挡其他房间（room-fairness-red）；手动重试越过一小时 429 截止（hard-429-red）；预建 symlink 改写目录外测试文件（symlink-red）；超出磁盘上限仍准入（pending-cap-behavior-red）；A 挂起时 recover 锁使新 C 与 B 定时重试无进展（recovery-scan-lock-red）。对应最终专项均 GREEN，独立小门禁保留在同目录。扫描锁最新回归保持 A pending，验证 C 新扫描进入空槽、B 实际 2 秒计时重试，不使用 UI timeout 释放 A。

700 次故障是测试进程内注入 Error 后关闭/重新打开实际数据库和文件，不是 700 次操作系统杀进程。它们使用 synthetic 事件 ledger；独立 SDK 测试另走实际 Matrix SDK 和生产 sendPersistedMedia，验证 ACK 丢失后相同 transaction URL、文件图片仍 m.file、prepared video 无二次转码。SDK HTTP、群加密入口和 Matrix 本地 DB 有 double；附件加密与 SDK sendFileEvent/sendEvent 路径真实。日志中的 SocketException 是明确注入的 ACK-loss 场景，不是真实网络故障。

真实 RoomPage camera widget + lease + SQLite 测试验证原件独立后离页发送；相机平台与 sender 是 double。coordinator 用例涵盖延迟导出/相册 resolver/媒体转发的 intent-before-work 和不保留大 bytes；SDK发送单独验证。Pending-view widget 验证重开失败行及取消。没有声称完整 AppHome 设备端生命周期已跑通。

## 未完成的平台/集成验收

本地 provider 测试模拟 MethodChannel，只验证映射及 fail-closed。新增 integration_test/media_outbox_persistence_native_test.dart 不 mock channel/SQLite，必须在真实 Android/iOS 候选执行；Windows 未执行此项。尤其不能据此宣称 iOS 文件保护、备份排除或移动 FFI 可用已验收。

根任务负责原生 helper 同源集成、独立 SPEC/domain 后 Quality/Security 审查、完整 Flutter/analyze 与 scripts/verify.ps1 共享门禁、设备启动/升级/恢复验收。本树只验证上述变化范围，没有运行或替代这些共享门禁。未部署、未打包、未发真实推送或用户附件。下一步是根任务集成后运行原生 fixture，再按审查问题补最小回归。

源码/Markdown 的 git diff --cached --check 通过。原始 RED 日志保留 Flutter 输出中的空白行，完整日志范围的 diff --check 会提示这些 trailing whitespace；为保持证据原样未改写日志。
