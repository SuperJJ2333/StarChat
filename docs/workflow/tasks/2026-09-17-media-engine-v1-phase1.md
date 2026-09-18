# 2026-09-17 Media Engine Phase 0（设计）+ Phase 1（视频加载优化）

## 恢复入口

- 目标、用户授权来源及边界：
  用户一条消息给定两阶段任务：**Phase 0** = 建立 ChatFlow 下一代媒体基础设施（Media Engine）方向，
  「只设计，不大规模重构」，产出 `docs/architecture/media-engine-v1.md`（含当前链路 / 目标架构 /
  `MediaObject`/`MediaVariant`/`MediaReference` 数据模型 / 明确「不做远端去重」）；
  **Phase 1** = 实际编码解决当前最影响体验的视频加载问题：禁止「为封面下载完整视频」、
  增加 `VideoPosterPipeline`、增加可见性门控（可见区域 ±5 行）、poster 生成优先级
  （服务端 → 本地缓存 → 本地抽帧 → 占位）、poster 缓存 LRU + 多账号隔离、`SentVideoLocalRegistry`
  审计（风险大则只报告）、6 项指定测试、脱敏性能日志、复用既有缓存实现。
  边界（用户明示）：不改 Matrix 协议/E2EE/事件格式/登录/好友/群聊业务/朋友圈业务；不删除现有缓存；
  不用清空缓存解决问题；不用 `Future.delayed` 掩盖加载问题；不大规模替换现有媒体架构；不做远端去重。
  不需要真机测试、不需要构建 IPA/APK、不需要部署、不需要 git pull。
- 关联计划/ADR：`docs/architecture/media-engine-v1.md`（本次设计）；媒体现状审计
  `docs/verification/2026-09-17-media-architecture-audit.md`；ADR-0060（内容寻址 + 确定性加密信封）保持不变。
- 当前状态：**完成（本地，未构建/未真机/未部署/未 push）**
- 负责人、工作树、文件所有权、源码 commit：主工作树 `D:\pythonProject\outsource\StarChat`，分支 `main`，
  基线 commit **`81d9e612`**（本批次未提交）；本任务独占 Phase 1 的 7 个源码文件 + 2 个测试文件 + 2 个文档。
- 最后更新时间（含时区）：2026-09-17（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收 ID：无阻断。下一步建议（非本次授权）：
  ① 真机验收「无封面视频进入聊天」的占位/生成体验与滚动流畅度；
  ② 按设计文档 §6 顺序推进 Phase 2（门面委派 → 参数集中 → 变体族谱 → 引用计数）。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | Media Engine v1 设计文档（链路/架构/数据模型/差距/迁移/不变量） | 只设计，无行为改动 | `docs/architecture/media-engine-v1.md` | 不适用 | 参数归一与远端去重属 Phase 2+，需产品/后端配合 |
| P1-1 | 视频无 poster 时**不会**下载完整视频 | `VideoPosterPipeline` 无下载入口；`_loadVideoPoster` 删除旧的全量下载路径 | `video_poster_pipeline_test.dart` Test 3（500MB：`downloadBytes=0`、`extractions=0`）+ 源码防回归用例 | 不适用 | 未真机；本地抽帧耗时未实测 |
| P1-2 | 视频列表首屏不触发全部视频处理 | 卡片可见性门控（±5 行）+ `mediaLoadScheduler(isVideo: true)` | 同上 Test 4（100 条：首屏 <20、滚动后累计 <40）+ 缓冲边界用例 | 不适用 | 未真机；有效上界是 `min(构建窗口, ±5 行)`（R1） |
| P1-3 | 增加 `VideoPosterPipeline`（内存 → 磁盘 → 生成任务） | `video_poster_pipeline.dart`（内存/会话磁盘复用 `VideoPosterSessionCache`） | Test 1（内存命中）、Test 5（磁盘命中） | 不适用 | — |
| P1-4 | poster 生成优先级：服务端 → 本地缓存 → 本地抽帧 → 占位 | `_generate` 顺序实现 + `VideoPosterSource` 枚举 | Test 1/2/3/5 逐层断言 | 不适用 | 无本地文件时只能占位（R2） |
| P1-5 | poster 缓存 LRU | 内存 `VideoPosterSessionCache`（32MiB/256 LRU）+ 磁盘 `MediaCache`（384/512MiB mtime LRU） | Test 5 + 既有 session cache/disk store 测试全绿 | 不适用 | 磁盘配额仍是全设备共享（审计 P1-1，Phase 2） |
| P1-6 | 多账号缓存隔离 | 复用 `chat-media/v2/<sha256(accountId)>` + 虚拟 ref `<eventId>#video-poster-v1` | Test 6（真实 `MediaCache`：A 写 B 读不到；流水线键含账号） | 不适用 | — |
| P1-7 | 脱敏性能日志（id 哈希/source/cache_hit/generate_ms/decode_ms/download_bytes） | `video_poster_diagnostics.dart`（白名单 + 加盐哈希 + 失败安全） | 诊断用例（字段白名单、无原始 ID/盐、日志抛异常不影响加载） | 不适用 | 真机 logcat 采集由用户执行 |
| P1-8 | `SentVideoLocalRegistry` 审计 | **只报告**（按要求，风险大不强改） | 设计文档 §4.5 + 本记录「已确认根因」 | 不适用 | 需 Phase 2 决策（产物所有权/引用计数） |
| P1-9 | 不破坏既有媒体缓存/发送/E2EE/朋友圈 | 未删除任何缓存层；未触碰发送、E2EE、Moments 业务 | 要求范围 1718 通过、UI 250 通过、全量 3094 通过 | 不适用 | — |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 无（本次不构建、不部署） | — | 工作树基于 `81d9e612` | — | — | — |

测试记录：

- `flutter analyze`（`apps/mobile_flutter`）→ `No issues found!`（退出码 0）。工具链 Flutter 3.44.9 / Dart 3.12.2。
- `flutter test test/features/matrix/video_poster_pipeline_test.dart test/ui/chat/video_poster_visibility_test.dart`
  → **24 通过 / 0 失败**。
- `flutter test test/features/matrix test/features/moments test/performance --timeout 120s`
  → **1718 通过 / 0 失败**。
- `flutter test test/ui/chat test/ui/media_visibility_test.dart test/ui/video_playback_arbiter_test.dart test/ui/video_playback_lease_coordinator_test.dart test/ui/video_viewer_lifecycle_test.dart`
  → **250 通过 / 0 失败**。
- `flutter test --timeout 120s`（全量）→ **3094 通过 / 0 失败（退出码 0）**，日志见
  `<TEMP>\starchat-full-test.txt`（本地；本记录不落仓库临时文件）。
  - 首次全量运行（`job pwsh-58`，在 Test 4 修正前启动）为 3093 通过 / 1 失败，
    失败即当时尚未修正的 `video_poster_visibility_test.dart` Test 4（断言 `loads.length` 未增长，
    原因是列表元素复用导致 `loads.clear()` 后不再重载）；修正后用 `jumpTo` 重写该用例，复跑全绿。
- 上一批次（媒体审计/引用消息/相册编辑）的门禁在同一工作树保持通过：
  `python scripts/verify_ui_contract.py` → `PASS (31 components, 369 screens)`；`npm test`（`frontend/`）→ 209 通过。
- 仓库门禁的 Flutter 相关子集：`py -3.12 -m pytest tests/mobile -q` → **70 通过 / 0 失败**（含
  `test_flutter_boundaries.py`、`test_ui_component_registry.py`）。
- 收尾加固（自查发现，已纳入门禁）：① 流水线回调改为携带 `mediaId`（原共享字段在并发解析时会串号）；
  ② `cache_hit` 语义补上「本机持久封面缓存命中」；③ `VideoPosterPipeline.forget(mediaId)` 供撤回清理
  冷却与归属；④ `_findLocalVideoFile` 改用 `controller.findMessage`（原遍历 `allMessages`，大房间退化）；
  ⑤ 持久封面命中后刷新 mtime（LRU 语义一致）。
- 未执行：APK/IPA 构建、真机安装、服务端部署。
- 证据身份：源码 `81d9e612` + 本记录撰写时的工作树 diff；依赖锁 `apps/mobile_flutter/pubspec.lock` 未改动；
  操作系统 Windows（工作站）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 视频/媒体链路审计 | 2026-09-17 | 2026-09-17 | 主动 | A | 定位 3 处 `_loadVideoPoster` 调用点、`VideoPosterSessionCache`/`DiskStore`/`extractor`、`MediaCache.cached/probe`、卡片 `initState` 触发点 | 设计 |
| Phase 0 设计文档 | 2026-09-17 | 2026-09-17 | 主动 | B | `docs/architecture/media-engine-v1.md` | 实现 |
| Phase 1 实现 | 2026-09-17 | 2026-09-17 | 主动 + 4 次返工 | B | 返工原因：① 闭包共享可变 `_serverPosterRequest` 传媒体 ID（并发串号）→ 改为回调带 `mediaId` 形参；② `cache_hit` 未覆盖「本机持久封面缓存命中」→ 语义修正为 `source ∈ {memory,disk}`；③ 可见性测试未意识到「子项未被构建时门控无从生效」→ 用 `scrollCacheExtent` 放大构建窗口以单独验证 ±5 行窗口；④ Test 4 列表元素复用导致 `loads.clear()` 失效 → 改为 `jumpTo` + 累计断言 | 门禁 |
| 门禁与文档 | 2026-09-17 | 2026-09-17 | 工具 | C | analyze 0 issue；全量 3094 通过；本报告与 current-state 更新 | 完成 |

- 总墙钟：未知（跨会话执行，未逐步记录时间戳；不按文件修改时间编造）。
- 重复工作：首次全量运行因未完成的 Test 4 失败，属**真失败**而非重复门禁；修正后复跑一次。
- 未知时段：`scripts/verify.ps1` 本次未运行（见「交接与回退」）。

## 交接与回退

- 已确认根因/已排除假设：
  - P0-1 根因确认：`_loadVideoPoster` 在「事件无可用缩略图」时用 `resolveCachedVideoFile`（整段视频下载+解密）
    换取一帧封面；触发点是无门控的 `VideoMessageCard.initState`。已用「流水线无下载入口」结构性修复。
  - `SentVideoLocalRegistry` **确认**登记的是 `asset.originFile`（相册原片）而非压缩产物；
    压缩产物在 `prepareLocalChatVideo` 的 `finally` 中被主动删除 → 强改需动 outgoing 产物所有权（高风险）→ 只报告。
  - 已排除「用清缓存/重下载」「用延时掩盖」「catch 全吞」等伪修复：失败一律降级为可重试占位并写诊断日志。
- 待办及验收失败项：
  - 真机验收（用户执行）：无封面视频的占位→生成→更新体验、100 条视频滚动流畅度、抽帧耗时。
  - Phase 2+：设计文档 §6 的 8 项（远端去重需后端配合）。
  - 审计 P0-1/P0-3、P1-1/P1-4/P1-5 仍开放。
- 已发布与仅候选的区别：**无发布、无候选包**；仅本地工作树改动。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。
- 运行中 CI/命令：无（全量测试已结束；未创建隧道；未占用端口）。
- 下次恢复先检查的事实：`git rev-parse --short HEAD`（应为 `81d9e612` 之上）、
  `docs/verification/2026-09-17-media-engine-v1-phase1.md` 的「修改文件」表、
  以及 `docs/architecture/media-engine-v1.md` §6 的迁移顺序。
- 本次未运行 `scripts/verify.ps1`（上一批次在同一工作树运行结果为 `Verification: PASS`；本次改动为
  Flutter 客户端 + 文档，未触碰后端/迁移/OpenAPI/Compose，故按工作流的「不重复做」原则不重复运行整仓门禁）。
