# 2026-09-17 ChatFlow Media Engine Phase 2 — 本地媒体索引 / 配额隔离 / 缓存生命周期

## 恢复入口

- 目标、用户授权来源及边界：用户直接指令（本会话）。建立可靠的本地媒体索引体系，消除大文件
  缓存命中时重复 SHA-256 计算，修复多账号共享磁盘配额，逐步统一 Chat / Moments / Avatar / File
  的本地缓存生命周期。
  **允许**：本地媒体缓存 / 本地媒体索引 / 本地 LRU+quota / 本地 reference 管理 / 本地 metadata /
  Chat·Moments·Avatar 缓存调用适配。
  **禁止**：Matrix 协议、event schema、E2EE/Megolm/Olm、服务端媒体上传 API、远端去重、服务端对象存储、
  消息格式、好友、群聊、登录、推送；不 `git pull`、不构建 APK/IPA、不真机、不部署、不 push。
  **不做 Phase 3**（服务端 SHA 去重、跨用户复用等只设计）。
- 关联计划/ADR：Phase 0 设计 [`docs/architecture/media-engine-v1.md`](../../architecture/media-engine-v1.md)；
  Phase 1 报告 [`docs/verification/2026-09-17-media-engine-v1-phase1.md`](../../verification/2026-09-17-media-engine-v1-phase1.md)；
  本阶段设计与落地说明 [`docs/architecture/media-engine-phase2-local-index.md`](../../architecture/media-engine-phase2-local-index.md)；
  现状审计 [`docs/verification/2026-09-17-media-architecture-audit.md`](../../verification/2026-09-17-media-architecture-audit.md)。
- 当前状态：**完成（本地实现 + 本地门禁通过）**；未构建 / 未真机 / 未部署 / 未 push。
- 负责人、工作树、文件所有权、源码commit：本地工作树 `D:\pythonProject\outsource\StarChat`，
  分支 `main`，基线 `81d9e612`（无新 commit，未提交）。文件所有权：`lib/features/matrix/media_cache.dart`、
  `media_index.dart`、`media_cache_metrics.dart`、`device_gallery_source.dart`、`matrix_e2ee_client.dart`、
  `room_page.dart`，对应 `test/features/matrix/*`，以及本任务文档。
- 最后更新时间（含时区）：2026-09-17（Asia/Hong_Kong）。
- 下一条具体操作、必要输入、阻断的验收ID：若继续 → Phase 3 候选（服务端查重需服务端配合，
  见设计文档 §12），或用户要求下的真机 I/O 剖析（`scripts/verify.ps1` 之后）。当前**无阻断项**。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | 500MB 对象第二次命中 **0 全文件 SHA-256**、0 邻居扫描 | `MediaIndex` 索引快路径 `_cachedViaIndex`（`media_cache.dart`） | `media_index_phase2_test.dart`「500MB 对象」：`hash_bytes_read` 首次 = size、第二次 = 0、`index_hits>0`；「不扫描邻居对象」 | 未发布 | 需真机 I/O 数据 |
| P0-1b | 索引命中仍必须做**廉价校验**，不得"信索引不验文件" | 命名空间/存在/精确大小 + mtime 锚点；< 1 MiB 回调完整校验 | 同文件：缺对象、截断、篡改、降级、无明文 ID 等用例 | 未发布 | — |
| 去重 | 同字节 → 1 对象 + 2 引用；命中同一物理文件 | 既有对象库 + 索引 | 「同字节两个房间」「Chat/Moments 共享字节」 | 未发布 | — |
| 变体 | q80/q70 字节不同 → **2 对象**，媒体族仅 metadata 关联 | `variant`/`family_id` 列 | 「q80/q70」「variant/family 落库」 | 未发布 | — |
| P1 | 账号配额隔离：A 淘汰不影响 B（除设备硬上限） | 两级配额 `MediaQuotaPolicy`（账号软 384MiB / 设备硬 1024MiB） | 「账号隔离」「设备硬上限」用例 | 未发布 | 数值待真机校准 |
| LRU | A/B/C 访问后淘汰最久未访问 | 账号内 LRU + 索引 `last_access_at` | 「LRU 淘汰最久未访问」 | 未发布 | — |
| LRU-batch | 滚动命中**不得**每次落盘（批量/去抖） | `MediaIndex._pendingTouches`（32 条 / 60s / 显式 flush） | 「批量 touch 不逐次落库」 | 未发布 | — |
| REF | 引用保护：有引用对象不被 GC 删除；引用数从 refs 重算 | `MediaGarbageCollector.collectGarbage` + refs 反查 | 「引用保护」「引用数可重算修复」 | 未发布 | — |
| GC-pin | pin/lease 期间 GC 与配额都不删 | `MediaCachePin` / `pinPath`，播放接线 `room_page._openVideoViewer` | 「pin 保护」「dryRun」「宽限期」 | 未发布 | — |
| CRASH | 崩溃双向恢复：有对象无索引 / 有索引无对象 | lazy 回填 / 失效索引回退 legacy | 「崩溃恢复与索引一致性」组 | 未发布 | — |
| CONC | 并发同 hash 写入 = 1 对象；并发读 + GC 不互毁 | `_storeFlights`/`_objectFlights` + `_atomicWrites` + pin | 「并发写入」「并发读 + GC」 | 未发布 | — |
| MIG | 旧缓存可读、不清应用数据、`video_first_frame_cache` 迁移 | 目录不搬迁（已账号隔离）+ 首帧并入对象库 + 惰性建索引 | `video_first_frame_cache_test.dart`（重写）、`device_gallery_source_test.dart` | 未发布 | — |
| METRICS | `cache_lookup_ms`/`index_lookup_ms`/`hash_bytes_read`/`disk_bytes_read`/`disk_bytes_written`/`eviction_ms`/`gc_ms` 且无 PII | `MediaCacheMetrics` | 「指标键」「无 PII」「计数器无条件累加」用例 | 未发布 | — |
| DEGRADE | 索引不可用 → 降级 legacy，不影响聊天 | `MediaIndex.degraded` + 30s 重试 | 「索引损坏（降级）」用例 | 未发布 | 生产依赖 SDK 的 sqlite3 `open` 覆盖 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Windows 工作站（仅本地测试） | Flutter 3.44.9 stable / Dart 3.12.2 | `81d9e612`（工作树未提交） | 无（不构建） | 无产物（按用户要求不构建） | 无（未部署） |

测试记录须包含：命令与真实退出码、源码/相关输入hash、依赖锁与工具版本、操作系统、CI run/job ID或本地日志、通过/失败/跳过数、未执行项和复用依据。用户原述设备/系统版本与实际观测值分开记录。

- 命令与退出码：
  - `flutter analyze lib/ test/features/matrix/media_index_phase2_test.dart` → **No issues found!（退出码 0）**
  - `flutter test test/features/matrix/{content_addressed_media,media_content_dedup,media_index_phase2,video_poster_pipeline}_test.dart` → **75 通过 / 0 失败（退出码 0）**
  - `flutter test --timeout 120s`（全量，第 3 次）→ **3120 通过 / 0 失败（退出码 0）**（前两次各 1 条既有易抖用例失败，见报告 §8.1）
  - `py -3.12 -m pytest tests/mobile -q` → **70 通过 / 0 失败**（294.99s）
  - `py -3.12 scripts/verify_ui_contract.py` → **PASS (31 components, 369 screens)**
  - `npm test`（`frontend/`）→ **209 通过 / 0 失败**
  - `pwsh -NoProfile -File scripts/verify.ps1` → **`Verification: PASS`（退出码 0）**
- 依赖锁与工具版本：`apps/mobile_flutter/pubspec.lock` 未改（**未新增任何依赖**；索引复用仓库既有
  `sqflite_common_ffi`）。
- 操作系统：Windows（工作站）。CI：本次未触发远端 CI（不 push）。
- 未执行项：真机测试、性能剖析、构建 APK/IPA、部署——均按用户要求不做。
- 复用依据：Phase 1 的全量门禁（3094/3094、`verify_ui_contract.py` PASS、frontend 209）在同一工作树、
  同一依赖锁上已完成；本次仅在媒体缓存链路与 4 个相关测试文件上做增量验证 + 全量回归复验。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 现状复核（读源码，确认真实调用图/哈希点/配额范围） | 2026-09-17 | 2026-09-17 | 主动 | — | 设计文档 §1 | 设计 |
| 设计（索引 schema、两级配额、GC/pin、迁移） | 2026-09-17 | 2026-09-17 | 主动 | — | 设计文档 §2–§9 | 实现 |
| 实现（`media_index` / `media_cache_metrics` / `media_cache` 改造 / 调用点适配） | 2026-09-17 | 2026-09-17 | 主动 | — | 见验证报告 §修改文件 | 测试 |
| 测试（新增 25 条 + 迁移 3 个既有文件） | 2026-09-17 | 2026-09-17 | 主动 + 返工 | — | 首轮 24 条通过后、完整性边界返工（见"返工记录"） | 门禁 |
| 门禁（analyze / 相关集 / 全量 / 契约 / frontend / pytest） | 2026-09-17 | 2026-09-17 | 工具等待（全量 Flutter 每次 ≈2.4 分钟） | 全量测试与文档撰写并行 | 验收台账 + 验证报告 | 交付 |

总墙钟：同一个工作日内完成；重复工作：**全量 `flutter test` 跑了三遍**——第 1、2 遍各出现 1 条与本改动
无关的既有"实时定时器 / 微任务调度"敏感用例在并行负载下抖动失败（`call_alerts_test.dart`、
`account_client_selection_test.dart`），两者单独重跑均通过，第 3 遍全量 **3120 通过 / 0 失败（退出码 0）**。
避免措施：这两个用例已在验证报告 §8.1 标注为"并行负载下易抖"，后续若再遇同类失败，先单跑确认再决定是否加固。

**返工记录（同一阶段内的自我纠正，重要）**：第一版索引快路径对所有尺寸一律"大小 + mtime"放行，
导致 3 条既有 Phase 1 完整性用例失败（`content_addressed_media_test` 2 条、
`video_poster_pipeline_test` 1 条）。根因不是测试过时，而是**设计缺陷**：毫秒粒度的
`mtime <= verified_at` 锚点在"校验同一毫秒内被同尺寸改写"时不可分辨，对小文件让
"同尺寸篡改必被发现"的既有语义退化。修正为**分级**：< 1 MiB 直接完整校验、≥ 1 MiB 才用
mtime 锚点，并补一条测试把这条边界固化（见验证报告 §5.2）。

## 交接与回退

- 已确认根因/已排除假设：
  - 已确认（源码级）：Phase 1 结束后 `_valid` 在每次磁盘命中整文件流式哈希 + `setLastModified`；
    配额枚举 `/chat-media` 整棵树（跨账号）；对象库目录本身**已经**是账号隔离（`v2/<sha256(account)>`）。
  - 已确认（测试级）：`MediaIndex` 索引命中路径确实 0 哈希字节（500MB 稀疏对象）。
  - 已排除：头像缓存"重复落盘"假设——头像只由 `flutter_cache_manager` 承载，没有第二份；
    把字节再交给 `MediaCache` 反而会变成两份落盘，故**不改**（设计文档 §7）。
  - 已排除：`SentVideoLocalRegistry` 指向压缩产物的改动——压缩产物被
    `prepareLocalChatVideo` 的 `finally` 删除，强改需动 outgoing 产物所有权，**只报告**。
- 待办及验收失败项：无阻断项。可选后续：真机 I/O 剖析（校准 384/1024 MiB 配额）、Phase 3 清单。
- 已发布与仅候选的区别：**全部仅为本地候选**（工作树未提交、未构建、未发布）。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不涉及生产。回退 = 丢弃工作树改动
  （索引库为新增文件 `{support}/chatflow_media_index_v1.db`，删除该文件即回到 legacy 行为；
  对象库与 `refs/*.ref` 未被迁移或重命名，旧缓存始终可读）。
- 运行中CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：`git status`（工作树是否仍为 `81d9e612` 未提交状态）、
  `apps/mobile_flutter/pubspec.lock` 是否被改动（不应改动）、
  以及 `MediaCache._cheapPathMinBytes` 是否仍为 1 MiB（这是完整性语义的关键常量）。
