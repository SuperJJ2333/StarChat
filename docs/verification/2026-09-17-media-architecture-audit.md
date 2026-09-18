# 媒体架构审计（Flutter 客户端）

- **范围**：`apps/mobile_flutter`（Flutter 应用，包名 `liuhetong_mobile`）的图片 / 视频 / 头像 / 文件媒体链路与缓存。
- **方式**：只读源码走查。本次审计**未修改任何 Dart 源码、未运行构建、未运行测试、未提交任何内容**。
- **证据基线**：`apps/mobile_flutter/lib/**`。审计期间 `lib/features/matrix/matrix_e2ee_client.dart` 被**并发修改**（行数 6397 → 6447），该文件的行号以本次读取时刻为准；表中其余媒体文件在审计期间未被改动，行号即文件当前内容行号。
- **未确认**项一律显式标注（见附录 A）。
- **文件位置**：`docs/verification/2026-09-17-media-architecture-audit.md`（canonical）。最初落在
  `docs/verification/artifacts/2026-09-17/MEDIA_ARCHITECTURE_AUDIT.md`，而 `docs/verification/artifacts/`
  被 `.git/info/exclude` 排除、无法随仓库评审，故移至当前可跟踪路径；已合并为唯一一份，避免双份漂移。

> **行号漂移提示（2026-09-17 追加）**：本审计产出后，同一批次任务修改了下列文件，
> 因此本文件中引用它们的**行号可能整体平移**（内容与结论不变）；定位时请以函数名/字符串为准：
> `features/matrix/matrix_e2ee_client.dart`（引用消息解析能力 + 导入）、
> `features/matrix/room_page.dart`（引用卡片状态机）、
> `features/matrix/room_timeline_controller.dart`、`features/matrix/matrix_room_timeline_adapter.dart`、
> `features/matrix/device_gallery_source.dart`（新增 `editedGalleryPhoto`，其后行号约 +14）、
> `features/matrix/image_picker_page.dart`（大图预览「编辑」入口，行号漂移较大）、
> `ui/chat/wechat_image_editor.dart`（裁剪重做，已整体重写）。
> 未改动文件的引用行号仍然有效。

---

## 0. 结论速览

| 问题 | 结论 | 关键证据 |
| --- | --- | --- |
| 哪一步压缩图片 | 相册"压缩图"= photo_manager `thumbnailDataWithSize(1280,1280, quality:80)`；缩略图 = `buildChatImageThumbnail`（≤800px/≤100KB，JPEG）；朋友圈 = `MomentImagePreprocessor`（≤1080px/≤500KB） | `device_gallery_source.dart:627-630`、`media_thumbnail.dart:29-69`、`moment_image_preprocessor.dart:72-115` |
| 是否有多个演绎版 | 是。同一张图在一次聊天发送中最多 **2 份上传**（正文演绎版 + `info.thumbnail_file` 缩略图）；"原图"开关切换的是正文那份 | `room_page.dart:1767-1799`、`media_cache.dart:775-788` |
| 客户端是否有通用 `uploadMedia` | **没有**。上传只有两条出口：SDK `room.sendFileEvent`（聊天/群/公告）与业务 API `PUT /moments/media/uploads/{id}/content`（朋友圈） | `matrix_e2ee_client.dart:6278`、`business_api_client.dart:1289-1302` |
| 视频是否渐进式播放 | 否。整文件下载/解密落盘后才 `VideoPlayerController.file` 播放 | `media_cache.dart:330-341`、`wechat_video_message.dart:213-226` |
| 视频是否落盘 | 是，落 `{docs}/chat-media/v2/<sha256(account)>/objects/`，受 384/512 MiB 全设备配额 LRU 淘汰 | `media_cache.dart:19-20,301-319,383-402` |
| 同一文件同时发聊天 / 朋友圈 / 群 | 客户端**不跨域复用**：远端至少 3 次上传（Matrix 与业务 API 各一套存储）；本地对象存可因字节相同而合并，但预览缓存仍多份 | 见 §4 |

---

## 1. 图片加载流程

### 1.1 全链路（以聊天"相册 → 发送"为例）

| # | 步骤 | 实现（函数） | 文件:行 | 产物/备注 |
| --- | --- | --- | --- | --- |
| 1 | 选择图片（聊天） | `RoomPage._pickAndSendImages` → `ImagePickerPage` → `DeviceGallerySource` | `room_page.dart:1636-1644`；`device_gallery_source.dart:531-577` | photo_manager 分页：首屏 12 张、后续 20 张/页（`device_gallery_source.dart:94-98`） |
| 1' | 选择图片（拍摄） | `MediaMessageService.captureToFile` | `media_message_service.dart:133-141` | `pickImage(camera, maxWidth: 2160, imageQuality: 92)`——相机路径的"压缩"其实就是 image_picker 的这两个参数 |
| 1'' | 选择图片（朋友圈） | `MomentComposerPage._pickImages` | `moment_composer_page.dart:227-255` | `pickMultipleMedia`，仅保留图片 |
| 2 | **压缩（聊天正文）** | `DeviceGallerySource._readImage(compressed: true)` | `device_gallery_source.dart:594-633`（压缩点 `:627-630`） | `thumbnailDataWithSize(ThumbnailSize(1280,1280), quality: 80)`；GIF 与"原图"开关绕过压缩（`:622-625`） |
| 2' | **压缩（朋友圈正文）** | `MomentImagePreprocessor.process` | `moment_image_preprocessor.dart:72-115` | 最长边 ≤1080px（`:7`），质量阶梯 `[85,70,55]`（`:64`），目标 ≤500KB（`:8`）；最低质量仍超限时**仍返回该结果**（`:109-114`） |
| 3 | 入队/串行化 | `RoomPage._enqueueMedia` | `room_page.dart:1849-1865` | 房间内发送串行；视频另有账户级 outgoing 队列 |
| 4 | **生成本地缩略图（≤800px/≤100KB）** | `buildChatImageThumbnail` | `media_thumbnail.dart:29-69` | 常量 `:8-9`；质量阶梯 `[75,60,50,40]`（`:37`），仍超限降到 600/480（`:51`）；GIF 直接返回 null（`:32`） |
| 5 | 本地保留原始字节 | `cacheOutgoingMedia`（正文 + 缩略图各一次） | `media_cache.dart:775-788`；调用点 `matrix_e2ee_client.dart:6257-6268` | 以 `sha256(bytes)` 为对象名写入本地对象库 |
| 6 | 构造事件 + 确定性信封 | `prepareContentAddressedMedia` / `MediaEnvelope` | `content_addressed_media.dart:215-251,136-175` | 写入扩展 `chatflow_media = {v:1, content_sha256, thumbnail_sha256}`（`:239-243`）；密钥由 `sha256` 经文 HKDF 派生（`:158-174`），`AppConfig.deterministicMediaEncryption` 默认值见 `core/app_config.dart:5-7` |
| 7 | 上传（加密） | SDK `room.sendFileEvent` | `matrix_e2ee_client.dart:6278-6283` | 客户端只把密文交给 SDK；正文与缩略图各产生一个 `mxc://` |
| 7' | 上传（朋友圈） | `beginMomentUpload` → `putMomentUpload` → `completeMomentUpload` | `business_api_client.dart:1276-1309`；调用 `moment_composer_page.dart:137-171` | 业务 API 存储，与 Matrix 媒体库完全分离 |
| 8 | 消息事件落地 | `chatflow_media` 扩展 | `content_addressed_media.dart:239-243` | 只有解密成功后 `TrustedMediaHashes.fromEvent` 才认账（要求 `originalSource.type == Encrypted && type != Encrypted`，`:111-114`；解析 `:116-133`） |
| 9 | 下载 + 解密 | `downloadMediaContent` / `downloadMediaContentBounded` | `content_addressed_media.dart:22-31,35-58` | 走 SDK `event.downloadAndDecryptAttachment`；有界版带 `maxDownloadBytes` 与 `MediaContentLimitException`（`:54-57,85-87`） |
| 10 | 缓存编排 | `loadMediaWithCache` | `media_cache.dart:630-752` | 内存 → 磁盘对象 → 调度器下载（并发上限见 `media_load_scheduler.dart:40`） |
| 11 | 落盘 | `MediaCache.store` / `_store` | `media_cache.dart:267-319` | 对象 `objects/{sha256}[.mp4|.mov]` + `.len` + 引用 `refs/{sha256([roomId,eventId])}.ref`（`:155,301-319`） |
| 12 | 展示（气泡） | `RoomPage._loadImagePreview` → `ContainImageBubble`（`loadChatImagePreview` 决定"缩略图优先"） | `room_page.dart:1565-1591`、`room_page.dart:3543-3569`；`chat_image_preview.dart:7-23`；`contain_image_bubble.dart:18-29` | **缩略图优先**，缺失/失败回退正文；解码被 `ResizeImage(720)` 约束（`contain_image_bubble.dart:27-28`）。注意 `EncryptedImageMessage` 定义仍在但房间页已不再使用（见 P2-6） |
| 13 | 展示（大图） | `ImageViewerPage._loadOriginal` | `encrypted_media_view.dart:352-415,540-553` | 预览先行，点"查看原图"才异步取正文；查看器解码 `maxEdge: 2048`（GIF 720，`:546`） |

### 1.2 压缩到底发生在哪一步

- **聊天相册**：压缩由 photo_manager 完成，代码位置 `DeviceGallerySource._readImage` 的 `asset.thumbnailDataWithSize(const ThumbnailSize(1280, 1280), quality: 80)`（`device_gallery_source.dart:627-630`）。这不是应用自己实现的比例缩放算法，而是把"解码 + 缩放 + JPEG 编码"交给原生相册插件。
- **拍摄**：由 image_picker 参数完成（`media_message_service.dart:134-138`）。
- **朋友圈**：由 `MomentImagePreprocessor._process` 用 `FlutterImageCompress.compressWithList` 完成（`moment_image_preprocessor.dart:90-108`），并用 `ui.instantiateImageCodec` 先读真实像素尺寸（`:75-80`）。
- **文件选择器发的视频**：`MediaMessageService.sendSelectedFile` 走 `transcodeForChat`（`media_message_service.dart:205-209`）。

### 1.3 缩略图在哪一步生成

- **聊天 / 群**：由客户端在发送前生成，入口 `buildChatImageThumbnail`（`media_thumbnail.dart:29-69`），由 `room_page.dart:1319`（拍摄）与 `room_page.dart:1779`（相册）调用。
- **兜底**：当调用方没给缩略图、且文件是图片时，`_sendMedia` 会用 SDK 的 `image.generateThumbnail` 兜底生成，并挂在 `OutgoingMediaThumbnailCache`（按 `sha256(bytes)` 记忆，48 条 / 8 MiB，`outgoing_media_thumbnail_cache.dart:10-11,24-59`）；生成结果比原图还大时丢弃（`matrix_e2ee_client.dart:6242-6256`）。
- **朋友圈**：**不生成缩略图**，只有一份 ≤1080px/≤500KB 的正文图（`moment_image_preprocessor.dart:72-115`）；`image_cache_keys` 是服务端下发的摘要，用作缓存键，不是第二份演绎版（`moment_models.dart:211-218`）。
- **视频**：封面帧由 `extractVideoPoster`（`video_poster_extractor.dart:17-39`）或多时间点首帧（`device_gallery_source.dart:682-745`）生成，发送时作为 `thumbnailBytes` 随事件上传（`room_page.dart:1768-1777`）。
- **头像**：不是客户端生成，服务端按 `width/height=96, method=crop, animated=false` 输出（`avatar_url_resolver.dart:17,121-132`）。

### 1.4 演绎版矩阵

| 场景 | 正文那份 | 缩略图那份 | 备注 |
| --- | --- | --- | --- |
| 聊天/群 图片（默认） | 1280px q80 JPEG | ≤800px、≤100KB JPEG | 两份都上传、都本地保留 |
| 聊天/群 图片（"原图"开关） | 原始字节 | ≤800px、≤100KB JPEG | 原图仅做 20MiB 上限校验（`gallery_media_payload.dart:8,27-35`） |
| 聊天 GIF | 原始动图 | **无**（`media_thumbnail.dart:32`；预览也直接取整图 `chat_image_preview.dart:12-22`） | GIF 上限 20MiB / 400 万像素（`gif_image_policy.dart:3-4`） |
| 闪照 | 原始字节 | 无（`room_page.dart:1620-1627` 不传 thumbnail） | 仅内存驻留，不写明文预览缓存（`:1615-1619`） |
| 视频 | 转码 mp4（640×480 或 aggressive 档） | 封面 JPEG（约 480px） | `video_transcode.dart:54,58-65`、`device_gallery_source.dart:638-657` |
| 朋友圈 | ≤1080px、≤500KB JPEG | 无 | 只有一份 |

### 1.5 是否重复存储

**会，且是设计内 + 设计外的叠加**：

1. **设计内**：正文与缩略图是两个独立对象，各写一份本地对象、各上传一次（`matrix_e2ee_client.dart:6257-6268`）。GIF 除外。
2. **设计外的同字节多份**：出站图片会在三处留下同一批预览字节——
   - `MediaCache` 对象库（缩略图对象，`media_cache.dart:301-319`）；
   - `RoomImagePreviewCache` → `EncryptedEmojiPreviewStore` 的加密预览文件（`room_image_preview_cache.dart:33,83-95,153-178`）；
   - Flutter 解码位图缓存（`ResizeImage` 解码结果，上限见 `core/media_resource_policy.dart:13-15`）。
3. **发送方回读副本**：`RoomImagePreviewCache.seed(eventId, preview)` 会在事务 id 与最终 eventId 上各存一份内存/磁盘预览（`room_page.dart:1735-1739,1748-1756,1840-1847`）。
4. **同一字节跨房间会合并**（本地对象名就是 `sha256`，`media_cache.dart:303-305`），既有测试已锁定该行为（`test/features/matrix/media_content_dedup_test.dart:111`）。

---

## 2. 视频加载流程

### 2.1 全链路

| # | 步骤 | 实现 | 文件:行 |
| --- | --- | --- | --- |
| 1 | 选择视频 | 相册 `DeviceGallerySource` / 拍摄 `MediaMessageService.captureVideoToFile` / 文件选择器 | `device_gallery_source.dart:557-572`、`media_message_service.dart:146-150` |
| 2 | **压缩（转码）** | `transcodeForChat` → `_transcodeForChat`（H.264+AAC，两趟 profile：**normal 640×480/1.2 Mbps/24fps**，失败或超 20MiB 再用 **aggressive 320px/12fps/动态码率**） | `video_transcode.dart:131-139,141-221`；档位 `:54,58-65`；上限 `:7` |
| 3 | 转码产物归属 | `VideoRendition.dispose()` 删除压缩产物（原文件永不删除） | `video_transcode.dart:120-122`；`prepared_chat_video.dart:29-46` |
| 4 | **生成封面** | `extractVideoPoster`（多时间点 + 近黑帧判定）或 `DeviceGallerySource._videoPosterBytes`（兜底 photo_manager 480px 封面） | `video_poster_extractor.dart:17-39`；`device_gallery_source.dart:638-657` |
| 5 | 入队 | `enqueueVideoFiles` → 账户级 outgoing job（预留 `maxOriginalVideoBytes + 512KiB`） | `matrix_e2ee_client.dart:4646,4715` |
| 6 | 上传 | `_sendOutgoingMedia` → `_sendMedia` → `room.sendFileEvent` | `matrix_e2ee_client.dart:4807`、`6191`、`6278` |
| 7 | 消息展示 | `VideoMessageCard`：封面 + 播放按钮 + 时长角标 | `wechat_video_message.dart:21-127`；接线 `room_page.dart:3277-3281` |
| 8 | 点击播放 | `resolveCachedVideoFile`（磁盘直读 → 内存 flight → 下载解密落盘）→ `VideoPlayerController.file` | `room_page.dart:1445-1467`；`media_cache.dart:802-844`；`wechat_video_message.dart:213-226` |

### 2.2 四个明确结论

1. **封面是否先加载？** 是，但**不一定便宜**。
   - 新消息（事件带 `thumbnail_sha256`）：只下载小图（`room_page.dart:1476-1479`）。
   - 事件没有可用缩略图（旧消息 / 抽帧失败 / 海报超过 512KiB 被丢弃，见 `matrix_e2ee_client.dart:4072-4075` 的 `poster` 过滤）：**会为了封面把整段视频下载并解密到磁盘**（`room_page.dart:1480-1484`，legacy 分支 `:1501-1506`）。
   - 触发时机：`VideoMessageCard.initState` 立即调用 `posterLoader`（`wechat_video_message.dart:46-54`），没有可见性门控，因此列表构建/预取范围内的每个视频都会立刻发起该请求。

2. **是否有渐进式加载？** 否。没有 Range/分片/边下边播，播放器只接受完整本地文件（`media_cache.dart:330-341` 缺文件直接抛 `FileSystemException('Video cache is unavailable')`；`wechat_video_message.dart:223` 用 `VideoPlayerController.file`）。`VideoPosterCell` 的"可见性检测"实现是空操作（`video_gif_cells.dart:305-320`）。

3. **是否下载两次？** 常规路径**否**：磁盘命中即零下载（`media_cache.dart:811-818`），内存/网络 flight 合并（`:819-825`），封面兜底下载的整文件随后被播放直接复用。
   会额外下载的情形：
   - 上面第 1 条的"封面兜底"是**整文件下载**（不是双下载，但代价等于一次播放下载）；
   - 发送方相册视频点击自己的消息会读本地文件（`SentVideoLocalRegistry`，`room_page.dart:1446-1456`），但登记的是**相册原文件**而不是发送用的压缩产物（见 §6 P1-2）；
   - 相机拍摄的视频不登记，只能走网络/磁盘缓存（`room_page.dart:1888-1898`，`deleteSourceWhenDone: true`）。

4. **视频是否在磁盘缓存、在哪、怎么淘汰？** 是：
   - 位置：`{ApplicationDocuments}/chat-media/v2/<sha256(accountId)>/objects/<sha256(bytes)>[.mp4|.mov]`（视频容器后缀由文件头 `ftyp` 品牌判定，`media_cache.dart:343-356`）；
   - 引用：`refs/<sha256([roomId,eventId])>.ref`（`:144-156`）；
   - 完整性：`objects/*.len` 存字节数，命中时**整文件重算 sha256**（`:198-215`，见 P0-1）；
   - 淘汰：软配额 **384 MiB**、硬配额 **512 MiB**（`:19-20`），仅在 `_store` 成功后触发 `_enforceDiskQuota`，按 mtime 从旧到新删到软配额（`:383-402`）；枚举范围是 `chat-media` **整棵目录**（含其他账号与 legacy 目录，`:362-371`）。

---

## 3. 当前缓存层级

### 3.1 四层总表

| 层 | 存储什么 | 生命周期 | 淘汰策略 | 最大容量（原文常量） | 证据 |
| --- | --- | --- | --- | --- | --- |
| **Memory** | 已验证的编码字节（图片/视频/GIF/预览） | 进程内；房间页 dispose、账号清理、内存压力即失效 | LRU（插入序）+ 字节预算 + 条目上限；共享预算跨 owner 引用计数 | `MediaMemoryCache` 默认 `maxEntries = 48`、`maxBytes = 64 * 1024 * 1024`（`media_cache.dart:431-432`）；共享预算 `MediaMemoryBudget({this.maxBytes = 32 * 1024 * 1024, this.maxEntries = 512})`（`media_memory_budget.dart:19,89`）；`videoMemoryCache = MediaMemoryCache(maxEntries: 6, maxBytes: 32 * 1024 * 1024, ...)`（`media_cache.dart:792-796`）；房间预览 `maxEntries = 256, maxBytes = 64 * 1024 * 1024`（`room_image_preview_cache.dart:13-16`）与会话级 `256 / 32MiB`（`:49-52`）；视频封面 `memoryBudgetBytes = 32 * 1024 * 1024`、`memoryMaxEntries = 256`（`video_poster_session_cache.dart:27-28`）；出站缩略图 `48 / 8MiB`（`outgoing_media_thumbnail_cache.dart:10-11`）；Emoji 预览 `maxBytes = 8 * 1024 * 1024`（`emoji_preview_cache.dart:21`）；相册网格缩略图 **96 条、无字节上限**（`device_gallery_source.dart:437-439`）；Flutter `imageCache` `maximumSize = 512`、`maximumSizeBytes = 64 * 1024 * 1024`（`core/media_resource_policy.dart:13-15`）；动画并发 `maxActive = 2`（`ui/chat/media_activity.dart:5`） |
| **Disk（应用自管）** | 解密后的明文对象字节（图片/视频/语音/文件） | 账号清理、配额淘汰 | mtime 最旧优先，删到软配额 | 软 `diskSoftQuotaBytes = 384 * 1024 * 1024`、硬 `diskHardQuotaBytes = 512 * 1024 * 1024`（`media_cache.dart:19-20`）；**全设备共享，不是每账号** | `media_cache.dart:140,301-319,383-402` |
| **Disk（加密预览）** | 聊天缩略图预览、Emoji 预览（AES-GCM） | 账号清理 / 逐键删除 | 写入后按 mtime 删到 64MiB；单文件 >64MiB-28 字节直接不落盘 | `64 * 1024 * 1024`（`emoji_preview_cache.dart:196`）；键空间 `room-image-v1:<accountId>`（`room_image_preview_cache.dart:33`） |
| **Disk（临时/会话）** | 视频封面帧（AES-GCM，密钥仅内存） | 房间页 dispose 整体删除 | **无配额、无 LRU**；所有者显式销毁 | 注释明示"No quota eviction"（`video_poster_disk_store.dart:11-12,77-84`）；目录 `createTemp('chatflow-posters-')`（`:23-26`） |
| **Disk（无人管理的帧缓存）** | 相册视频首帧 JPEG | 仅进程内内存表 + 磁盘文件 | **无配额、无淘汰、不随账号清理** | 目录 `{docs}/video_first_frame_cache/<sha256(path\|id\|duration\|size)>.jpg`（`device_gallery_source.dart:716-724`） |
| **Disk（第三方 CacheManager）** | 朋友圈图片、头像（HTTP 响应缓存） | TTL 过期 + LRU | CacheManager 自身 LRU | 朋友圈 `stalePeriod: 7 天`、`maxNrOfCacheObjects: 200`、`concurrentFetches = 3`（`ui/moments/moment_media_cache.dart:50-62`）；头像 `30 天 / 500`（`ui/foundation/avatar_cache.dart:13-23`） |
| **Database** | Matrix 事件、房间状态、会话；SDK 本地库文件（按 `mxc` URI 键，Emoji 路径已确认使用） | 随矩阵本地库（SQLCipher） | SDK 自管，**未确认** | 库构造 `databaseFactory.openDatabase(databasePath, ...)` + `MatrixSdkDatabase`（`matrix_client_factory.dart:424-435`）；按 URI 读取库内文件的用法见 `matrix_e2ee_client.dart:3240`（聊天附件是否复用同一库文件缓存未确认） |
| **Database（业务域）** | 朋友圈首页 JSON 快照（SharedPreferences）+ 分页/墓碑（SQLite `MomentsPageStore`） | 按账号命名空间，登出/清理时删该账号键 | 显式 `clear()` + 账号 generation | 键 `cache.moments.feed.latest.audience-v2.<accountKey>`（`core/cache/cache_repository.dart:34-40`）；`MomentsCache.clear()`（`:495-522`） |
| **Remote** | Synapse 媒体库（每事件一个 `mxc://`）、业务 API 朋友圈媒体、服务端头像缩略图 | 服务端策略 | **未确认**（客户端不可见；无服务端配额证据纳入本次只读范围） | 客户端侧无任何远端容量/去重契约 | `matrix_e2ee_client.dart:6278`、`business_api_client.dart:1296`、`avatar_url_resolver.dart:121-132` |

### 3.2 缓存在哪里被清理（值得注意：并非每个缓存都有清理点）

| 清理动作 | 触发点 | 清除范围 | 证据 |
| --- | --- | --- | --- |
| `clearMediaMemoryCaches()` | 应用启动注册的内存压力回调、会话失效、登出、`MediaCache.clearAccount` | 共享预算、共享媒体内存、视频内存、在途 flight、调度器、已注册的解码缓存清理器 | 定义 `media_cache.dart:618-628`；调用 `main.dart:35`、`core/session_bootstrap_controller.dart:88,294`、`media_cache.dart:67` |
| `MediaCache.clearAccount(accountId)` | 仅在 `clearLocalChatData()`（"清除本机聊天数据"确认流程） | `${docs}/chat-media/v2/<sha256(account)>` 整目录 + 写清除纪元文件 + 递增账号代次 | `media_cache.dart:62-109`；调用 `matrix_e2ee_client.dart:5640` |
| `registerAccountMediaCacheClearer(...)` | 账号清理时统一回调 | 目前**唯一注册者是朋友圈媒体缓存** `MomentMediaCache.clearAccount` | `media_cache.dart:610-614`；`ui/moments/moment_media_cache.dart:111-114,142-155` |
| `MediaCache.discardLegacyCache()` | 每次 `loadMediaWithCache` 顺带执行 | legacy `chat-media/<账号>_<hash>` 目录 | `media_cache.dart:113-128,641` |
| `MediaResourcePolicy.didHaveMemoryPressure` | 系统内存压力 | `clearEncoded()` + Flutter `imageCache.clear()/clearLiveImages()` | `core/media_resource_policy.dart:19-25` |
| `VideoPosterSessionCache.clearAll()/clearMemory()/evict()` + `VideoPosterDiskStore.dispose()` | 房间页 dispose（切会话/退出） | 视频封面内存 + 加密临时目录 | `room_page.dart:4149-4155`；`video_poster_session_cache.dart:210-278`；`video_poster_disk_store.dart:77-84` |
| `RoomImagePreviewCache.dispose()` / `clearSessionMemory()` | 房间页 dispose / 登出与内存压力注册 | 该房间内存副本 + 会话级共享内存 | `room_page.dart:4149`；`room_image_preview_cache.dart:64-67,79-81,180-185` |
| `AvatarCache.invalidateUser` | 资料/头像变更 | 该用户的头像缓存键（可选保留上一张） | `ui/foundation/avatar_cache.dart:131-145`；调用 `features/profile/profile_controller.dart:93`、`features/matrix/profile_repository.dart:871` |
| `MomentMediaCache.retry` / `MomentMediaCache.clearAccount` | 单图加载失败重试 / 账号清理 | 该键的 `MediaCache` 引用 + CacheManager 文件 | `ui/moments/moment_media_cache.dart:27-36,142-155` |
| **没有被清理的** | — | `video_first_frame_cache`（相册首帧）、Flutter CacheManager 的 TTL 之外无账号级清理 | `device_gallery_source.dart:716-724` |

### 3.3 已锁定媒体行为的既有测试

`apps/mobile_flutter/test/` 下与媒体直接相关的测试（均为真实路径，本次未运行）：

- 缓存与去重：`features/matrix/media_content_dedup_test.dart`（含 `identical decrypted content across rooms occupies one physical object`、`ten references share a single byte instance`）、`features/matrix/media_cache_clear_test.dart`、`features/matrix/media_stream_integrity_test.dart`、`features/matrix/media_transfer_integrity_test.dart`、`features/matrix/fourth_cache_regression_test.dart`
- 内存/预算/调度：`features/matrix/media_memory_cache_test.dart`、`features/matrix/media_memory_budget_test.dart`、`features/matrix/media_load_scheduler_test.dart`、`features/matrix/media_consumer_scope_test.dart`、`features/matrix/media_consumer_integration_test.dart`、`core/media_resource_policy_test.dart`、`performance/media_cache_metrics_test.dart`、`performance/media_hit_baseline_test.dart`
- 图片链路：`features/matrix/media_thumbnail_test.dart`、`features/matrix/chat_image_preview_test.dart`、`features/matrix/gallery_media_payload_test.dart`、`features/matrix/device_gallery_source_test.dart`、`features/matrix/image_picker_page_test.dart`、`features/matrix/gif_send_safety_test.dart`、`ui/encrypted_image_message_test.dart`、`ui/chat/image_original_stream_test.dart`、`ui/chat/image_viewer_test.dart`、`ui/chat/image_viewer_lifecycle_test.dart`、`ui/chat/contain_image_bubble_test.dart`、`ui/chat/contain_image_bubble_lifecycle_test.dart`、`ui/chat/image_edge_layout_test.dart`、`features/matrix/image_contain_layout_test.dart`、`features/matrix/chat_media_shared_logic_test.dart`
- 视频链路：`features/matrix/video_viewer_cache_test.dart`、`features/matrix/video_poster_session_cache_test.dart`、`features/matrix/video_poster_disk_store_test.dart`、`features/matrix/video_poster_extractor_test.dart`、`features/matrix/video_first_frame_cache_test.dart`、`features/matrix/video_rendition_strategy_test.dart`、`features/matrix/video_send_limit_test.dart`、`features/matrix/video_send_stage_test.dart`、`features/matrix/gallery_video_lifecycle_test.dart`、`features/matrix/video_forward_backend_test.dart`、`features/matrix/file_video_metadata_test.dart`、`features/matrix/video_playback_extension_test.dart`、`ui/chat/video_gif_cells_test.dart`、`ui/video_playback_arbiter_test.dart`、`ui/video_playback_lease_coordinator_test.dart`、`ui/video_viewer_lifecycle_test.dart`
- 朋友圈媒体：`ui/moment_media_cache_test.dart`、`ui/moment_media_lifecycle_test.dart`、`features/moments/moment_image_preprocessor_test.dart`、`features/moments/moment_gallery_contract_test.dart`、`features/moments/moment_composer_page_test.dart`、`ui/moment_stable_image_identity_test.dart`、`ui/moment_image_prefetcher_test.dart`、`ui/moment_image_viewer_lifecycle_test.dart`、`features/moments/moment_preview_cache_test.dart`、`core/cache_repository_test.dart`、`core/moments_page_store_test.dart`
- 头像：`ui/retained_image_cache_manager_test.dart`、`ui/user_avatar_identity_test.dart`、`ui/user_avatar_recovery_test.dart`、`ui/avatar_retry_test.dart`、`features/matrix/avatar_url_resolver_test.dart`、`features/matrix/matrix_user_avatar_test.dart`、`features/matrix/conversation_avatar_identity_test.dart`、`ui/group_avatar_mosaic_test.dart`
- 访问策略/项目级审计：`features/matrix/media_message_access_policy_test.dart`、`features/matrix/room_media_gallery_projection_test.dart`、`features/matrix/media_audit_test.dart`、`features/matrix/content_addressed_media_test.dart`、`features/matrix/media_renderer_binding_test.dart`、`features/matrix/incoming_sdk_media_test.dart`

---

## 4. 媒体去重现状

### 4.1 真实行为（同一文件 A：发聊天 → 发朋友圈 → 发群）

| 环节 | 聊天（单聊） | 群聊 | 朋友圈 | 是否复用 |
| --- | --- | --- | --- | --- |
| 生成演绎版 | 1280px q80 + ≤800px 缩略图 | 同左 | ≤1080px/≤500KB | **不复用**：三处算法、参数、质量阶梯都不同，产出字节不同 |
| 上传出口 | `room.sendFileEvent` | `room.sendFileEvent` | `PUT /moments/media/uploads/{id}/content` | 两套完全独立的存储 |
| 远端对象 | 每条消息正文 1 个 `mxc://` + 缩略图 1 个 | 同左 | 业务 API 媒体 1 份 | **客户端不做任何"已上传过"查询** |
| 本地对象 | `objects/sha256(正文)`、`objects/sha256(缩略图)` | 同上（同账号同字节共用同一个对象文件） | `moments` 命名空间下同样落 `MediaCache` 对象 | **本地按字节去重有效**（跨房间、跨消费者） |
| 本地预览 | `RoomImagePreviewCache` 加密预览 | 同左 | `MomentMediaCache` CacheManager 条目 | 各存一份 |

**结论**：
- **本地解密字节层面**：内容寻址已实现——`MediaCache._store` 用 `sha256(bytes)` 作为对象名（`media_cache.dart:303-305`），`MediaCacheKey.identity` 在有可信摘要时收敛为 `"<account>":content:<sha256>`（`:859-864`），并有引用文件把"事件/来源"与对象解耦（`:144-156,754-771`）。因此同一账号下"同一份字节"只占一个物理对象（测试 `media_content_dedup_test.dart:111,82`）。
- **本地磁盘上仍会重复**：同一张图在一次发送里天然产生 2 个不同字节的对象（正文 + 缩略图）；预览又额外落一份加密预览文件（`room_image_preview_cache.dart:83-95`）；朋友圈/聊天各自还有一层第三方 CacheManager 文件。
- **远端**：客户端**没有任何远端去重**。每次 `sendFileEvent` / `completeMomentUpload` 都是一次独立上传；事件里记录的是各自的 `mxc://`（`matrixMediaSourceIdentity` 正是从 `file.url`/`thumbnail_url` 或加密描述符推导来源身份，`media_cache.dart:891-926`），没有 `media_id` 复用概念。
- **但有一个重要事实降低了远端重复度**：媒体加密是**确定性**的——密钥/IV 由 `sha256(plaintext)` 经固定域 HKDF 派生、计数器固定为零（`content_addressed_media.dart:136-174`），因此**相同明文字节每次产生完全相同的密文**。这使"按内容寻址的服务端存储"在协议上是可行的（同哈希 → 同 blob）。
- **服务端是否真的按内容哈希合并**：**未确认**。本次审计只读客户端源码，仓库内没有 Synapse 媒体库去重实现的证据；请在服务端侧验证后再下结论。
- **跨域去重的根本障碍**：聊天正文（1280px q80）、朋友圈（≤1080px q55-85）与"原图"是不同字节，即使服务端内容寻址也命中不了。只有"原图 → 原图"或"同一演绎版跨会话转发"才可能命中。

**转发的既有优化**：转发已收到的事件时不重新压缩、不重新上传原始明文——`loadMediaWithCache` 用原事件的 `content_sha256`/`sourceIdentity` 命中本地对象，再把**解密后的同一批字节**经 `_sendMedia` 重新加密上传到目标会话（`matrix_e2ee_client.dart:1567,1594`；outgoing 转发 `:4896`）。远端仍是目标会话独立的一份，但省掉了"再下载原图 + 再压缩"。

### 4.2 键形状对照

| 用途 | 键形状 | 证据 |
| --- | --- | --- |
| 内存/磁盘内容身份 | `"<accountId>":content:<sha256>`；无摘要时 `jsonEncode([accountId, sourceIdentity ?? [roomId,eventId]])` | `media_cache.dart:859-869` |
| 引用文件 | `refs/<sha256(jsonEncode([roomId, eventId]))>.ref`，内容为对象文件名 | `media_cache.dart:155,315-316` |
| 来源身份（同内容不同事件） | `sha256(jsonEncode([thumbnail, canonical(descriptor)]))` | `media_cache.dart:891-926` |
| 出站保留 | `loadMediaWithCache(MediaCacheKey(eventId: 'outgoing:$hash', contentSha256: hash))` | `media_cache.dart:775-788` |
| 朋友圈 | `moments-origin-account-v1:sha256(jsonEncode([origin, accountKey, cacheKey]))`，另有 `moments-url-account-v1` 与 legacy 键用于迁移 | `ui/moments/moment_media_cache.dart:86-96,126-130` |
| 房间预览 | `jsonEncode([accountId, roomId, eventId, 'preview-v1'])`（另有会话级命名空间键） | `room_image_preview_cache.dart:97-100` |
| 视频封面会话键 | `'$accountId\|$roomId\|$mediaId\|$mediaVersion\|$spec'`（不含会过期的 URL） | `video_poster_session_cache.dart:59-66` |
| 相册首帧 | `sha256('${origin.path}\|${asset.id}\|${asset.videoDuration}\|${await origin.length()}')` | `device_gallery_source.dart:720-723` |
| 头像 | `avatar:{userId}:{avatarVersion}`（尺寸不入键） | `ui/foundation/avatar_cache.dart:47-58` |

### 4.3 目标内容寻址存储（CAS）设计

目标模型（与现有实现的差距即为改造量）：

```
MediaObject {
  media_id     : "abc123"        // = sha256(plaintext) 前 16~64 位，逻辑主键
  content_sha256: <64 hex>
  size, mime, width, height, duration
  renditions   : { original, chat_1280, moment_1080, thumb_800, video_640, poster_480 }
  refs         : [ chat_message_1, moment_post_5, group_message_9 ]   // 引用计数
  stored_at    : <远端 blob id / mxc:// / business media id>
}
```

- 本地：对象文件已经是 `sha256` 命名，缺的是**统一的 MediaObject 清单 + 显式引用计数 + 演绎版族谱**。现有 `refs/*.ref` 已经是一份"事件 → 对象"的引用表，只需在其上补"对象 → 引用数"的反向索引（现在删除依赖配额 LRU，没有任何按引用计数回收的能力）。
- 远端：要让三处共用一份，需要协议/服务端配合（同一 blob 被多个事件引用）。**本次审计不建议改动 Matrix 协议层与消息事件格式**，因此可落地的部分只有：
  1. 客户端侧"演绎版归一"：把 ≤800px/≤100KB 缩略图、聊天正文演绎版、朋友圈演绎版收敛到同一套参数（或至少让同一参数被三处共用），使同源文件在不同域产生**相同字节**，从而让服务端内容寻址有机会命中；
  2. 客户端侧"上传前查重"：在 `_sendMedia` 之前用 `content_sha256` 查询本账号是否已有可复用的远端对象（需要服务端提供"按 sha256 查询 blob/媒体"的只读接口）；
  3. 引用式删除：撤回/删除消息时只解除引用，不再各自删除文件。
- 代价评估：`media_cache.dart` 的键/引用/配额三件事要一起改（现在配额淘汰与引用计数是冲突的：LRU 会删掉仍被引用、且离线可用的对象），并需要新增"对象 → 引用"的持久索引（可从现有 `refs/*.ref` 重建）。跨域归一还需要业务 API 与 Matrix 两侧都能接受同一演绎版参数。

---

## 5. 目标架构建议

### 5.1 `MediaService` 门面（统一 图片/视频/文件/头像）

```dart
/// 消费者只描述"要什么"，不关心存储/加密/调度细节。
enum MediaPurpose { chatBody, chatThumbnail, momentBody, avatar, videoPoster }

abstract interface class MediaService {
  /// 送达并取回可用字节（内部完成：内存 → 磁盘 → 下载 → 解密 → 落盘）。
  Future<MediaHandle> resolve(MediaRequest request, {MediaLoadPriority priority});

  /// 出站：本地保留 + 生成缺失演绎版 + 加密上传，返回事件/媒体 id。
  Future<MediaUploadResult> publish(MediaPublishRequest request);

  /// 引用式回收（替代"谁都能删文件"）。
  Future<void> release(MediaRef ref);

  /// 账号级清理（唯一入口，串行、代次围栏）。
  Future<void> clearAccount(String accountId);
}

final class MediaRequest {
  final String accountId;
  final MediaSource source;      // matrixEvent / businessUrl / localFile / avatarUri
  final MediaPurpose purpose;    // 决定演绎版与尺寸上限
  final int? maxBytes;           // 上限由调用方声明，服务内部强制
  final Object consumerScope;    // 可见性/取消/优先级
}
```

建议的接口分层：

| 组件 | 职责 | 现有可复用件 |
| --- | --- | --- |
| `MediaObjectStore` | `sha256` 对象库 + `.len` + 引用表 + 反向索引 + 配额 | `MediaCache`（`media_cache.dart:267-402`） |
| `MediaMemoryBudget` | 跨消费者字节预算与内部驻留 | `media_memory_budget.dart`（已实现，可直接复用） |
| `MediaLoadScheduler` | 网络/解码并发与优先级 | `media_load_scheduler.dart`（已实现） |
| `MediaCodecPolicy` | 每个 purpose 的压缩/缩略图参数 | `media_thumbnail.dart`、`moment_image_preprocessor.dart`、`video_transcode.dart`（参数需归一） |
| `MediaEnvelope` | 确定性加密信封与 `chatflow_media` 扩展 | `content_addressed_media.dart:136-251`（保持现状，不改协议） |
| `MediaGateway` | 两个出口：Matrix（SDK `sendFileEvent`）/ Business（`/moments/media/*`） | `matrix_e2ee_client.dart:6191`、`business_api_client.dart:1276-1309` |
| 消费者 | `ChatMediaConsumer` / `MomentsMediaConsumer` / `AvatarMediaConsumer` / `FileMediaConsumer` | `RoomImagePreviewCache`、`MomentMediaCache`、`AvatarCache` 收敛为消费者适配器 |

### 5.2 迁移路径（低风险顺序）

1. **只做门面（不改行为）**：新增 `MediaService`，内部直接委派给现有 `MediaCache`/`loadMediaWithCache`/`resolveCachedVideoFile`；先把聊天、朋友圈、头像三处调用点改为经门面（纯重构，测试可复用）。
2. **统一演绎版参数表**：把"聊天正文 1280/q80、缩略图 800/100KB、朋友圈 1080/500KB、视频 640×480、封面 480"集中为一张 `MediaCodecPolicy` 表（先不改参数，只集中，便于后续评估归一）。
3. **引用计数与配额解耦**：为对象库补反向索引，配额淘汰先跳过被引用对象；把"跨账号全局淘汰"改成"账号内配额 + 全局上限兜底"。
4. **删除入口收敛**：撤回/删除/账号清理统一走 `release()` / `clearAccount()`，消除各域自己删文件的路径。
5. （需服务端配合，另行评估）远端内容寻址与上传前查重。

---

## 6. 问题清单与优先级

| 编号 | 级别 | 现象 | 证据（文件:行） | 影响 | 建议修复方向 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | P0 | 磁盘缓存**每次命中**都对整个对象重算 SHA-256（先比对 `.len`，随后仍全量流式哈希） | `media_cache.dart:198-215`（`verifyMediaContentStream` 调用在 `:206`）、`content_addressed_media.dart:11-18`；命中路径 `media_cache.dart:158-188,811-818` | 打开一个 50–100MB 视频要重读并哈希整个文件才起播；`PerformanceCounter.mediaDiskHit` 统计的"命中"实际很贵；预览滚动同样触发 | 写入时校验一次并落"已验证"标记（对象名即摘要 + `.len` + mtime），命中只验长度；把全量校验降级为显式"完整性校验/修复"动作或后台抽样；大对象如需校验移入 isolate |
| P0-2 | P0 | 缺少缩略图的视频会**为了封面下载整段视频**；触发点在列表构件的 `initState`，无可见性门控 | `room_page.dart:1476-1484`（trusted 分支）与 `:1501-1506`（legacy 分支）；触发 `wechat_video_message.dart:46-54` | 旧消息/抽帧失败消息（`matrix_e2ee_client.dart:4072-4075` 会丢弃 >512KiB 的海报）在滚动时等于"整段视频下载"；弱网/移动数据代价高 | 封面缺失时先渲染占位并只在小图可用时加载；把封面兜底下载降级为"可见 + 主动点击/进入查看器"才触发；服务端/发送端保证封面必达（失败可重试上传） |
| P0-3 | P0 | 同源文件在不同域产出不同演绎版（聊天 1280/q80、朋友圈 1080/≤500KB、缩略图 800/≤100KB），且远端无任何去重与复用：同一文件发聊天+朋友圈+群 = 至少 3 次上传、3 份远端副本；本地还会有加密预览等多份 | `device_gallery_source.dart:627-630`、`moment_image_preprocessor.dart:64,72-115`、`media_thumbnail.dart:8-9,37-63`；上传出口 `matrix_e2ee_client.dart:6278`、`business_api_client.dart:1289-1302`；本地多份 `room_image_preview_cache.dart:83-95,153-178` | 流量、服务端存储与本地磁盘三重放大；同一张图最多可同时存在 4–6 份字节级副本 | 按 §4.3/§5.2 先统一演绎版参数表并落地 `MediaObject` 引用模型；远端内容寻址/查重需服务端接口另行评估（不改 Matrix 协议与事件格式） |
| P1-1 | P1 | 磁盘配额是**全设备共享**：枚举 `chat-media` 整棵树（含其他账号），一个账号写入可淘汰另一账号的对象；没有每账号配额 | `media_cache.dart:19-20,362-371,383-402`；根路径按账号分目录 `:140` | 多账号设备上"离线可看"不可预期；账号 A 的大视频会顶掉账号 B 的图片；账号隔离只体现在目录/键，不体现在配额 | 配额分为"账号内配额 + 全设备硬上限"，淘汰只在同账号命名空间内进行；跨账号兜底淘汰需显式策略与日志 |
| P1-2 | P1 | 发送方视频本地回读登记的是**相册原文件**，不是实际发送的压缩产物；注释与实现不符；相机拍摄的视频完全不登记 | 登记 `room_page.dart:1705-1715`（`photo.localVideoFile`）、定义 `device_gallery_source.dart:572`（`asset.originFile`）；注释声称压缩产物 `room_page.dart:1710-1711`、`sent_video_local_registry.dart:5-8`；相机路径 `room_page.dart:1888-1898` | 发送者点开自己的视频可能播放与对方不同的版本（4K 原片，解码/内存压力大），或直接失败；"零下载"承诺只在相册视频上成立 | 登记"转码产物 + 生命周期"（当前产物在 `prepared_chat_video.dart:39-45` 被删除，需要改为所有权转移/引用计数），或登记时同时记录该消息对应的对象摘要 |
| P1-3 | P1 | 封面抽帧默认首采样点是 `0ms`，且 `0ms` 直接返回、跳过近黑帧判定；与文档声明的"多时间点 + 黑帧跳过"不一致 | `video_poster_extractor.dart:20`（默认 `[0, 200, 500, 1000]`）与 `:30`（`if (positionMs == 0) return bytes;`）；注释声明 `:13-14`；对比 `device_gallery_source.dart:682-695` 的候选点 `[200,500,1000,2000]` | 片头黑场视频仍会拿到黑封面——正是注释里声称已修复的问题；两个抽帧入口候选点不一致 | 默认候选点与 `samplePositionsFor` 对齐，去掉 `0ms`，或对 `0ms` 同样做亮度判定 |
| P1-4 | P1 | 朋友圈九宫格用**原图 URL 全尺寸解码**到 90/180px 单元格（无 `ResizeImage`/`cacheWidth`） | `ui/moments/wechat_moment_image_grid.dart:67-86`（`Image(image: MomentMediaCache.imageProvider(...), width: size, height: size)`） | 每张 ≤500KB 的图解码为全分辨率位图，9 图一条 = 数千万像素；低端机 OOM/掉帧风险 | 与聊天一致引入 `ResizeImage`/`cacheWidth`，或让服务端下发网格专用小图 |
| P1-5 | P1 | `video_first_frame_cache` 无配额、无淘汰、不随账号清理 | `device_gallery_source.dart:716-724`；账号清理只删 `chat-media/v2/<account>`（`media_cache.dart:89-101`） | 长期使用后 Documents 目录无限增长；换账号后旧账号帧仍在 | 纳入账号命名空间与统一配额；或改为受限 LRU（保留现有 `ignoreCache` 损坏恢复入口） |
| P1-6 | P1 | 群公告图片上传不经 `cacheOutgoingMedia`，发送端没有本地对象；公告图与聊天图各一套演绎版（SDK `generateThumbnail`） | `group_announcement_service.dart:208-227` | 公告发布后本机无对象可复用，再次渲染需重新下载；同类图片在不同功能里参数不一致 | 统一走 `MediaService.publish`（含本地保留与统一缩略图策略） |
| P1-7 | P1 | 出站媒体在发送链路上存在多份内存副本（prepared 字节 → snapshot → isolate（`compute`）→ SDK 原生拷贝） | `matrix_e2ee_client.dart:3935`（构造时 `Uint8List.fromList`）、`:3961,4106`（`_takeBytes`/take）、`content_addressed_media.dart:144-147`（`compute`）、`matrix_e2ee_client.dart:6142-6144` 的注释（SDK 原生再拷贝） | 20MB 视频峰值内存可达 60–80MB，低内存机型并发发送（`mediaSendConcurrency = 3`，`media_message_service.dart:20`）时风险叠加 | 减少值拷贝（`Uint8List` 直接传递 + 只读视图），发送并发与"预留字节"预算联动（`matrix_e2ee_client.dart:4715` 已有预留字段可复用） |
| P2-1 | P2 | 两条并行预览管线：新消息走 `MediaCache`（内容寻址），legacy 消息走 `RoomImagePreviewCache` → 加密预览存储 | `room_page.dart:1535-1591`；`room_image_preview_cache.dart`；`emoji_preview_cache.dart:132-137` | 键与生命周期不同、同一图可能两处各存一份；测试与心智负担 | 由 `MediaService.resolve` 统一，legacy 兼容逻辑收敛为"迁移器"（现有 `_MomentMediaCacheManager._migrateFile` 已是可参考范式，`ui/moments/moment_media_cache.dart:246-279`） |
| P2-2 | P2 | GIF 无缩略图，预览即整图（上限 20MiB / 400 万像素），且 `_isAnimatedImage` 每次都从内存缓存取字节嗅探 | `media_thumbnail.dart:32`、`chat_image_preview.dart:12-22`、`room_page.dart:1513-1517`、`gif_image_policy.dart:3-4` | 大 GIF 首屏流量与解码内存偏高；嗅探会顺带把字节读进内存缓存 | 为 GIF 生成静态首帧缩略图（保留原动画作为"查看原图"），并把格式判定移到事件元数据 |
| P2-3 | P2 | `VideoPosterCell` 的可见性检测是空实现，离屏不会暂停/降优先级 | `ui/chat/video_gif_cells.dart:305-320`（注释自述"简化实现：始终可见"） | 网格里离屏视频仍可能保持负载 | 接入真实可见性（`VisibilityDetector`/滚动通知）并与 `MediaLoadPriority` 联动 |
| P2-4 | P2 | 头像缓存与聊天/朋友圈缓存分属三个 CacheManager，无法互相命中；头像键不含尺寸（有意为之） | `ui/foundation/avatar_cache.dart:13-23,47-58`；`ui/moments/moment_media_cache.dart:50-62`；`media_cache.dart:140` | 同一账号头像/图片在不同域各下载一次 | 由门面对接同一 HTTP 缓存层（头像仍保持"尺寸不入键"的既有约定） |
| P2-5 | P2 | 相册网格缩略图缓存无字节上限（仅 96 条），并发解码 3 条 | `device_gallery_source.dart:437-439,102,454-459` | 极端宽高比缩略图可占较多内存（200px 量级，风险有限） | 补字节预算或与共享预算联动 |
| P2-6 | P2 | "缩略图优先"渲染有两份实现：`EncryptedImageMessage`（仍有 widget 测试）已不在房间页使用，生产走 `ContainImageBubble` | 定义 `ui/chat/encrypted_media_view.dart:44-146`（缩略图优先逻辑 `:85-92`，固定 200×150 `:65-66,131-134`）；替换说明 `room_page.dart:3540-3542`；生产使用 `room_page.dart:3186,3548` | 行为/参数漂移风险（固定尺寸 vs contain 布局），测试覆盖的是死代码路径 | 删除或明确标注为已弃用，并把其测试迁移到 `ContainImageBubble` |

---

## 附录 A：未确认清单

| # | 未确认项 | 缺失的证据 |
| --- | --- | --- |
| A1 | **服务端是否按内容哈希对媒体 blob 去重**（Synapse 媒体库 / 业务 API 朋友圈媒体） | 仓库内只有 Flutter 客户端与业务 API 调用点；无服务端媒体库实现或接口契约证据。客户端侧可确认的是：确定性加密使同明文 → 同密文（`content_addressed_media.dart:136-174`），协议上具备内容寻址条件 |
| A2 | **Matrix SDK 内部是否在 `sendFileEvent` 上传前按摘要复用已上传的 `mxc://`** | 客户端只把 `preEncrypted` 的 `MatrixFile` 交给 SDK（`matrix_e2ee_client.dart:6278-6283`），SDK 源码不在本仓库读取范围内 |
| A3 | **SDK 本地数据库对 `downloadAndDecryptAttachment` 下载物的落盘策略与淘汰**（条目上限/TTL/清理点） | 只能确认 `MatrixSdkDatabase` 是本地库（`matrix_client_factory.dart:424-435`）且 Emoji 路径会按键取文件（`matrix_e2ee_client.dart:3240`）；SDK 内部实现未读 |
| A4 | **`diskHardQuotaBytes` 淘汰在真实设备上的实际触发频率与单账号分布** | 需要运行期数据（需执行构建/测试或抓取生产指标，本次为只读审计未执行） |
| A5 | **朋友圈服务端下发的 `image_cache_keys` 是否恒等于内容摘要** | 客户端只按 `^[a-f0-9]{64}$` 形状校验（`ui/moments/moment_media_cache.dart:71-72`），无法证明其语义等于字节 sha256 |
| A6 | **`matrix_e2ee_client.dart` 行号的最终稳定性** | 审计期间该文件被并发修改（6397 → 6447 行），本文件中所有引用均为写入时刻所读内容；若该文件再次变更，请以函数名/字符串为准重新定位 |
| A7 | **"原图"开关下 20MiB 上限与服务端上限是否一致** | 客户端有 `maxGalleryImageBytes = 20 * 1024 * 1024`（`gallery_media_payload.dart:8`）与 `_maxFileSendBytes = 100 * 1024 * 1024`（`matrix_e2ee_client.dart:70`）两个不同上限，服务端侧限制未在本仓库 |

## 附录 B：本次审计的证据读取清单（按文件）

`apps/mobile_flutter/lib/` 下实际读取（非猜测）的文件：`features/matrix/{media_cache,content_addressed_media,media_thumbnail,media_message_service,matrix_media_file,matrix_e2ee_client,outgoing_media_thumbnail_cache,room_image_preview_cache,video_poster_disk_store,video_poster_extractor,video_poster_session_cache,video_send_stage,video_transcode,prepared_chat_video,sent_video_local_registry,gallery_media_payload,room_media_gallery_projection,media_load_scheduler,media_memory_budget,attachment_upload_controller,device_gallery_source,gallery_video_preview,image_picker_page,chat_image_preview,media_consumer_scope,media_renderer_binding,media_message_access_policy,avatar_url_resolver,emoji_preview_cache,group_announcement_service,room_page,matrix_client_factory}.dart`、`features/moments/{moment_image_preprocessor,moment_preview_cache,moment_composer_page,moment_models}.dart`、`ui/chat/{budgeted_media_image,encrypted_media_view,wechat_video_message,video_gif_cells,shared_video_playback,contain_image_bubble,media_activity,room_image_gallery}.dart`、`ui/moments/{moment_media_cache,moment_image_provider,wechat_moment_image_grid,moment_image_prefetcher}.dart`、`ui/foundation/{avatar_cache,retained_image_cache_manager}.dart`、`core/{cache/cache_repository,media_resource_policy,app_config,business_api_client,session_bootstrap_controller}.dart`、`main.dart`。
