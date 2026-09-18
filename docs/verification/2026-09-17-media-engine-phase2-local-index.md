# ChatFlow Media Engine Phase 2 报告 — 本地媒体索引 / 配额隔离 / 缓存生命周期

- 日期：2026-09-17（Asia/Hong_Kong）
- 仓库：`SuperJJ2333/StarChat`（本地工作树，基线 `81d9e612`，分支 `main`，**工作树未提交**）
- 范围：**Phase 2 = 本地媒体索引 + 账号配额隔离 + 本地引用/GC + 本地缓存生命周期统一**
- 相关文档：设计 [Phase 2 本地媒体索引](../../architecture/media-engine-phase2-local-index.md)、
  任务记录 [2026-09-17-media-engine-phase2-local-index.md](../workflow/tasks/2026-09-17-media-engine-phase2-local-index.md)、
  Phase 1 报告 [2026-09-17-media-engine-v1-phase1.md](2026-09-17-media-engine-v1-phase1.md)、
  现状审计 [2026-09-17-media-architecture-audit.md](2026-09-17-media-architecture-audit.md)
- 未做：`git pull`、构建 APK/IPA、真机测试、部署、`git push`（用户明确本次不需要）
- 遵守的禁止事项：未改 Matrix 协议 / event schema / E2EE(Megolm·Olm) / 服务端媒体上传 API /
  远端去重 / 服务端对象存储 / 消息格式 / 好友 / 群聊 / 登录 / 推送；未实现 Phase 3（只设计）；
  **未删除任何既有缓存**；未清空应用数据（旧缓存原样可读）；未新增第三方依赖。

---

## 1. 本阶段要解决的三件事（用户原述）

> 建立可靠的本地媒体索引体系，消除大文件缓存命中时重复 SHA-256 计算，修复多账号共享磁盘配额的问题，
> 并逐步统一 Chat / Moments / Avatar / File 的本地缓存生命周期。

拆成可验收目标：**P0-1**（大文件命中不再重算 SHA-256）、**P0-1b**（不得"索引命中即盲信"）、
**P1**（账号级配额隔离）、**索引体系**（可靠、可崩溃恢复、可降级）、**GC/引用/pin**、
**生命周期统一**（首帧缓存并入、Moments 自动受益、Avatar 明确不动并给出理由）。

---

## 2. Before（Phase 1 结束时的真实行为）

| 位置 | 行为 | 问题 |
| --- | --- | --- |
| `MediaCache._valid(file)` | 每次磁盘命中：读 `.len` → 校验文件名摘要 → **整文件流式 SHA-256** → `setLastModified(now)` | **P0-1**：500MB 视频"命中"要重读+哈希 500MB 才起播，且每次命中一次写盘 |
| `MediaCache._enforceDiskQuota` | 递归枚举 `{docs}/chat-media` **整棵树**（含所有账号），超 512MiB 硬上限后按 mtime 删到 384MiB | **P1**：账号 A 的视频能淘汰账号 B 的离线媒体；单账号无上限 |
| `removeReference` | 只删 `refs/*.ref`，对象保留 | 无反向索引 → 无法安全回收对象，只能靠配额 LRU 兜底 |
| 相册视频首帧 | `{docs}/video_first_frame_cache/` | 独立目录、**无配额、无账号、无原子写** |
| `refs/<sha256([roomId,eventId])>.ref` → 对象名 | **已经是**"逻辑引用 → 对象"的持久映射 | 没有反向索引（对象 → 引用数） |

目录层面 `chat-media/v2/<sha256(accountId)>` **已经**账号隔离 → 本阶段**不做机械目录迁移**。

---

## 3. After（本阶段实现）

```
                       MediaCache（唯一对象库 / 配额 / 引用 / GC）
                        │                 │                 │
        Chat（E2EE 解密后）    Moments（HTTP 下载后）   相册首帧（本机抽帧）
                        └────────┬────────┴────────┬────────┘
                        MediaIndex（SQLite，按账号列隔离）   refs/*.ref（真相源）
                                 │                              │
                          廉价命中快路径              MediaGarbageCollector（refs 重算引用数）
```

1. **`MediaIndex`（新增，`media_index.dart`）**：`(account_namespace, reference_key)` 主键，
   `object_hash / object_name / variant / family_id / size_bytes / mime_type / width / height /
   duration_ms / created_at / last_access_at / verified_at`。**索引是加速层，不是真相源**：
   删掉索引靠对象 + refs 可完全恢复。
2. **廉价命中**：≥ 1 MiB 的对象命中只做"命名空间 + 存在 + 精确大小 + mtime 锚点"（0 字节读取）；
   < 1 MiB 仍然完整校验（成本可忽略，保住 Phase 1 的"同尺寸篡改必被发现"语义）。
3. **两级配额**：账号内软配额 384 MiB（沿用既有值）+ 设备硬上限 1024 MiB（集中常量）。
4. **LRU 批量 touch**：命中只写内存 pending（32 条 / 60s / 显式 flush），滚动不产生逐次磁盘写。
5. **引用计数 + GC**：引用数**从 `refs/*.ref` 重算**（不依赖计数器，崩溃不漂移）；
   `collectGarbage` 跳过 pin / 在途写 / 宽限期内的对象。
6. **pin/lease**：视频全屏播放在解析出播放文件后 pin，路由返回时释放。
7. **首帧缓存并入对象库**（`roomId='device-gallery'`），删除独立无配额目录的使用。
8. **失败降级**：索引打不开/查询抛错 → 纯 legacy 行为，30s 后重试；聊天永不因索引不可用而不可用。

---

## 4. 修改文件

### 4.1 新增

| 文件 | 内容 |
| --- | --- |
| `apps/mobile_flutter/lib/features/matrix/media_index.dart` | `MediaVariantKind` / `MediaIndexEntry` / `MediaIndex`（SQLite schema v1、热 LRU 512、pending touch 批处理、`lookup`/`lookupObject`/`put`/`touch*`/`flush`/`invalidate`/`forgetObjects`/`clearAccount`/`entriesForAccount`、降级 + 30s 重试、`shared` 单例 + `overrideShared`/`resetForTest`） |
| `apps/mobile_flutter/lib/features/matrix/media_cache_metrics.dart` | `MediaCacheMetrics`：`cache_lookup_ms` / `index_lookup_ms` / `hash_bytes_read` / `disk_bytes_read` / `disk_bytes_written` / `eviction_ms` / `evictions` / `gc_ms` / `gc_runs` / `index_hits` / `index_misses` / `index_writes` / `touch_flushes` 等，`snapshot()` / `debugLine()` / `reset()`；**计数器无条件累加**，仅耗时受 profile 开关控制 |
| `apps/mobile_flutter/test/features/matrix/media_index_phase2_test.dart` | **25 条** Phase 2 验收测试（见 §7） |
| `docs/architecture/media-engine-phase2-local-index.md` | 设计 + 落地说明（Before/After、schema、廉价校验分级、LRU/配额、GC/pin、账号隔离、崩溃恢复、迁移、安全、指标、Phase 3 清单、不变量） |
| `docs/verification/2026-09-17-media-engine-phase2-local-index.md` | 本报告 |
| `docs/workflow/tasks/2026-09-17-media-engine-phase2-local-index.md` | 任务记录 |

### 4.2 修改

| 文件 | 变更 |
| --- | --- |
| `lib/features/matrix/media_cache.dart` | 索引快路径 `_cachedViaIndex` + 分级完整性校验（`_cheapPathMinBytes = 1 MiB`）；`_store`/`_storeObject` 走索引 + `_knownObjectValid`（小对象强制完整校验）；两级配额 `MediaQuotaPolicy`（账号软 / 设备硬）+ `_accountObjects`/`_indexedLastAccess`/`_evictOldest`；`collectGarbage` + `MediaGcReport`；`pinPath`/`unpinPath`/`isPinned`/`MediaCachePin`；`touchLocalObject`；`_discardCorruptObject`；`removeReference` 同时失效索引行；`clearAccount` 清索引行 + 估计值 + pin；`MediaCacheKey` 新增非身份字段 `variant`/`familyId`；`loadMediaWithCache` 摘要不符时**修复**（删对象 + 失效索引 + 重新解密落盘）而不是抛异常 |
| `lib/features/matrix/matrix_e2ee_client.dart` | `mediaCacheKey()` 传 `variant`（thumbnail/body）与 `familyId`（正文摘要） |
| `lib/features/matrix/device_gallery_source.dart` | 首帧缓存改为对象库（`videoFirstFrameRoomId='device-gallery'`、`variant=poster`、`mimeType=image/jpeg`），删除 `path_provider` 依赖与 `cacheDir` 形参 |
| `lib/features/matrix/room_page.dart` | `_openVideoViewer` 在解析出播放文件后 `MediaCache.pinPath`，`finally` 释放（播放中不被配额/GC 删除） |
| `test/features/matrix/media_content_dedup_test.dart` | 损坏用例同时推进 mtime（与新锚点语义一致） |
| `test/features/matrix/video_first_frame_cache_test.dart` | **重写**：断言走对象库、不再创建 `video_first_frame_cache` 目录、空对象重新抽帧；新增 `_Paths` PathProvider 桩 |
| `test/features/matrix/device_gallery_source_test.dart` | 适配 `cacheDir` 移除（`_VffPaths` 桩 + `probeCachedObject` 判空） |

**未改动**：`MediaEnvelope`/加密、`MediaMemoryCache`/`sharedMediaMemoryBudget`、`VideoPosterSessionCache`、
`VideoPosterDiskStore`、`RoomImagePreviewCache`、Moments CacheManager、
Avatar `RetentionImageCacheManager`、`SentVideoLocalRegistry`（只审计报告）、`pubspec.*`（零新依赖）。

---

## 5. 关键设计决策与取舍

### 5.1 索引命中为什么不是"信任索引"

强制保留的廉价校验：**账号命名空间**（对象路径必须落在当前账号根内，否则索引行不可信）、
**文件存在**、**精确大小**、**`verified_at > 0`**。任一不符 → 立即失效该索引行 → 回退 legacy
（`refs` → 完整校验 → 回填索引）。索引只替代**重复的整文件哈希**，不替代"文件是否真的在那儿、大小对不对"。

校验失败一律**降级为缓存未命中**（可重新下载/解密），绝不出现"索引指向幽灵文件导致媒体永久打不开"。

### 5.2 分级完整性校验（本阶段最重要的一次自我纠正）

第一版实现对**所有尺寸**使用"大小 + mtime"锚点，结果 3 条既有 Phase 1 用例失败：

| 失败用例 | 断言 |
| --- | --- |
| `content_addressed_media_test.dart`「content video playback renames the single verified blob and repairs corruption」 | 同尺寸篡改后必须重新下载（`downloads == 1`）并返回正确字节 |
| `content_addressed_media_test.dart`「cross room content hits zero download and rejects same length corruption」 | 同尺寸篡改必须被拒绝 |
| `video_poster_pipeline_test.dart`「探测不替代完整性校验：cached() 仍拒绝被篡改的对象」 | `cached()` 对被篡改对象必须返回 `null`（`probeCachedObject` 仍返回非空） |

根因是**设计缺陷**，不是测试过时：`stat.modified` 与 `verified_at` 都是毫秒粒度，
"校验之后同一毫秒内被同尺寸改写"在锚点上不可分辨；对小文件放行等于让"同尺寸篡改必被发现"退化。

修正（现已落地并有测试）：

| 对象尺寸 | 命中成本 | 同尺寸篡改 |
| --- | --- | --- |
| < 1 MiB | 整文件流式 SHA-256（亚毫秒） | **必被发现**（Phase 1 语义不变） |
| ≥ 1 MiB | 一次 `stat`（大小 + mtime），0 字节读取 | mtime 晚于 `verified_at` 即被发现 |

为什么锚点对**大**对象成立：已索引对象的 mtime **只在写入时设定**（LRU 走索引列；
`MediaIndex.flush()` 的 `setLastModified` 只作用于**未索引**对象），而 `_indexVerified`
在对象成功落盘之后记录 `verified_at = now`，因此正常对象恒有 `mtime <= verified_at`。
残留风险（毫秒窗口、本地攻击者伪造 mtime）在设计文档 §4.2 明确记录，并由
`loadMediaWithCache` 的内容摘要复核 + 自愈修复（§4.3）兜底。

### 5.3 配额数值为什么是 384 MiB / 1024 MiB

若设备硬上限仍是 Phase 1 的 512 MiB，则两个账号各自写到 384 MiB 就会立刻互相驱逐——**等于没修 P1**。
1 GiB 允许 2–3 个活跃账号各自留在自己的软配额内，同时仍把最坏磁盘占用限制在可控范围。
两个数值集中在 `MediaQuotaPolicy`，测试可用 `useQuotaForTest` 覆盖。

### 5.4 Avatar 为什么"不统一"（明确决定，不是遗漏）

头像当前只由 `flutter_cache_manager`（30 天 / 500 对象 / 键 `avatar:<userId>:<version>`）承载：
同一个 Matrix 用户 = 同一个头像文件，**不存在重复下载或重复落盘**。若把最终字节再交给 `MediaCache`，
结果是"同一头像两份落盘"，与去重目标相反；要真正统一必须把 CacheManager 的 HTTP 新鲜度
（etag / validTill）一起搬进对象库 —— 那会改变头像刷新语义（**本次禁止**），故列为 Phase 3（设计文档 §12.3）。

### 5.5 Moments 为什么无需改网络层

Moments 已经通过 `MediaCache.store/cached('moments', cacheKey, accountId:)` 使用**同一个对象库**，
因此自动获得索引、廉价命中、账号配额与 GC；HTTP 层（CacheManager）与其 TTL 保持独立不变。

---

## 6. 索引 schema 与数据安全

```sql
CREATE TABLE IF NOT EXISTS media_index (
  account_namespace TEXT NOT NULL,   -- sha256(accountId)
  reference_key     TEXT NOT NULL,   -- sha256(jsonEncode([roomId, eventId]))
  object_hash       TEXT NOT NULL,   -- sha256(明文对象字节)
  object_name       TEXT NOT NULL,
  variant TEXT NOT NULL DEFAULT 'unknown',
  family_id TEXT, size_bytes INTEGER NOT NULL,
  mime_type TEXT, width INTEGER, height INTEGER, duration_ms INTEGER,
  created_at INTEGER NOT NULL, last_access_at INTEGER NOT NULL,
  verified_at INTEGER NOT NULL, schema_version INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (account_namespace, reference_key)
);
```

- 库文件：`{ApplicationSupportDirectory}/chatflow_media_index_v1.db`（**懒打开**：构造时不建库，
  首次查询才落盘 → 不引入启动扫描）。
- **不含明文**：没有 userId / roomId / eventId / 文件名 / token / Matrix 密钥 / 媒体内容；
  账号与引用都是 sha256 摘要。测试 `媒体索引数据库不含明文房间/事件/账号 ID` 直接扫描 db 文件字节断言。
- 指标 `debugLine()` 只输出数字。

---

## 7. 新增测试（`test/features/matrix/media_index_phase2_test.dart`，25 条）

| 组 | 用例（断言要点） |
| --- | --- |
| P0-1 大文件命中不重哈希 | 500MB 稀疏对象：首次 `hash_bytes_read == size`（一次完整校验 + 回填），第二/三次命中 **0 增长**且 `index_hits > 0`；`contentSha256` 寻址同样命中 |
| P0-1 无启动全量扫描 | 命中某对象不触碰同账号 64MB **未索引**邻居对象（`hash_bytes_read == 0`） |
| 分级完整性 | **小对象（4 KiB）默认仍整文件校验**（`hash_bytes_read == size`），且**同尺寸篡改 → `cached()` 返回 null** |
| 去重与变体 | 同字节两个房间 → 1 对象 + 2 引用且路径相同；q80/q70 → **2 对象**（不误合并）+ `family_id` 只作 metadata 关联；`variant` 落库 |
| 跨域共享 | Chat 与 Moments 同字节 → 1 对象 2 引用 |
| 账号隔离（P1） | 极小配额下 A 的淘汰不影响 B；设备硬上限触发跨账号兜底 |
| LRU | A/B/C 命中后访问 A → 淘汰 B（最久未访问）；**批量 touch**：60s/32 条内不落库、`flush()` 后一次落库 |
| 引用与 GC | 有引用对象不被回收；引用数从 `refs/*.ref` 重算（人为删 ref 后即可回收）；宽限期内不回收；`dryRun` 不删除；**pin 期间 GC/配额都不删** |
| 崩溃恢复 | 对象在、索引缺 → 首次完整校验并**回填**；索引在、对象缺 → 失效索引行 + 回退（不留幽灵路径）；对象被截断 → 失效；索引构造失败（`_ThrowingFactory`）→ **降级**且不影响 legacy |
| 并发 | 并发同 hash 写入只产生 **1 个对象**；并发读 + GC 不互毁（pin 保护） |
| 迁移 | 旧缓存（无索引行）可读；不清应用数据；`clearAccount` 只清该账号的索引行 |
| 指标与隐私 | 指标键齐全；db 文件内**无明文**房间/事件/账号 ID；计数器在非 profile 构建下也累加；索引**懒建库** |

既有测试迁移（3 个文件）与"零回归"策略：`video_first_frame_cache_test.dart` 重写为对象库语义，
`device_gallery_source_test.dart` 适配 `cacheDir` 移除，`media_content_dedup_test.dart` 的损坏用例
同步推进 mtime。其他既有缓存测试（`video_card_interaction`、`video_gif_cells`、
`video_poster_session_cache`、`video_poster_disk_store`、`video_poster_extractor`（含 `0ms` 语义）、
`fourth_cache_regression`、`video_viewer_cache`、`media_visibility`）**未改且全绿**。

---

## 8. 门禁结果

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 静态分析 | `flutter analyze lib/` / `flutter analyze lib/ test/features/matrix/media_index_phase2_test.dart` | **No issues found!**（退出码 0） |
| Phase 2 相关集 | `flutter test test/features/matrix/{content_addressed_media,media_content_dedup,media_index_phase2,video_poster_pipeline}_test.dart` | **75 通过 / 0 失败**（退出码 0） |
| **全量** | `flutter test --timeout 120s` | **3120 通过 / 0 失败（退出码 0）** |
| UI 契约 | `py -3.12 scripts/verify_ui_contract.py` | `UI contract drift: PASS (31 components, 369 screens)` |
| Flutter 边界（仓库门禁子集） | `py -3.12 -m pytest tests/mobile -q` | **70 通过 / 0 失败**（294.99s） |
| HTML demo | `npm test`（`frontend/`） | **209 通过 / 0 失败**（2250ms） |
| 仓库整体门禁 | `pwsh -NoProfile -File scripts/verify.ps1` | **`Verification: PASS`（退出码 0）** |

工具链：Flutter 3.44.9 (stable) / Dart 3.12.2（Windows 工作站）。

### 8.1 全量回归的抖动说明（如实记录）

`flutter test --timeout 120s` 共跑了三次：

| 次 | 结果 | 失败用例 |
| --- | --- | --- |
| 1 | 3119 通过 / **1 失败** | `features/matrix/call_alerts_test.dart`「alerts ring immediately then loop on the interval」（真实定时器 + 铃声循环） |
| 2 | 3119 通过 / **1 失败** | `features/matrix/account_client_selection_test.dart`「owner atomically accepts nine deferred gallery videos within one preparation budget」（`Future.delayed(Duration.zero)` 调度断言） |
| 3 | **3120 通过 / 0 失败（退出码 0）** | — |

两次失败是**两个不同的、与本改动无关的既有用例**，都属于"实时定时器 / 微任务调度顺序"这一类在
并行负载下易抖的断言；两者**单独重跑均通过**（`call_alerts_test.dart` → 3 通过；
`account_client_selection_test.dart` → 22 通过），且第三次全量干净。
本改动未向这些路径加入任何定时器或调度（`MediaIndex` 的 flush 只在媒体缓存命中时检查 60s 去抖，
没有周期性 Timer）。结论：既有测试的并行负载抖动，非 Phase 2 回归。

---

## 9. 剩余风险

| # | 风险 | 影响 | 现状/缓解 |
| --- | --- | --- | --- |
| R1 | 大对象（≥ 1 MiB）廉价路径的毫秒级"同毫秒改写"窗口 | 理论窗口内篡改不被 mtime 锚点发现 | 重写 ≥ 1 MiB 文件耗时远超 1 ms，实践不可达；最终由 `loadMediaWithCache` 摘要复核兜底并**自愈修复**（设计文档 §4.2/§4.3） |
| R2 | 本地攻击者篡改后 `setLastModified` 回填 mtime | 绕过锚点 | 本阶段明确把索引定位为**完整性加速器**，不是对抗本地沙箱写权限的安全边界；摘要复核仍可发现并提供修复 |
| R3 | 生产环境索引依赖 Matrix SDK 的 sqlite3 `open` 覆盖（`SQfLiteEncryptionHelper.ffiInit`） | 若 SDK 初始化早于/独立于索引打开，索引可能降级 | 已实现 30s 自动重试 + 完全 legacy 降级；不影响聊天可用性。需真机确认（本阶段不做真机） |
| R4 | 配额数值（384 MiB / 1024 MiB）未经真机磁盘剖析校准 | 低端机可能偏大/偏小 | 集中常量 + `useQuotaForTest`；列入 Phase 3（真机 I/O 剖析） |
| R5 | `MediaMemoryCache` 在内存 put 时仍会对字节做一次 sha256 | 与 P0-1 同类成本（内存侧） | 不改：它校验的是"键内嵌哈希 == 内容"的内存安全约束；需要新的"信任来源"证明，列入 Phase 3 |
| R6 | `SentVideoLocalRegistry` 仍登记相册**原片**而非压缩产物 | 自己发的 4K 视频抽帧更慢/内存峰值更高 | Phase 1 已审计，强改需动 outgoing 产物所有权；本阶段**只报告** |
| R7 | 未构建 / 未真机 / 未部署 / 未 push | 无安装包、无真机手感数据 | 用户明确本次不需要；验收由用户执行 |
| R8 | 首帧缓存迁移后账号命名空间为设备共享（`roomId='device-gallery'`，`accountId` 缺省空） | 多账号下首帧对象共享 | **有意为之**：素材来自用户本机相册（非 E2EE 媒体），共享不泄露跨账号信息；需要时可传 `accountId` 隔离 |

---

## 10. 验收对照（用户给定标准）

| 用户要求 | 结果 | 证据 |
| --- | --- | --- |
| 500MB 第二次命中 = 0 全文件 SHA | ✅ | 500MB 稀疏对象用例：`hash_bytes_read` 第二次 0 增长、`index_hits > 0` |
| 同字节去重：1 对象 + 2 引用 | ✅ | 同字节两房间用例 + Chat/Moments 共享用例 |
| q80/q70 = 2 对象（不误合并，族信息仅 metadata） | ✅ | `variant`/`family_id` 用例，断言 2 个物理对象 |
| 账号隔离：A 淘汰不影响 B（除设备硬上限） | ✅ | 极小配额用例 + 设备硬上限用例 |
| LRU：A/B/C + 访问 A → 淘汰 B | ✅ | LRU 用例 |
| 引用保护 | ✅ | 有引用不被回收；引用数从 refs 重算；删 ref 后可回收 |
| 崩溃恢复（有对象无索引 / 有索引无对象） | ✅ | 崩溃恢复组 4 条（含索引构造失败降级） |
| 并发同 hash 写入 = 1 对象 | ✅ | 并发写入用例 |
| 并发读 + GC | ✅ | 并发读 + GC 用例（pin 保护下不互毁） |
| Moments + Chat 共享字节 = 1 对象 2 引用 | ✅ | 跨域共享用例 |
| 索引命中必须做廉价校验（不盲信） | ✅ | 存在/大小/命名空间/verified 校验 + 失效回退用例；小对象额外完整校验用例 |
| 批量/去抖 LRU（滚动不落盘） | ✅ | 批量 touch 用例（60s/32 条/flush） |
| pin/lease 保护正在使用的文件 | ✅ | pin 用例 + 生产接线（视频播放） |
| `video_first_frame_cache` 迁移 | ✅ | 重写的首帧测试断言对象库 + 目录不再创建 |
| 指标齐全且无 PII | ✅ | 指标键用例 + db 无明文用例 + 计数器无条件累加 |
| 惰性/增量索引（无启动扫描） | ✅ | 懒建库用例 + 无邻居扫描用例 |
| 迁移兼容（旧缓存可读、不清应用数据） | ✅ | 旧对象回填用例；目录未搬迁 |
| 失败降级 | ✅ | 索引损坏降级用例 |
| Phase 3 只设计不实现 | ✅ | 设计文档 §12 清单，代码中无服务端/远端去重改动 |
| 未改 Matrix 协议 / E2EE / 事件格式 / 服务端 | ✅ | 未触碰 `MediaEnvelope`、上传 API、事件字段、登录/好友/群聊 |

---

## 11. UI / demo 说明

本次是**非视觉**的缓存与索引行为变更（消息气泡、视频卡片外观、占位底、时长角标均未改动），
聊天视频卡片从未纳入 HTML demo（`packages/ui-contracts/changliao-component-registry.json` 与
`frontend/src/components` 中无视频组件），因此无 demo / registry 改动。
`Figma 已退役：本次变更不涉及 HTML demo（无对应 demo 组件）。`
