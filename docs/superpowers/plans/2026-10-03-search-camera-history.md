# 搜索、系统相机和三天历史 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development, one implementer at a time, independent specification/domain then quality/security review per task and broad final review.

**Goal:** 修复S1/C1/H1，验证旧事件定位、系统拍摄和安全72小时历史补齐，交付可测试debug。
**Architecture:** 复用现有本地搜索及Matrix event context；收窄Android相机可见性/授权；以账号client租约协调有界历史补齐和现有密钥恢复。
**Tech Stack:** Flutter3.44.9/Dart3.12.2，固定Matrix0.34.0/image_picker_android0.8.13+23，Android原生。
**Spec:** ../specs/2026-10-03-search-camera-history-design.md

## Global Constraints
- PowerShell7/UTF8，PythonUTF8；无.codegraph；不读取/发送/保留真实明文、tokens、keys。
- 工作树C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat；显式文件提交，主工作区WIP保持。
- 500*1024图片预算、E2EE、账号撤销、本机清空/隐藏/闪图和财务边界保持。缺密钥不能伪造解密。
- Evidence only docs/verification/artifacts/2026-10-03/search-camera-history；root owns shared docs/versions/build/platform CI/integration.
- User standing autonomy resolves approval pauses; implementers cannot spawn further agents or change versions/root docs. One implementer and one independent reviewer max; Flutter/Gradle exclusive window.

## Review Focus
- Search own pagination/decryption vs security invalidation, continual sync and route closure.
- Year-old anchor must use eventId/source room context and not newest-first unbounded scanning.
- Hidden/recalled/cross-account event must never leak during context adoption or failure.
- Restricted camera package visibility and file grant, denied permissions/cancel/duplicate pick.
- 72h loading all room types, non-message pages, transient failure and late A callback after B login; missing/late key availability.

### Task 1: Search stability and old event context
**Files:** Modify lib/ui/chat/chat_search_page.dart, lib/features/matrix/room_page.dart, chat_search_query_controller.dart, bounded_history_search.dart, room_timeline_controller.dart, matrix_room_timeline_adapter.dart, matrix_e2ee_client.dart and narrow new event-context capability. Tests corresponding test/ui/chat/chat_search_page_test.dart, test/features/matrix/room_timeline_controller_test.dart, SDK adapter/history tests. Paths under apps/mobile_flutter. Exact changed file list declared before edit.
**Interfaces:** consumes current optional timeline/date capabilities and localSearch snapshots; produces generation-safe explicit eventId locator exposed through timeline capability/adapter/controller, preserving legacy adapters.
- [ ] Trace baseline callbacks, write actual behavioral failing search-self-update and old-event SDK/context tests, run intended RED.
- [ ] Implement bounded stable queries and direct context/adoption with cancel/visibility checks; no unrelated calendar redesign.
- [ ] Focused GREEN/analyze, adjacent local search/history/logical timeline tests; report commands/exits/input/durations in task-1-report.md. Commit explicit source/tests only.
- [ ] Independent domain/spec then quality/security review; resolve load-bearing findings.

### Task 2: Honor system photo/video capture
**Files:** AndroidManifest.xml; media_message_service.dart and room_page.dart only if required, narrowly scoped Android native helper if evidence needs it. Test new camera contract tests plus native intent/file grant tests and existing camera/media policy tests. No Matrix transport/history edits.
**Interfaces:** captureToFile/captureVideoToFile return path or null(cancel); existing send pipeline/account guards unchanged.
- [ ] Trace pinned plugin and merge manifest; RED restricted activity visibility and photo/video permission/output grant behavior.
- [ ] Fix root cause with targeted camera queries/URI rights or narrow compatible wrapper; classify cancellation/permissions/action unavailable without masking failures.
- [ ] GREEN Dart/manifest/native tests plus Android compile; report and explicit commit.
- [ ] Independent domain/spec then quality/security review; close regressions.

### Task 3: Account-scoped recent history warmup
**Files:** matrix_e2ee_client.dart, matrix_recovery_service.dart, matrix_security_page.dart, app_home.dart/settings recovery entry and optional narrow recent-history coordinator; vendored Matrix src/client.dart, src/room.dart, src/database/database_api.dart, src/database/matrix_sdk_database.dart, encryption/key_manager.dart only for declared independent-cursor import/backup-validation interfaces; frontend/src/catalog and packages/ui-contracts/changliao-component-registry.json for recovery UI parity; core/session_bootstrap_controller.dart/features/auth/login_controller.dart only if needed. Tests SDK history/restore/account lifecycle + new coordinator tests. Public interface if needed declares before touching.
**Interfaces:** consumes a captured immutable account lease, independent-cursor raw page fetch/transactional checkpoint CAS, bounded stored-ciphertext replay and actual backup version binding; see ADR 2026-10-03-account-recent-history-hydration D1–D5/Q1–Q4. Reachable authenticated recovery-key entry and actual key import/replay, no fake usable SAS route; task1 event context must remain correct. Produces cancellable bounded recent72h hydration scheduled once per authorized login/recovery, transient retry and secure account teardown.
- [ ] Confirm current sync only limited latest events; author concrete ADR and obtain ordered independent design review before protected wiring.
- [ ] RED actual login/new-device/account-switch missing history and recovered-key retry, then implement bounded pagination with encrypted database persistence and account fencing.
- [ ] GREEN room/time/no-progress/retry/missing-key/revoke tests, SDK integration, auth/recovery regressions and analyze; report and explicit commit.
- [ ] Independent domain/spec then quality/security review.

### Task 4: Final validation and debug delivery
**Files:** root shared task/index/report/pubspec/AppConfig/paired version tests/build helpers only after candidate review; frontend/src/screens/messaging.js、frontend/src/catalog/screens.js、packages/ui-contracts/changliao-component-registry.json及聚焦HTML测试在Task3释放相应所有权后同步搜索进度/旧事件定位/真实失败文案状态。
- [ ] Whole candidate independent review; full Flutter/analyze, relevant Python/frontend/native/platform checks, preflight verify.ps1 and record limits.
- [ ] 搜索HTML示例和registry同步已有Flutter的稳定进度、旧消息定位与可重试错误状态；恢复页面的HTML/registry由Task3先交付，root不得同时编辑共享registry。合并后验证屏幕计数、token与行为一致。
- [ ] Re-read live version/CI and emulator; freeze next version/source. Build conventional rebuilt stable-signed x86_64 debug; preserve-data install and launch smoke, same-source iOS native validation.
- [ ] Integrate/push reviewed changes preserving unrelated WIP, primary artifact/evidence, cleanup only own branch/worktree. Report physical Honor/K80 and new-device key acceptance limits separately.
