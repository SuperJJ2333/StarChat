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
- User standing autonomy resolves approval pauses; implementers cannot spawn further agents or change versions/root docs. One implementer max; Flutter/Gradle exclusive window. Task2 frozen source review and Task3 new custody design review may run concurrently as read-only independent scopes; no concurrent source writes/tests and protected implementation waits for its own ordered design PASS.

## Review Focus
- Search own pagination/decryption vs security invalidation, continual sync and route closure.
- Year-old anchor must use eventId/source room context and not newest-first unbounded scanning.
- Hidden/recalled/cross-account event must never leak during context adoption or failure.
- Restricted camera package visibility and file grant, denied permissions/cancel/duplicate pick.
- 72h loading all room types, non-message pages, transient failure and late A callback after B login; missing/late key availability.

### Task 1: Search stability and old event context
**Files:** Modify lib/ui/chat/chat_search_page.dart, lib/features/matrix/room_page.dart, chat_search_query_controller.dart, bounded_history_search.dart, room_timeline_controller.dart, matrix_room_timeline_adapter.dart, matrix_e2ee_client.dart and narrow new event-context capability. Tests corresponding test/ui/chat/chat_search_page_test.dart, test/features/matrix/room_timeline_controller_test.dart, SDK adapter/history tests. Paths under apps/mobile_flutter. Exact changed file list declared before edit.
**Interfaces:** consumes current optional timeline/date capabilities and localSearch snapshots; produces generation-safe explicit eventId locator exposed through timeline capability/adapter/controller, preserving legacy adapters.
- [x] Trace baseline callbacks, write actual behavioral failing search-self-update and old-event SDK/context tests, run intended RED.
- [x] Implement bounded stable queries and direct context/adoption with cancel/visibility checks; no unrelated calendar redesign.
- [x] Focused GREEN/analyze, adjacent local search/history/logical timeline tests; report commands/exits/input/durations in task-1-report.md. Commit explicit source/tests only.
- [x] Independent domain/spec then quality/security review; resolve load-bearing findings.

### Task 2: Honor system photo/video capture
**Files:** AndroidManifest.xml; media_message_service.dart and room_page.dart only if required, narrowly scoped Android native helper if evidence needs it. Test new camera contract tests plus native intent/file grant tests and existing camera/media policy tests. No Matrix transport/history edits.
**Interfaces:** captureToFile/captureVideoToFile return path or null(cancel); existing send pipeline/account guards unchanged.
- [x] Trace pinned plugin and merge manifest; RED restricted activity visibility and photo/video permission/output grant behavior.
- [x] Fix root cause with targeted camera queries/URI rights or narrow compatible wrapper; classify cancellation/permissions/action unavailable without masking failures.
- [x] GREEN Dart/manifest/native tests plus Android compile; report and explicit commit.
- [x] Independent domain/spec then quality/security review; close regressions.

### Task 3: Account-scoped recent history warmup
**Files:** matrix_e2ee_client.dart, matrix_recovery_service.dart, matrix_security_page.dart, app_home.dart/settings recovery entry and optional narrow recent-history coordinator; vendored Matrix src/client.dart, src/room.dart, src/database/database_api.dart, src/database/matrix_sdk_database.dart, encryption/key_manager.dart only for declared independent-cursor import/backup-validation interfaces; frontend/src/catalog and packages/ui-contracts/changliao-component-registry.json for recovery UI parity; core/session_bootstrap_controller.dart/features/auth/login_controller.dart only if needed. Tests SDK history/restore/account lifecycle + new coordinator tests. Public interface if needed declares before touching.
**Interfaces:** consumes a captured immutable account lease, independent-cursor raw page fetch/transactional checkpoint CAS, bounded stored-ciphertext replay and actual backup version binding; see ADR 2026-10-03-account-recent-history-hydration D1–D5/Q1–Q4. Reachable authenticated recovery-key entry and actual key import/replay, no fake usable SAS route; task1 event context must remain correct. Produces cancellable bounded recent72h hydration scheduled once per authorized login/recovery, transient retry and secure account teardown.
- [x] Confirm current sync only limited latest events; author concrete ADR and obtain ordered independent design review before protected wiring.
- [x] RED actual login/new-device/account-switch missing history and recovered-key retry, then implement bounded pagination with encrypted database persistence and account fencing.
- [x] GREEN room/time/no-progress/retry/missing-key/revoke tests, SDK integration, auth/recovery regressions and analyze; report and explicit commit.
- [x] Independent domain/spec then quality/security review.

### Task 3 override: Server-custodied automatic recovery (2026-10-04 user instruction)

以上Task3的client-only/手工恢复入口由本节和[新ADR](../../adr/2026-10-04-server-custodied-matrix-recovery.md)覆盖；原有独立游标/内存/账号drain验收保持。正常用户无需恢复密钥/SAS。具体固定提案server-recovery-custody-proposal.md SHA76b44279a2f45a79ed8001702a41b7e2a54ec04cb8d7f9882c6caf9a2978684a已纳入ADR，先独立领域/规格再质量安全设计审查。无源码保护改动可复用旧client-only批准。

#### Task 3A: Matrix custody service and current-account authorization

**Files:** 新third_party/synapse/chatflow_recovery_vault.py及必要窄crypto/store/versioned migration、Dockerfile/README；services/business-api/app/api/identity.py及独立identity recovery authority/service、OpenAPI和对应测试（implementer先核实实际路径）；infra/synapse/homeserver.yaml.template、render_config、专用Compose overlay/nginx命名空间、systemd凭据配置、专用provision/rotation/DR helpers及runbook。root共享ADR/规格/任务/版本/生产操作不交给源码implementer。不得修改SDK/Flutter相机、金融规则或原生备份SSSS。

**Public interfaces:** 专用`/_matrix/client/unstable/com.starchat.recovery/v1` status/enrollment/material/session PUT/query，与仅身份元数据的`/api/v1/auth/matrix-recovery-authorize`；具体UUID幂等/CAS/双bearer/分页/error契约见新ADR及固定提案§3。独立namespaced module migration ledger，不改Synapse核心schema92/现有媒体delta。OS生产secret provider + 独立DPAPI DR provider按ADR、POSIX和实际隔离restore证明。

- [x] 整体托管ADR/规格/本计划领域审查再安全审查PASS；冻结公共wire/数据契约和provider计划。
- [x] RED真实PG并发、crypto/authority/migration/rollback/secret-provider failure gates；最低修复实现main-only模块、唯一owner集合信封、保留session候选、严格当前family/device授权、no-store/no-secret-logs；支持响应丢失重试。
- [x] GREEN专项Python/nativeSynapse/真实PG及helper Linux/Windows synthetic interop/恢复演练；准确报告实际输入hash与环境/未验生产事实。输出公开协议固定JSON schema供3B消费。
- [x] 每个新wrapping key先primary-inactive→独立DPAPI保存/读回确认，之后才active-write/rewrap；失败/丢ack/混合旧新信封主机丢失的真实隔离restore用例，旧active/旧key保留。Staff业务角色本身不排除本人合法mobile session。
- [x] R1真实client leaf遮蔽修订：public BASE不变，main ModuleAPI仅挂private `/_synapse/client/chatflow/recovery/v1`，精确Nginx public-prefix映射且公网private拒绝，namespace access_log/body tracing/cache关闭。无需core/router全局替换；独立定向设计复核PASS后实际Nginx+Synapse证明public路由及原Matrix关键路由保持。
- [x] 独立领域/规格再质量安全实现审查；explicit source/tests/schema/runbook提交并释放工具文件。

#### Task 3B: Mobile vault migration, recovery and 72h ciphertext hydration

**Files:** 复用原Task3声明source，增加narrow matrix_recovery_vault.dart、core/session_store.dart专用account scoped journal；SDK key_manager及DB分页export/receipt/awaited import接口；auth/bootstrap若真实测试需要才声明。恢复UI改为“聊天记录同步”自动状态页；frontend catalog/renderer和registry对应同步。所有前述H1实际SDK/生命周期测试保留；与3A仅通过已冻结公开接口联动，不直接写域外表。

- [x] RED真实可用local session（包含原生备份锁定）自动归档→新设备全新隔离store登录→解密72h fixture，正常UI无手工key/SAS；本机旧SQLCipher保留并证明同账号来源。
- [x] 实现paged≤80session导出/保护receipt、按需≤64session恢复、实际Olm sessionId/sender验证/最早index merge、counted import与bounded ciphertext replay；不改SSSS/nativeuploaded/信任flag，A→B所有held边界不串号。
- [x] 真实标准backup payload无加密room_id/session_id也可互操作，外层标签不是密码证明；共用SDK解密在构造Event/索引写入前核验实际payload.room_id。追踪原discarded-index-write Future/runInRoot实际写，hold边界证明owner revoke/drain，不仅await周边replay。
- [x] 实现原H1独立80event页面/timestamp顺序锚/checkpoint CAS、terminal/state/empty/cycle、limitedsync/new-login gap；真实DB/key-write完整drain，deadline不冒充完成，有界working set。
- [x] Registry/HTML自动状态先于或伴随Flutter；高级旧backup迁移若材料不可用真实partial，服务器enrollment成功不等于全部消息恢复。
- [x] GREEN专项SDK/storage/account/crypto互操作与UI/frontend/contract门禁，独立领域/规格再安全实现审查；explicit source提交/报告及所有权释放。

### Task 4: Final validation and debug delivery
**Files:** root shared task/index/report/pubspec/AppConfig/paired version tests/build helpers only after candidate review; frontend/src/screens/messaging.js、frontend/src/catalog/screens.js、packages/ui-contracts/changliao-component-registry.json及聚焦HTML测试在Task3释放相应所有权后同步搜索进度/旧事件定位/真实失败文案状态。
- [x] Whole candidate independent review; full Flutter/analyze, relevant Python/frontend/native/platform checks, preflight verify.ps1 and record limits.
- [x] 搜索HTML示例和registry同步已有Flutter的稳定进度、旧消息定位与可重试错误状态；恢复页面的HTML/registry由Task3先交付，root不得同时编辑共享registry。合并后验证屏幕计数、token与行为一致。
- [x] Re-read live version/CI and emulator; freeze next version/source. Build conventional rebuilt stable-signed x86_64 debug; preserve-data install and launch smoke, same-source iOS native validation.
- [ ] Integrate/push reviewed changes preserving unrelated WIP, primary artifact/evidence, cleanup only own branch/worktree. Report physical Honor/K80 and new-device key acceptance limits separately.

R2追加执行：采纳server-custody-design-review.md §7–8已批TRACE协议边界+方法级互补map/安全TRACE元数据format/现有access条件分支，见托管ADR R2。仅API处理范围JSON/no-store不变；TRACE单独固定405非反射规范。真实日志sentinel泄漏P1必须关闭，普通方法日志及生产noticeerrorlevel保持，再转3A实现双审/3B。独立设计审查对真实notice的事实校正进行中，不改批准方法或保护边界。
