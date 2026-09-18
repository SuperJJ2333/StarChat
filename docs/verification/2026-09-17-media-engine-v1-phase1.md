# ChatFlow Media Engine Phase 0-1 Report

- 日期：2026-09-17（Asia/Hong_Kong）
- 仓库：`SuperJJ2333/StarChat`（本地工作树，基线 `81d9e612`，分支 `main`）
- 范围：Phase 0 = Media Engine 架构设计（只设计）；Phase 1 = 视频媒体加载优化（实际编码）
- 相关文档：[`docs/architecture/media-engine-v1.md`](../architecture/media-engine-v1.md)（设计）、
  [`docs/verification/2026-09-17-media-architecture-audit.md`](2026-09-17-media-architecture-audit.md)（现状审计）
- 未做：构建 IPA/APK、真机测试、服务端部署、git push（用户明确本次不需要）
- 遵守的禁止事项：未改 Matrix 协议 / E2EE / 事件格式 / 登录 / 好友 / 群聊业务 / 朋友圈业务；
  未删除任何现有缓存；未用「清空缓存」解决问题；未用 `Future.delayed` 掩盖加载；未大规模替换媒体架构；
  未做远端去重（未改服务端存储/上传协议/加密协议）

---

## 1. 当前媒体架构

（完整链路与证据行号见 [媒体架构审计](2026-09-17-media-architecture-audit.md)；设计文档 §1 亦复述。）

### 聊天图片
选择 → 压缩（`DeviceGallerySource._readImage`：1280×1280 q80）→ 生成缩略图
（`buildChatImageThumbnail`：≤800px/≤100KB）→ 本地对象库（`objects/<sha256>` + `refs/*.ref`）→
确定性加密信封（`MediaEnvelope`，密钥/nonce 由 sha256(明文) 派生）→ SDK `sendFileEvent`
（正文 + 缩略图各一个 `mxc://`）→ 事件（`chatflow_media` 扩展）→ 下载 + 解密 →
缓存（内存 LRU 48 条/64MiB → 磁盘 384/512MiB mtime LRU → 房间加密预览）→ 展示（缩略图优先，`ResizeImage(720)`）。

### 聊天视频
选择 → 转码（`transcodeForChat`：640×480 1.2Mbps，超限再 aggressive）→ 生成 poster
（`extractVideoPoster`，多时间点 + 近黑帧判定）→ 上传（正文 mp4 + poster 缩略图）→ 展示
（`VideoMessageCard`）→ 播放（`resolveCachedVideoFile` → `VideoPlayerController.file`）。

### 朋友圈媒体
Moment → 业务 API（`/moments/media/uploads/{id}/content`）→ 客户端缓存 →
展示。**与聊天媒体部分共享**：解密字节对象库（`MediaCache.store('moments', ...)` 与
`MediaCache.cached('moments', ...)`）与内存预算共享；HTTP 层（`flutter_cache_manager`）、
缓存键/TTL、账号清理注册点各自独立；演绎版参数不同（≤1080px/≤500KB vs 聊天 1280/q80 vs 缩略图 800/100KB），
因此同源文件在不同域产生**不同字节**，内容寻址也命中不了。

---

## 2. Media Engine v1 设计

（完整设计见 [`docs/architecture/media-engine-v1.md`](../architecture/media-engine-v1.md)。）

```
                 MediaService
                      │
     ┌────────────────┼────────────────┐
     │                │                │
   Chat          Moments           Avatar
     │
  Group/File
```

- **核心模型**：`MediaObject`（`media_id`/`sha256`/`mime_type`/`size`/`width`/`height`/`duration`/
  `created_at`/`storage_path`，其中 `media_id` 由内容派生）；
  `MediaVariant`（图片：`original`/`thumbnail_small`/`thumbnail_medium`/`preview`；
  视频：`poster`/`preview_video`/`compressed_video`/`original_video`，各自又是一个 `MediaObject` 并以 `variant_of` 归族）；
  `MediaReference`（`media_id` + `business_type` + `business_id` + `created_at`，实现引用计数与引用式回收）。
- **复用而非重写**：`MediaObjectStore`←`MediaCache`、`MediaMemoryBudget`、`MediaLoadScheduler`、
  `MediaEnvelope`（**保持不变**）、两个 `MediaGateway`（Matrix / Business）。
- **本阶段不做**：远端去重、上传协议/E2EE 改动、演绎版参数归一（会改变发送字节）、
  删除任何现有缓存、独立 `cache/<account_hash>/video_poster/` 目录树（与「不复制新缓存系统」冲突）。
- **迁移顺序**（Phase 2+）：门面委派 → `MediaCodecPolicy` 参数集中 → `MediaVariant` 族谱 →
  引用计数与配额解耦（账号内配额）→ 删除入口收敛 → 视频渐进播放 → （需服务端）远端查重 → P0 收尾。

---

## 3. 视频加载旧流程（问题 P0-1）

```
VideoMessageCard.initState（无任何可见性门控：进入列表即全量触发）
  ↓
posterLoader() = RoomPage._loadVideoPoster(messageId)
  ↓
事件有可用缩略图?
  ├─ 有 → timeline.loadThumbnail()（≤480px 小图）→ 显示 ✅
  └─ 无 → resolveCachedVideoFile()   ← 下载 + 解密**整段视频**到磁盘
             ↓
          extractVideoPoster(本地文件)  ← 解码抽帧
             ↓
          显示
```

证据（改动前）：`room_page.dart` `_loadVideoPoster` 的 trusted 分支（`trusted.thumbnailSha256 == null`
时直接 `resolveCachedVideoFile` + `extractVideoPoster`）与 legacy 分支（同一个 loader 内先 `loadThumbnail`
再回退整段视频下载）；触发点 `wechat_video_message.dart` 的 `initState`。

后果（用户报告）：首屏慢、流量浪费（500MB 视频为了封面下满 500MB）、小米/红米明显卡顿、
大视频严重；列表首屏会为尽量多的视频触发处理。

---

## 4. 视频加载新流程（Phase 1 实现）

```
VideoMessageCard
  └─ MediaVisibility(warmExtent: ±5 行 ≈ 790pt)
        └─ 窗口从 hidden → warm/visible 时才调用 posterLoader
             ↓
VideoPosterPipeline.resolve(mediaId)          ← 没有任何下载入口
  ├─ ① 会话内存 LRU（VideoPosterSessionCache：LRU + 在途合并）      → cache_hit
  ├─ ② 会话磁盘（VideoPosterDiskStore，AES-GCM 临时目录，原样保留）  → cache_hit
  ├─ ③ 本机持久封面缓存（MediaCache 对象库：账号命名空间 + 内容寻址 + 配额 LRU）→ cache_hit
  ├─ ④ 服务端 poster：事件自带加密缩略图附件（≤480px，**不是视频**）
  ├─ ⑤ 本地抽帧：**仅当本地已存在视频文件**（自己发的 / 已离线缓存 / 播放过）
  │      → 写入 ③（「生成后更新缓存」）→ 卡片刷新显示
  └─ ⑥ 占位图（videocam 占位底）
```

关键设计点：

| 要求 | 实现 |
| --- | --- |
| **禁止为了封面下载完整视频** | `VideoPosterPipeline` 的构造参数里**没有**任何下载回调；`findLocalVideoFile` 只做本地存在性探测（`SentVideoLocalRegistry` + `MediaCache.probeCachedObject`，后者不重算哈希）。有源码级防回归测试 |
| **poster 优先级** | 服务端 poster（事件缩略图）→ 本地持久封面缓存 → 本地抽帧 → 占位（内存/会话磁盘作为更快的同内容层前置） |
| **可见性门控** | `MediaVisibility` 新增 `warmExtent` + 三态 `onWindowChanged`；卡片只在「可见区域 ±5 行」内请求封面；路由被覆盖/退后台/TickerMode 关闭时一律不请求 |
| **首屏不全量处理** | 门控 + `mediaLoadScheduler(isVideo: true → 全局并发 1)` 双重约束；抽帧失败有冷却（20s），`forceGenerate` 用于播放后补生成 |
| **失败可见** | 失败降级为占位（可重试）+ 诊断日志（`source=placeholder`），绝不无限 loading |
| **播放后补生成** | `_openVideoViewer` 返回后，若该消息封面仍缺失 → 提升 `posterRevision` → 卡片重新解析（此时视频已落盘，可本地抽帧成功） |

---

## 5. 修改文件

### Phase 1（视频加载优化，本任务新增/修改）

| 文件 | 变更 |
| --- | --- |
| `apps/mobile_flutter/lib/features/matrix/video_poster_pipeline.dart` | **新增**：`VideoPosterPipeline` + `VideoPosterSource` + `VideoPosterOutcome`（优先级链、单飞复用、冷却、`forceGenerate`、`downloadBytes ≡ 0`） |
| `apps/mobile_flutter/lib/features/matrix/video_poster_diagnostics.dart` | **新增**：`VideoPosterDiagnostics`（白名单字段 + 加盐哈希 + 失败安全日志） |
| `apps/mobile_flutter/lib/ui/chat/media_visibility.dart` | 新增 `warmExtent`（±buffer）与三态 `MediaVisibilityWindow`/`onWindowChanged`；默认 0 时行为与原实现逐字一致 |
| `apps/mobile_flutter/lib/ui/chat/wechat_video_message.dart` | `VideoMessageCard` 封面加载改为**可见性门控**（`kVideoPosterWarmRows = 5`）；新增 `posterRevision` 触发补生成 |
| `apps/mobile_flutter/lib/features/matrix/room_page.dart` | `_loadVideoPoster` 改为走流水线（删除「为封面下载整段视频」路径）；新增服务端 poster/持久缓存/本地文件探测回调；播放后补生成 |
| `apps/mobile_flutter/lib/features/matrix/media_cache.dart` | 新增 `probeCachedObject`（廉价存在性探测，不重算哈希；完整性读取仍走 `cached`） |
| `apps/mobile_flutter/lib/features/matrix/video_poster_extractor.dart` | 新增可选 `onFrameDecoded` 诊断回调（`decode_ms` 来源）；**默认行为不变**（含 `0ms` 语义，避免影响发送侧 poster） |
| `apps/mobile_flutter/test/features/matrix/video_poster_pipeline_test.dart` | **新增**：19 条 |
| `apps/mobile_flutter/test/ui/chat/video_poster_visibility_test.dart` | **新增**：5 条 |

### Phase 0（设计文档）

| 文件 | 变更 |
| --- | --- |
| `docs/architecture/media-engine-v1.md` | **新增**：Media Engine v1 设计（链路、目标架构、数据模型、差距、迁移路径、不变量） |
| `docs/verification/2026-09-17-media-engine-v1-phase1.md` | **新增**：本报告 |

### 同批次上一轮（媒体审计 / 引用消息 / 相册编辑）留存的改动

`reply_message_resolution.dart`、`message_timeline_cache.dart`、`quote_preview_card.dart`、
`image_crop_geometry.dart`、`wechat_image_editor.dart`、`image_picker_page.dart`、
`device_gallery_source.dart`、`matrix_e2ee_client.dart`、`matrix_room_timeline_adapter.dart`、
`room_timeline_controller.dart`、`frontend/src/components/image-editor.js`、
`frontend/src/styles/components.css`、`packages/ui-contracts/changliao-component-registry.json`、相关测试与文档
（明细见 [上一轮报告](2026-09-17-media-quote-image-editor.md)）。

---

## 6. 新增缓存策略

**没有新建第二套缓存系统**：全部复用现有件。

| 层 | 承载 | 淘汰 | 账号隔离 | 生命周期 |
| --- | --- | --- | --- | --- |
| 内存（新接入） | `VideoPosterSessionCache`（32MiB / 256 条 LRU + 在途合并） | LRU（仅内存条目） | 键含 `accountId` | 房间实例存活期 |
| 会话磁盘（沿用） | `VideoPosterDiskStore`（AES-GCM，进程临时目录） | 会话销毁整体删除（设计如此，不按 LRU） | 进程临时目录 | 房间实例存活期 |
| 持久磁盘（新接入同一账号命名空间） | `MediaCache` 对象库（`chat-media/v2/<sha256(accountId)>/{objects,refs}`） | **既有** 384MiB 软 / 512MiB 硬，mtime LRU | `chat-media/v2/<sha256(accountId)>` | 账号清理（`clearLocalChatData`）或配额淘汰 |
| 服务端 | 事件缩略图附件（≤480px） | 服务端策略 | 房间成员资格 | 服务端 |

磁盘缓存的元数据映射（用户要求的 `poster_id / size / last_access / media_id`）：

| 要求 | 承载 |
| --- | --- |
| `poster_id` | 对象文件名 = `sha256(封面字节)` |
| `size` | `<sha256>.len` |
| `last_access` | 对象 mtime（命中即 `setLastModified(now)`，参与 LRU 排序） |
| `media_id` | `refs/<sha256([roomId, <eventId>#video-poster-v1])>.ref` |

**账号隔离（验收项）**：写入/读取都带 `accountId` → 路径前缀 `chat-media/v2/<sha256(accountId)>`；
测试用真实 `MediaCache` 验证「账号 A 写的封面，账号 B 读不到」（`probeCachedObject` 返回 null）。

**未删除任何现有缓存**：`VideoPosterDiskStore`、`VideoPosterSessionCache`、`RoomImagePreviewCache`、
`MediaCache`、`Moments` 的 CacheManager 全部保留，语义不变。

---

## 7. 新增测试

### 7.1 `test/features/matrix/video_poster_pipeline_test.dart`（19 条）

| 验收 | 用例 | 断言要点 |
| --- | --- | --- |
| **Test 1** 有 poster → 立即显示 | 服务端 poster 命中即返回 | `source=server`、`downloadBytes=0`、`localProbes=0`、`extractions=0`；第二次 `source=memory`、`cache_hit=true`、`serverCalls=1` |
| | 并发解析同一媒体 | 单飞：`extractions=1` |
| **Test 2** 无 poster → 占位 → 后台生成 → 更新 | 本地已有视频 → 抽帧生成 | `source=local_frame`、`diskWrites=1`、缓存内容等于生成字节、`decodeMs≥3` |
| | 抽帧失败 | `source=placeholder`（可重试）、`diskWrites=0`、`extractionFailures=1`、`downloadBytes=0` |
| | 失败冷却 / 播放后补生成 | 冷却期内 `extractions=1`；`forceGenerate` 后 `=2` |
| **Test 3** 大视频不下载 | 500MB 远端 + 无本地文件 | 占位、`downloadBytes=0`、`extractions=0`、只做 1 次本地探测 |
| | 500MB 本地 + 有 poster | `source=server`、`extractions=0`（不解码大文件） |
| | **结构防回归** | 流水线源码不含 `resolveCachedVideoFile`/`loadAttachment`/`downloadMediaContent`/`downloadAndDecryptAttachment`/`_downloadMedia` |
| **Test 5** 缓存命中 | 第一次抽帧、第二次新流水线 | 第二次 `source=disk`、`cache_hit=true`、`extractions=0`、`localProbes=0` |
| **Test 6** 账号隔离 | 真实 `MediaCache` | A 写 → A 可读、**B 读不到**；同账号同字节跨房间共用同一物理对象 |
| | 流水线键含账号 | B 账号解析同一 eventId → 占位（不命中 A 的缓存） |
| 诊断 | 白名单字段 | 日志含且仅含 `id/source/cache_hit/generate_ms/decode_ms/download_bytes`；不含原始 ID/盐；`lastRecord` 键序固定 |
| | 日志抛异常 | 不影响封面加载（`source=server` 仍返回） |
| 健壮性 | 服务端抛错 | 降级到本地抽帧，不崩溃 |
| | 写盘失败 | 不阻断本次显示 |
| | 空媒体 ID | 直接占位，不触碰任何来源 |
| | 键形状 | `账号\|房间\|媒体\|版本\|规格`（`chat-poster-v2`） |
| 探测 | `probeCachedObject` | 命中已落盘对象、不校验哈希；`cached()` 仍拒绝被篡改对象（职责分离） |

### 7.2 `test/ui/chat/video_poster_visibility_test.dart`（5 条）

| 用例 | 断言要点 |
| --- | --- |
| **Test 1（UI）** | 有 poster：进入（可见）后 `posterLoader` 只调用 1 次、封面渲染、播放按钮与时长角标在位 |
| **Test 2（UI）** | 无 poster：生成完成前显示 **占位底**（无 Image），完成后更新为封面 |
| 窗口外不加载 | 卡片已构建但位于视口下方 3000pt（远超 ±5 行）→ **不加载**；`jumpTo` 进入窗口后才加载 |
| **前瞻缓冲边界** | 视口下方 400pt（±5 行 ≈790pt 内）→ 加载；下方 1200pt（缓冲外）→ 不加载 |
| **Test 4** 100 个视频 + 快速滚动 | 把 `scrollCacheExtent` 放大到可构建全部 100 行（证明过滤来自门控而非懒构建）：首屏只处理 <20 行、第 20 行不处理；滚到底后累计仍 <40 行（`v99` 在真正可见后处理） |

> 注：`lib/features/media/` 与 `lib/ui/gallery/` 在仓库中不存在（用户列出的搜索路径），
> 视频/媒体实现集中在 `lib/features/matrix/` 与 `lib/ui/chat/`；已在审计文档中说明。

### 7.3 既有测试的兼容性

- `video_card_interaction_test.dart`（4 条）：仍全绿。**语义被保留**——`posterIdentity` 变化时重载、
  同一 identity 重建不重载；「首帧不请求」改为等可见性窗口帧后回调（`pumpWidget` 会跑完该回调）。
- `video_gif_cells_test.dart`（9 条，含「移出/移入 10 次只加载 1 次」）、
  `video_poster_session_cache_test.dart`、`video_poster_disk_store_test.dart`、
  `video_poster_extractor_test.dart`（含 `0ms` 既有语义）、`fourth_cache_regression_test.dart`、
  `video_viewer_cache_test.dart`、`media_visibility_test.dart`：全部未改且全绿。

---

## 8. flutter analyze

```
$ cd apps/mobile_flutter && flutter analyze
Analyzing mobile_flutter...
No issues found! (ran in 14.2s)
```

工具链：Flutter 3.44.9 (stable) / Dart 3.12.2（Windows 工作站）。
（过程中修掉的问题：`ListView.cacheExtent` 已废弃 → 测试改用
`scrollCacheExtent: ScrollCacheExtent.pixels(...)`；流水线未使用导入/初始化形参告警。）

---

## 9. flutter test

| 范围 | 命令 | 结果 |
| --- | --- | --- |
| Phase 1 新增 | `flutter test test/features/matrix/video_poster_pipeline_test.dart test/ui/chat/video_poster_visibility_test.dart` | **24 通过 / 0 失败** |
| 要求范围 | `flutter test test/features/matrix test/features/moments test/performance --timeout 120s` | **1718 通过 / 0 失败** |
| 视频/媒体 UI | `flutter test test/ui/chat test/ui/media_visibility_test.dart test/ui/video_playback_*_test.dart test/ui/video_viewer_lifecycle_test.dart` | **250 通过 / 0 失败** |
| **全量** | `flutter test --timeout 120s` | **3094 通过 / 0 失败（退出码 0）** |
| Flutter 边界（仓库门禁子集） | `py -3.12 -m pytest tests/mobile -q` | **70 通过 / 0 失败**（含 `test_flutter_boundaries.py`、`test_ui_component_registry.py`） |
| UI 契约 | `python scripts/verify_ui_contract.py` | `UI contract drift: PASS (31 components, 369 screens)` |
| HTML demo | `npm test`（`frontend/`） | **209 通过 / 0 失败** |

上一轮（媒体审计 / 引用消息 / 相册编辑）在同一工作树上留下的门禁同样保持通过
（`verify_ui_contract.py` PASS 31/369、`npm test` 209 通过，见上一轮报告）。

### 9.1 实现收尾时补做的加固（自查发现，均已纳入上面的门禁）

| 加固 | 原因 |
| --- | --- |
| 流水线回调改为携带 `mediaId` 形参 | 原设计用房间页共享字段传递当前媒体 ID，两个视频并发解析会串号（真实缺陷） |
| `cache_hit` 语义修正 | 原实现漏掉「本机持久封面缓存命中」→ 现在 `source ∈ {memory, disk}` 才算 cache hit |
| `VideoPosterPipeline.forget(mediaId)` | 撤回/删除时清理来源归属与抽帧冷却（否则冷却会阻塞同 ID 新内容、诊断残留） |
| `_findLocalVideoFile` 改用 `controller.findMessage` | 原写法遍历 `allMessages`，大房间（5 万事件）会退化成全量扫描 |
| `_readCachedVideoPoster` 命中后刷新 mtime | 探测路径不刷 mtime，会让封面对象比「刚访问过」更早被配额淘汰 |

---

## 10. Remaining Risks

| # | 风险 | 影响 | 现状/缓解 |
| --- | --- | --- | --- |
| R1 | **可见性门控的有效上界是 `min(Flutter 构建窗口, ±5 行窗口)`** | 房间列表默认 `cacheExtent≈250pt`，因此「built 但离屏」的行本来就不多；门控的主要收益是「路由被覆盖/退后台不请求」+「确实离屏的行不处理」 | 已在设计文档写明；Test 4 用超大 `scrollCacheExtent` 单独证明 ±5 行窗口本身的过滤能力 |
| R2 | 无 poster 且本地无视频时**无法生成封面**（只能等播放/缓存后） | 旧消息的封面仍可能是占位底，直到该视频被播放或离线缓存 | 这是「禁止为封面下载整段视频」的必然结果；已实现播放后补生成（`posterRevision`）；Phase 2 可考虑发送端保证 poster 必达/可重试上传 |
| R3 | 本地抽帧会解码**相册原片**（`SentVideoLocalRegistry` 登记原片） | 自己发的 4K 视频抽帧更慢、内存峰值更高 | 见设计文档 §4.5：登记压缩产物需改动转码产物所有权（高风险，本次只报告）；抽帧受 `mediaLoadScheduler` 全局并发 1 + 冷却约束 |
| R4 | `probeCachedObject` 与 `cached` 的职责差异 | 使用探测路径得到的文件句柄未做完整性校验（用于抽帧，失败即占位） | 注释与测试明确：完整性与播放仍走 `cached`/`preparePlaybackFile`；损坏文件只导致占位，不会播放坏文件 |
| R5 | 抽帧冷却（20s）可能让「刚播放完」的补生成被推迟 | 用户看到封面更新的时间可能滞后 | 播放路径显式使用 `forceGenerate` 绕过冷却 |
| R6 | 诊断日志默认开启（`debugPrint`） | 大量视频滚动时日志量增加（每媒体一行） | 只含白名单字段 + 12 位加盐哈希；可用 `enabled: false` 关闭 |
| R7 | 真机未验证 | 手感（抽帧耗时、低端机滚动帧率、占位视觉）无实测数据 | 用户明确本次不做真机测试；验收由用户执行 |
| R8 | 审计 P0-1（磁盘命中全量重算 SHA-256）、P0-3（跨域三份上传）、P1-1（全设备配额）、P1-4（朋友圈九宫格全尺寸解码）、P1-5（首帧缓存无配额） | 仍在 | 本阶段范围外；已在审计文档与设计文档 §6 列为 Phase 2+ 输入。注意 P0-1 与本任务相关：本任务通过 `probeCachedObject` **避开**了封面路径上的重哈希，但播放路径仍存在 |
| R9 | 未构建/未部署/未 push | 产物仍为本地工作树 | 用户明确本次不需要 |

---

## 11. 验收对照（用户给定标准）

| 验收标准 | 结果 | 证据 |
| --- | --- | --- |
| 视频无 poster 时不会下载完整视频 | ✅ | 流水线**无下载入口**（源码防回归测试）+ 500MB 用例 `downloadBytes=0`/`extractions=0` |
| 视频列表首屏不触发全部视频处理 | ✅ | Test 4（100 条 + 超大 cacheExtent）：首屏 <20 行；滚动后累计 <40 行 |
| poster 生成有可见性门控 | ✅ | `MediaVisibility(warmExtent: ±5 行)` + 卡片窗口门控；窗口外/缓冲外不加载用例 |
| poster 缓存支持 LRU | ✅ | 内存 `VideoPosterSessionCache` LRU；磁盘 `MediaCache` mtime LRU（384/512MiB） |
| 多账号缓存隔离 | ✅ | `chat-media/v2/<sha256(accountId)>` + 真实 MediaCache 账号隔离用例 |
| 不破坏已有媒体缓存 | ✅ | 未删除任何缓存层；相关既有测试（含缓存回归类）全绿；`VideoPosterDiskStore`/`RoomImagePreviewCache` 原样保留 |
| 不影响消息发送 | ✅ | 未触碰发送/转码/上传路径；`prepareLocalChatVideo`、outgoing job、E2EE 未改 |
| 不影响 E2EE | ✅ | 未改 `MediaEnvelope`/加密格式；封面走既有加密附件与本地句柄 |
| 不影响朋友圈 | ✅ | 未触碰 Moments 业务与缓存注册点；Moments 测试全绿 |
| analyze 通过 | ✅ | `No issues found!` |
| test 通过 | ✅ | 全量 **3094 通过 / 0 失败** |

HTML demo / 契约：本次为**非视觉**的加载行为变更（视频卡片外观、占位底、时长角标均未改动），
且聊天视频卡片从未纳入 HTML demo（registry 与 `frontend/src/components` 中无视频组件），
因此无 demo/registry 改动；`verify_ui_contract.py` 保持 PASS。
`Figma 已退役：本次变更不涉及 HTML demo（无对应 demo 组件）。`
