# 2026-09-17 媒体架构审计 + 引用消息跨距离修复 + 相册大图编辑/裁剪重做

## 恢复入口

- 目标、用户授权来源及边界：
  用户一条消息给出三个方向：① 媒体缓存/加载/存储架构**审计**（先不重构，输出报告 + 方案 + P0/P1/P2）；
  ② 修复引用消息「距离过远永久显示原消息加载中」；③ 相册查看大图增加「编辑」并把裁剪交互做到**微信级**
  （默认全图裁剪框、四边四角拖动、遮罩/边框/控制点、缩放平移、比例、还原、应用裁剪）。
  边界（用户明示的禁止事项）：不重构 Matrix 协议层、不改 E2EE 加密逻辑、不改消息事件格式（除非必要）、
  不改登录/好友/群聊协议、不删除已有缓存机制、不用「清空缓存/重新下载」解决问题、不用 `Future.delayed`
  掩盖加载问题、不用 `catch` 全吞异常。不需要真机测试、不需要构建 IPA/APK、不需要部署、不需要从 GitHub pull。
- 关联计划/ADR：无新计划文件；媒体侧沿用 ADR-0060（内容寻址 + 确定性加密信封）不动；UI 交付按
  `docs/ui-development-html-demo-workflow.md` / `ui-demo-delivery` 技能（Figma 已退役，仅更新 HTML demo）。
- 当前状态：**完成（本地，未构建/未真机/未部署/未 push）**
- 负责人、工作树、文件所有权、源码 commit：主工作树 `D:\pythonProject\outsource\StarChat`，分支 `main`，
  基线 commit **`81d9e612`**（改动前工作树干净）；本任务独占第 5 节列出的文件。
- 最后更新时间（含时区）：2026-09-17（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收 ID：无阻断。下一步建议（非本次授权）：把审计 P0-1/P0-2/P0-3 拆成
  独立任务；真机验收相册「编辑 → 裁剪 → 还原 → 应用裁剪 → 发送」全链路。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 媒体架构审计报告（图片链路/视频链路/缓存层级/去重/P0-P1-P2） | 无行为改动，仅只读走查 | `docs/verification/2026-09-17-media-architecture-audit.md`（330 行，含未确认附录） | 不适用 | 审计中「服务端是否按内容哈希去重」「SDK 上传前是否按摘要复用 mxc://」标记**未确认** |
| Q1 | 引用最近消息：直接显示，不产生解析请求 | `QuotePreviewCard` + `ReplyMessageResolver` | `reply_message_resolution_test.dart` Test 1（`lookups` 为空） | 不适用 | 未真机 |
| Q2 | 引用 1000 条以前的消息：仍可加载，且不是按页翻 1000 条 | `RoomMessageLookupSource` + SDK `Timeline.getEventById`（本地加密库 → 服务器单事件查询 + 解密） | 同上 Test 2（`lookups == 1`、`historyCalls == 0`、结果并入 `findMessage`） | 不适用 | 未真机；服务端 403/404 判定未联调 |
| Q3 | 重启/重进会话后引用仍可显示 | SDK 本地加密库优先读取 + `MessageTimelineCache`（仅内存、按账号+房间） | 同上 Test 3 + `MessageTimelineCache` 隔离/淘汰用例 | 不适用 | 「写入 Room local database」**有意未做**（SDK 无安全 upsert，见报告 §3.3 / R1） |
| Q4 | 网络断开：显示「原消息加载失败，点击重试」，绝不永久 loading | 3 秒超时 + 五态状态机 + 点击重试（单飞） | 同上 Test 4（超时→失败→重试成功）+ 默认超时断言 | 不适用 | 未真机弱网 |
| G1 | 相册大图出现「编辑」，顺序 编辑 → 选择 → 闪照，点击可进入编辑器 | `_GalleryPreviewPage` + `_GalleryPreviewAction` | `gallery_preview_edit_test.dart` 用例 1（含 x 坐标递增断言） | 不适用 | 未真机 |
| G2 | 编辑 → 发送：产生**新的**媒体对象，原图不被覆盖 | 编辑器 `onSend` + `editedGalleryPhoto(bytes)` + 选择器返回契约 | 同上用例 2（`id` 以 `edited-` 开头、`image/png`、原 `GalleryPhoto` 字节不变） | 不适用 | 未真机；会替换原本的多选批次（R6） |
| G3 | 取消编辑：原图不变化、无任何输出 | 编辑器取消只出栈 | 同上用例 3 + `image_crop_editor_test.dart` Test6 | 不适用 | 未真机 |
| C1 | 打开裁剪：裁剪框默认覆盖完整图片 | `ImageCropGeometry` + 画布 contain 映射 | `image_crop_editor_test.dart` Test1（与 `viewBox` 四边一致、面积 ≥95%） | 不适用 | 未真机 |
| C2 | 拖动四角：裁剪区域变化 | `handleAt`/`resize` | 同上 Test2 + 几何单测「拖角改两条边」 | 不适用 | 未真机 |
| C3 | 拖动边框：区域变化，另一轴不动 | 同上 | 同上 Test3 + 几何单测「拖边只改一条边」 | 不适用 | 未真机 |
| C4 | 点击还原：恢复原始图片状态 / 默认裁剪框 / 默认缩放 / 默认旋转 | `_restore()` | 同上 Test4（rotation 0、crop 全幅、marks 清空、viewScale 1） | 不适用 | 语义为**全量还原**（R4，建议真机确认） |
| C5 | 点击应用裁剪：生成新图片，原图保持 | `toImageRect` → 新文档 → 导出 PNG | 同上 Test5（导出尺寸 ≈ 裁剪像素、source 字节与副本全等） | 不适用 | 未真机 |
| C6 | 裁剪框有半透明遮罩 / 明显边框 / 四角控制点 / 拖动提示 | `_paintCropOverlay` | 同上「像素级遮罩/边框/控制点」与「拖动中高亮」用例 | 不适用 | 未真机 |
| C7 | 支持放大/缩小/移动图片、保持比例、自由裁剪、旋转 | `_cropStart/_cropUpdate` + 比例预设 + `rotatedDocument` | 同上「比例」「旋转」「缩放与移动」用例 + 几何比例单测 | 不适用 | 手势竞争手感未真机验证（R5） |
| C8 | 还原 / 应用裁剪：高度、圆角、间距一致，应用裁剪有填充背景与高亮 | `ImageEditorActionButton` | 同上「按钮一致性」用例（尺寸相等、圆角一致、间距 12、填充色不同） | 不适用 | 未真机 |
| U1 | UI 契约与 HTML 演示同步 | `frontend/src/components/image-editor.js`、`components.css`、registry | `python scripts/verify_ui_contract.py` PASS(31/369)；`npm test` 209 通过 | 不适用 | Figma 已退役，仅 HTML demo |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 无（本次不构建、不部署） | — | 工作树基于 `81d9e612` | — | — | — |

测试记录：

- `flutter analyze`（`apps/mobile_flutter`）→ `No issues found!`（退出码 0）。工具链 Flutter 3.44.9 / Dart 3.12.2。
- `flutter test test/features/matrix/reply_message_resolution_test.dart test/ui/chat/image_crop_geometry_test.dart test/ui/chat/image_crop_editor_test.dart test/features/matrix/gallery_preview_edit_test.dart`
  → **48 通过 / 0 失败**（退出码 0）。
- `flutter test test/features/matrix test/performance test/ui/message_bubble_anchor_test.dart`（引用链回归）
  → **1576 通过 / 0 失败**（退出码 0，见 `job pwsh-55`）。
- `flutter test --timeout 120s`（全量）→ **3070 通过 / 0 失败**（退出码 0，日志由 `job pwsh-56` 输出）。
- `python scripts/verify_ui_contract.py` → `UI contract drift: PASS (31 components, 369 screens)`。
- `npm test`（`frontend/`）→ **209 通过 / 0 失败**（含 `image-editor-demo.test.mjs`、`source-contract.test.mjs` 的
  "无硬编码颜色/无内联样式"扫描）。
- 未执行：APK/IPA 构建、真机安装、服务端部署。
- `pwsh -NoProfile -File scripts/verify.ps1` → **`Verification: PASS`（退出码 0）**（仓库策略/部署策略/模板单测/
  渲染冒烟/infra/getui/matrix-bot/Business API+Worker/Flutter boundary/UI 契约/API import/AST parse/
  Alembic head + offline upgrade/OpenAPI/Compose render 全部通过；后台作业 `pwsh-57`）。
- 证据身份：源码 `81d9e612` + 本文档 commit 时的工作树 diff（11 个已跟踪文件 `+1445/−335`，8 个新增文件）；
  依赖锁 `apps/mobile_flutter/pubspec.lock` 与 `frontend/package.json` 未改动；操作系统 Windows（工作站）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 恢复与侦察 | 2026-09-17 | 2026-09-17 | 主动 | 与媒体审计并行 | 读取 AGENTS/工作流/current-state + 定位媒体/引用/相册代码 | 写审计 + 改代码 |
| 媒体审计（子代理只读） | 2026-09-17 | 2026-09-17 | 工具（后台子代理） | A | `2026-09-17-media-architecture-audit.md` 330 行；本任务自行抽查 P0-1（`media_cache.dart` 全量重哈希）、P1-1（全局配额枚举）等关键断言属实 | 无需返工 |
| 引用消息修复（TDD） | 2026-09-17 | 2026-09-17 | 主动 | B | 21 条新测试；matrix/performance 回归 1576 通过 | 完成 |
| 相册编辑入口 + 裁剪重做 | 2026-09-17 | 2026-09-17 | 主动 + 3 次返工 | B | 返工原因：① 裁剪角控制点松手后未清高亮（未 setState）② 测试画布映射未随"画布占满编辑区"更新 ③ 相册预览测试的命中区/路由过渡/DOM 采样阈值需按真实行为校正。最终 24 条新测试 + 6 条既有测试全绿 | 完成 |
| UI demo/契约同步 | 2026-09-17 | 2026-09-17 | 主动 | C | 契约 PASS、`npm test` 209 通过 | 完成 |
| 全量门禁 | 2026-09-17 | 2026-09-17 | 工具（后台） | D | `flutter analyze` 0 issue；全量 `flutter test` 3070 通过 / 0 失败 | 完成 |

- 总墙钟：未知（跨会话执行，未逐步记录时间戳；不按文件修改时间编造）。
- 重复工作：无重复的等价门禁；引用链回归（1576 条）与全量（3070 条）属不同覆盖范围，非重复。
- 未知时段：`scripts/verify.ps1` 的完整执行时长未记录（见交接与回退）。

## 交接与回退

- 已确认根因/已排除假设：
  - 引用永久 loading = ① 卡片只有"本机窗口命中"一条路径 ② 无状态机/无超时 ③ 远端补路径只在点击时触发 → 已修。
  - 已排除「用 `Future.delayed` 兜底」「失败的 catch 全吞」「清缓存重下」等伪修复；失败一律发布成可重试状态。
  - 裁剪"不符合微信" = 旧实现是"拖动框选一个矩形"，没有默认裁剪框/控制点/遮罩，且按钮视觉弱 → 已重做。
- 待办及验收失败项：
  - 真机验收（用户执行）：相册编辑全链路、裁剪手势手感、弱网下引用卡片 3 秒失败→重试。
  - 审计 P0-1/P0-2/P0-3 与 P1-1..P1-5 未修（本阶段只审计），可作为下一批任务。
  - R1（未写回 Room local database）与 R4（还原语义）需产品/真机确认。
- 已发布与仅候选的区别：**无发布、无候选包**；本次只有本地工作树改动。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。
- 运行中 CI/命令：`scripts/verify.ps1` 曾以后台作业启动（`pwsh-57`），结果见本任务验证记录；
  未创建任何隧道；未占用端口。
- 下次恢复先检查的事实：`git status` 与 `git rev-parse --short HEAD`（确认仍在 `81d9e612` 之上、改动未被他人覆盖）、
  `docs/verification/2026-09-17-media-quote-image-editor.md` 的「修改文件」表。
