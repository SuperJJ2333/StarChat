# ChatFlow Media + Quote + Image Editor Optimization Report

- 日期：2026-09-17（Asia/Hong_Kong）
- 仓库：`SuperJJ2333/StarChat`（本地工作树，基线 `81d9e612`，`main`）
- 范围：Flutter 客户端 `apps/mobile_flutter` + HTML 设计演示 `frontend/`
- 本次**未**构建 APK/IPA、**未**安装真机、**未**部署服务端、**未** push（用户明确本次不需要）
- 禁止事项遵守情况：未改 Matrix 协议层、未改 E2EE 加密逻辑、未改登录/好友/群聊协议、未改消息事件格式、
  未删除任何既有缓存机制、未用「清空缓存/重新下载」解决问题、未用 `Future.delayed` 掩盖加载问题、
  未 `catch` 全吞异常（失败一律发布成用户可见状态）

---

## 1. 媒体架构审计

完整审计报告：`docs/verification/2026-09-17-media-architecture-audit.md`（330 行，含图片/视频全链路、
四层缓存表、去重现状、目标 `MediaService` 架构、P0/P1/P2 清单与「未确认」附录）。

### 1.1 图片链路（哪一步压缩 / 哪一步缩略图 / 多版本 / 重复存储）

| 环节 | 事实 | 证据 |
| --- | --- | --- |
| 压缩（聊天正文） | photo_manager `thumbnailDataWithSize(1280×1280, quality: 80)`；GIF 与"原图"开关绕过 | `device_gallery_source.dart` `_readImage` |
| 压缩（朋友圈） | `MomentImagePreprocessor`，最长边 ≤1080px、质量阶梯 `[85,70,55]`、目标 ≤500KB | `moment_image_preprocessor.dart` |
| 缩略图 | **发送前由客户端生成**：`buildChatImageThumbnail`，最长边 ≤800px、≤100KB、质量阶梯 `[75,60,50,40]` | `media_thumbnail.dart:8-9,29-69` |
| 多版本 | 是。一次聊天图片发送最多 **2 份上传**（正文 + `info.thumbnail_file` 缩略图）；朋友圈只有 1 份（无缩略图） | `room_page.dart` 发送分支 |
| 重复存储 | 本地对象库**已内容寻址**（`objects/<sha256(bytes)>` + `refs/*.ref`），同字节跨房间合并；但正文/缩略图是两套字节，且出站预览会再落一份加密预览文件 | `media_cache.dart:301-319`、`room_image_preview_cache.dart:83-95` |

### 1.2 视频链路

| 问题 | 结论 | 证据 |
| --- | --- | --- |
| 是否先加载封面 | 是。新消息（事件带 `thumbnail_sha256`）只下载小图；**缺缩略图时为了封面会下载并解密整段视频** | `room_page.dart` `_loadVideoPoster` trusted 分支 → `resolveCachedVideoFile` + `extractVideoPoster` |
| 触发时机 | `VideoMessageCard.initState` 立即请求，无可见性门控 | `wechat_video_message.dart` |
| 是否渐进加载 | 否。没有 Range/边下边播，播放器只接受完整本地文件 | `media_cache.dart` `resolveCachedVideoFile`、`VideoPlayerController.file` |
| 是否重复下载 | 常规路径否（磁盘命中零下载、内存/网络 flight 合并）；封面兜底等于一次整文件下载 | `media_cache.dart` |
| 是否缓存视频文件 | 是，落 `{docs}/chat-media/v2/<sha256(account)>/objects/`，软 384MiB / 硬 512MiB 配额、按 mtime LRU | `media_cache.dart:19-20,383-402` |

### 1.3 当前缓存层级（摘要）

| 层 | 存什么 | 生命周期 | 淘汰 | 上限（原文常量） |
| --- | --- | --- | --- | --- |
| Memory | 已验证编码字节（图/视频/GIF/预览） | 进程内；房间 dispose / 账号清理 / 内存压力 | LRU + 字节预算 + 条目上限 | `MediaMemoryCache` 48 条 / 64MiB；共享预算 512 条 / 32MiB；视频 6 条 / 32MiB；房间预览 256 / 64MiB |
| Disk（自管明文对象） | 解密后的图/视频/语音/文件 | 账号清理 / 配额淘汰 | mtime 最旧优先 | 软 384MiB / 硬 512MiB，**全设备共享（跨账号）** |
| Disk（加密预览） | 聊天缩略图预览、Emoji 预览（AES-GCM） | 账号清理 / 逐键删除 | mtime 删到 64MiB | 64MiB |
| Disk（视频封面临时） | 视频封面帧（AES-GCM，密钥仅内存） | 房间页 dispose | **无配额** | 注释明示 "No quota eviction" |
| Disk（相册首帧） | 相册视频首帧 JPEG | 进程内表 + 磁盘 | **无配额、不随账号清理** | 无 |
| Disk（第三方 CacheManager） | 朋友圈图、头像 | TTL + LRU | CacheManager | 朋友圈 7 天 / 200；头像 30 天 / 500 |
| Database | Matrix 事件/房间状态/会话（SQLCipher） | 随本地库 | SDK 自管（未确认） | 未确认 |
| Remote | Synapse 媒体库（每事件一个 `mxc://`）、业务 API 朋友圈媒体 | 服务端 | 未确认 | 客户端无远端去重契约 |

### 1.4 去重结论（同一文件 A：聊天 + 朋友圈 + 群）

- **本地**：`sha256(bytes)` 对象库让"同一份字节"只占一个物理文件，跨房间/跨消费者有效；但正文/缩略图/预览
  仍是不同字节或不同存储层，磁盘上仍有 2–3 份。
- **远端**：客户端**没有任何上传前去重**；聊天/群走 SDK `room.sendFileEvent`，朋友圈走业务 API
  `/moments/media/uploads/{id}/content`，两套完全独立的存储 → 至少 3 次上传、3 份远端副本。
- **重要事实**：媒体加密是**确定性**的（密钥/nonce 由 `sha256(plaintext)` 经固定域 HKDF 派生、计数器固定为零），
  即"同明文 → 同密文"，因此服务端**有内容寻址去重的技术前提**；但服务端是否真的按内容哈希合并，仓库内**无证据（未确认）**。
- **跨域去重的根本障碍**：聊天 1280/q80、朋友圈 ≤1080px、原图是不同字节，即便服务端内容寻址也命中不了。
  真正可落地的第一步是**客户端演绎版归一** + **上传前按 `content_sha256` 查重**（需要服务端只读查重接口）。

### 1.5 目标架构（本阶段只设计，不实现）

`MediaService` 门面统一 图片/视频/文件/头像，消费者为 Chat / Moments / Avatar / File：

```dart
abstract interface class MediaService {
  Future<MediaHandle> resolve(MediaRequest request, {MediaLoadPriority priority});
  Future<MediaUploadResult> publish(MediaPublishRequest request);
  Future<void> release(MediaRef ref);              // 引用式回收（替代各自删文件）
  Future<void> clearAccount(String accountId);     // 唯一账号清理入口
}
```

内部复用现有件：`MediaCache`（对象库/引用/配额）、`MediaMemoryBudget`、`MediaLoadScheduler`、
`MediaEnvelope`（确定性加密信封，**保持不变**）、两条 `MediaGateway` 出口。
迁移顺序：① 只做门面（委派，不改行为）→ ② 统一演绎版参数表 → ③ 引用计数与配额解耦（配额内加"账号内配额"）
→ ④ 删除入口收敛 → ⑤（需服务端）远端内容寻址与上传前查重。

### 1.6 优先级清单（审计产出，P0 未在本次修复）

| 级别 | 问题 | 影响 |
| --- | --- | --- |
| **P0-1** | 磁盘缓存**每次命中**都对整个对象重算 SHA-256（先比 `.len`，随后仍全量流式哈希） | 50–100MB 视频"命中"= 重读+哈希整个文件才起播 |
| **P0-2** | 缺缩略图的视频会**为了封面下载整段视频**，且触发点在列表构件 `initState`、无可见性门控 | 旧消息滚动 = 整段视频下载 |
| **P0-3** | 同源文件跨域产出不同演绎版 + 远端零去重 → 同一文件 ≥3 次上传、3 份远端副本 | 流量/服务端存储/本地磁盘三重放大 |
| **P1-1** | 磁盘配额**全设备共享**，枚举整棵 `chat-media`（含其他账号），A 账号写入可淘汰 B 账号对象 | 多账号设备"离线可看"不可预期 |
| **P1-2** | 发送方视频本地回读登记的是**相册原文件**而非发送用的压缩产物；相机拍摄视频不登记 | 发送者点开自己的视频可能播放 4K 原片 |
| **P1-3** | 封面抽帧默认首采样点 `0ms` 且 `0ms` 直接返回、跳过近黑帧判定 | 片头黑场视频仍拿到黑封面（与注释声明不符） |
| **P1-4** | 朋友圈九宫格用原图 URL **全尺寸解码**到 90/180px 单元格 | 9 图一条 = 数千万像素，低端机 OOM 风险 |
| **P1-5** | `video_first_frame_cache` 无配额、无淘汰、不随账号清理 | Documents 目录无限增长 |
| P2-1..6 | 两条并行预览管线、GIF 无缩略图、`VideoPosterCell` 可见性空实现、头像/聊天/朋友圈三个 CacheManager 不互通、相册网格缓存无字节上限、`EncryptedImageMessage` 已是死代码但仍有测试 | 维护成本与漂移风险 |

> **本阶段刻意不改**：任务要求「不要一次重构 Media Engine」，且 P0-3 的远端去重需要服务端接口配合；
> 因此本次只输出审计 + 方案 + 优先级，媒体侧**未做行为改动**。

---

## 2. 当前问题（本次修复的两个）

### 2.1 引用消息永久 loading

- 现象：引用原消息距离过远时，引用卡片永久显示「原消息加载中」，不会失败、不会重试。
- 根因（三处叠加）：
  1. 引用卡片摘要只查 `RoomTimelineController.findMessage(target)`（即当前 timeline 窗口 + SDK 窗口源），
     **窗口外没有第二条解析路径**；
  2. 没有任何加载状态机：只有"命中/未命中"二值，未命中就渲染 `'原消息加载中'` 字面量，**缺少超时**；
  3. 唯一的远端补路径在**点击**时（`_scrollToMessage` 的 `openAnchor` + 反复 `_loadEarlier`），
     卡片本身从不触发它，且失败只弹一次 toast。

### 2.2 相册大图缺「编辑」，裁剪交互不符合微信

- 相册大图预览（`image_picker_page.dart` 的 `_GalleryPreviewPage`）底部只有「选择」「闪照」，没有「编辑」入口。
- 图片编辑器（`wechat_image_editor.dart`）的裁剪是「**拖动画面框选一个矩形**」：
  进入裁剪时没有裁剪框、默认是"空白 + 提示拖动选择"、只有一条细白线、没有任何控制点/遮罩，
  应用裁剪按钮是裸文字按钮且从属于一行提示，视觉极弱；也没有还原、比例、旋转。

---

## 3. 引用消息修复方案

### 3.1 五态状态机（不再只有 `loading=true`）

`apps/mobile_flutter/lib/features/matrix/reply_message_resolution.dart`

```dart
enum ReplyMessageStatus { loading, loaded, notFound, permissionDenied, networkError }
```

| 状态 | 卡片文案 | 可重试 |
| --- | --- | --- |
| `loading` | 原消息加载中…（带小转圈） | — |
| `loaded` | `显示名：摘要`（图片/视频/语音/文件各有摘要） | 点击=跳转 |
| `notFound` | 原消息不存在或已被删除 | 是 |
| `permissionDenied` | 无权查看原消息（服务端权威 403/404 结论） | **否**（重试无意义） |
| `networkError` | 原消息加载失败，点击重试 | 是 |

`ReplyMessageResolver` 的编排约束：

- **单飞**：同一 `eventId` 并发请求共享同一个 future，N 行引用同一目标只发一次请求；
- **超时**：默认 **3 秒**（`ReplyMessageResolver.timeout`，有测试断言默认值）后进入 `networkError`，绝不无限 loading；
- **终局缓存**：成功/失败都记住（有界 LRU，仅淘汰终局项），重复渲染不再发请求；
- **不吞异常**：`ReplyMessageLookupDenied` → `permissionDenied`，`ReplyMessageLookupUnavailable`/超时/`StateError`/其它
  `Exception` → **发布**成 `networkError`（用户可见 + 可重试）；真正的编程错误（`Error`，如 `ArgumentError`）继续抛出，
  不被伪装成"加载失败"。

### 3.2 三级解析链路（本地 timeline → 本地加密库 → 服务器）

新增可选能力 `RoomMessageLookupSource`（`room_timeline_controller.dart`），由 `MatrixRoomTimelineAdapter`
转发到 `_SdkRoomTimelineCapability.lookupMessage`：

```
controller.findMessage(eventId)                        // ① 本机 timeline / 窗口源
  └─ 未命中 → MessageTimelineCache.lookup(account, room, eventId)   // ② 进程级已解析缓存
       └─ 未命中 → _timeline.getEventById(eventId)     // ③ SDK：timeline 事件 → timeline 缓存
                                                       //        → 本地加密库 → 服务器单事件查询 + 解密
            └─ 成功 → RoomMessageViewModel（投影）→ 写回 ② + 控制器已解析表 → refresh() → 卡片更新
```

- `Timeline.getEventById` 是 SDK 公开 API，语义正是「本地优先、未命中才走服务器，并解密」，
  所以第 ③ 步**一次往返**即可恢复 1000 条以前的引用目标，而不是从窗口顶端逐页翻历史（旧实现是 O(页数)）。
- 错误映射：`MatrixException.errcode` 为 `M_FORBIDDEN`/`M_UNAUTHORIZED` → `ReplyMessageLookupDenied`；
  其它 `MatrixException`/`SocketException`/`TimeoutException` → `ReplyMessageLookupUnavailable`。
- 适配器未实现该能力时（`supportsMessageLookup == false`，例如旧 fake/旧适配器）回退到**有界**历史分页
  （`replyHistoryPageBudget = 2` 页），绝不无限拉历史。

### 3.3 缓存要求与一处**有意的偏离**

- **`MessageTimelineCache`（新增，`message_timeline_cache.dart`）**：进程级、按
  `<accountId>:<roomId>:<eventId>` 隔离、256 条 LRU。用途：重新进入会话/切换窗口后引用卡片立即命中。
  **只存内存、绝不落盘**——Matrix 明文只允许存在于设备内存与 SDK 的加密本地库（SQLCipher）中；
  把解密正文写进 SharedPreferences 会削弱 E2EE 保证。
- **「Room local database」这一项有意未做写回**：SDK 的本地加密库里，事件写入只有
  `DatabaseApi.storeEventUpdate`，而它对 `timeline` 类型做 `eventIds.insert(0, ...)`（插到**最新**位置）、
  对 `history` 类型做 `eventIds.add(...)`（追加到**末尾**）。这两种语义都会破坏本地 timeline 顺序，
  而 SDK 没有暴露"只按 eventId 覆盖单条事件、不动 timeline 片段"的公开 API。
  因此本次**不**手工插入 SDK 事件库（那会制造更难排查的数据损坏），改为：
  ① 读路径走 `Room.getEventById`（本地加密库优先，天然复用历史同步已落库的事件）；
  ② 会话内核 `_resolvedMessages` + 进程级 `MessageTimelineCache` 承担"避免重复请求"；
  ③ 在报告中把这一偏离与原因写清楚（见第 10 节）。
- **清空聊天记录**时会同时丢弃引用解析投影（`controller.clearResolvedReplyTargets()` + `replyResolver.clear()`），
  避免清空后引用卡片仍展示已不可见的内容。

### 3.4 渲染与回归安全

- 引用卡片抽成公共组件 `lib/ui/chat/quote_preview_card.dart`（`QuotePreviewCard`，保留
  `Key('reply-preview-<eventId>')` 兼容既有测试），并把行缓存 key 扩成
  `(message, previous, reply, status, row)`——状态变化一定触发重建，不会因为 `reply == null`
  而命中旧缓存继续显示 loading。
- 首帧扫描：`_visibleMessages()` 里只做只读判定，真正的解析请求放到**帧后**执行
  （`_scheduleReplyResolutionSweep`，每帧最多一批、`_replySweepScheduled` 去重），避免在 build 期间触发
  `_timelineRevision` 变更。
- 引用摘要优先级：`replyExcerpt`（局部引用选中的片段）> 已解析原消息摘要 > 失败文案。

---

## 4. 相册编辑修改

### 4.1 编辑入口（相册大图）

`_GalleryPreviewPage` 底部操作改为一行三枚同风格胶囊：**编辑 → 选择 → 闪照**（顺序有测试断言），
三枚共用新的 `_GalleryPreviewAction`（选中态用品牌色，其余深色半透明），键名保持
`gallery-preview-edit` / `gallery-preview-select` / `gallery-preview-flash` 不变。

点击「编辑」：

1. 取**原图字节**（`photo.originalBytes()`；不可读时回退已展示的预览字节），失败时显示
   「图片打开失败，请重试」而不是静默无反应；
2. 进入 `WeChatImageEditorPage`，新增 `onSend` 动作（完成菜单第一项「发送」）；
3. 导出 PNG 后以 `editedGalleryPhoto(bytes)` 包装成**新的 `GalleryPhoto` 媒体对象**，
   由选择器正常返回（`(photos: [edited], original: true, flash: false)`），
   复用既有上传/发送管线；
4. 设备上的原照片与消息里的原媒体对象**都不被覆盖**（有测试断言原 `GalleryPhoto` 字节不变）。

### 4.2 裁剪交互重做（微信级）

`lib/ui/chat/image_crop_geometry.dart`（纯几何，独立单测）+ `wechat_image_editor.dart`（交互/渲染）

| 要求 | 实现 |
| --- | --- |
| 进入裁剪：图片完整铺满编辑区域 | 画布改为占满整个编辑区域，图片按 `BoxFit.contain` 居中适配（`viewBox`）；绘制/手势统一走 `_toImage` 映射 |
| 裁剪框默认**覆盖整个图片**（不是固定小框） | 进入裁剪/应用裁剪/旋转/布局变化后，`_cropFrame = viewBox`（有像素级测试断言 ≥95% 面积） |
| 四边 + 四角拖动 | `ImageCropGeometry.handleAt` 命中 8 个位置（角优先于边，24px 容差）；`resize` 只动被拖的边，最小边长 56，夹在图片矩形内 |
| 明显边框 | 1.5px 亮白描边 + 三分参考线（有像素测试：边框行亮度 > 0.85） |
| 四角控制点 | 四角各画两条 3.5px 白色折线，拖动中变品牌色高亮，松手恢复（有测试） |
| 半透明遮罩 | 裁剪框外四块 60% 黑色遮罩（有像素测试：框外亮度 < 0.7，框内 > 0.9） |
| 拖动提示 | 裁剪工具条常驻文案「拖动边框或四角调整裁剪范围，双指缩放 / 拖动画面」 |
| 放大 / 缩小 / 移动图片 | 单指在框内=平移、双指=以手势焦点为锚缩放（`viewScale ∈ [1,8]`），图片始终盖住适配矩形（`_clampCenter`） |
| 保持比例 / 自由裁剪 | 比例预设「自由 / 1:1 / 4:5 / 16:9」；固定比例时以对侧锚点套用比例并夹在图片内 |
| 旋转（还原要能复位） | 裁剪工具条「旋转」按 90° 递增；旋转把**裁剪框与标注一起**映射到新文档空间（标注仍贴原图同一处），可撤销/重做 |
| **还原** | 一键回到：原始图片状态（清空全部标注与裁剪）、默认裁剪框、默认缩放（1）、默认旋转（0） |
| **应用裁剪** | 裁剪框（视图）经 `toImageRect` 映射回图像像素，生成**新文档**；原图字节不动 |
| 按钮同风格 | 新公共组件 `ImageEditorActionButton`：高度 44、圆角 8、左右各一个 `Expanded` + 12pt 间距，`还原` 为描边半透明、`应用裁剪` 为品牌色填充 + 按压高亮（有测试断言高度/宽度/圆角/间距/填充色） |

### 4.3 安全性

- 编辑全程在内存临时缓冲中进行，导出产生**新的 PNG 字节**；`取消` 直接返回，不产生任何持久副作用
  （有专门测试：取消后原字节不变、无任何回调被触发）。
- 未改任何 Matrix 事件格式、未上传任何明文；编辑结果仍走原有加密上传管线。

---

## 5. 修改文件

| 文件 | 变更 |
| --- | --- |
| `apps/mobile_flutter/lib/features/matrix/reply_message_resolution.dart` | **新增**：五态状态机 + `ReplyMessageResolver`（单飞/3s 超时/终局缓存/不吞 Error） |
| `apps/mobile_flutter/lib/features/matrix/message_timeline_cache.dart` | **新增**：进程级、按账号+房间隔离、256 条 LRU、**仅内存**的引用投影缓存 |
| `apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart` | 新增 `RoomMessageLookupSource`/两枚失败异常；`findMessage` 增加已解析目标回退；新增 `lookupReplyMessage`（单事件查询 + 有界分页回退）；`forget/clearResolvedReplyTargets` |
| `apps/mobile_flutter/lib/features/matrix/matrix_room_timeline_adapter.dart` | 转发 `supportsMessageLookup`/`lookupMessage` |
| `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart` | `_SdkRoomTimelineCapability` 实现单事件解析（SDK `Timeline.getEventById` → 加密库→服务器）、错误分类、`_resolvedMessages` + `MessageTimelineCache` 写入 |
| `apps/mobile_flutter/lib/features/matrix/room_page.dart` | 引用卡片改用 `QuotePreviewCard` + `ReplyMessageResolver`；帧后解析扫描；行缓存纳入状态；清空记录时丢弃投影；删除内联 `_QuotePreview` |
| `apps/mobile_flutter/lib/ui/chat/quote_preview_card.dart` | **新增**：引用卡片（五态 + 摘要 + 重试/跳转分流） |
| `apps/mobile_flutter/lib/ui/chat/image_crop_geometry.dart` | **新增**：裁剪框命中/拖拽/比例/夹取/视图→图像映射（纯函数） |
| `apps/mobile_flutter/lib/ui/chat/wechat_image_editor.dart` | 裁剪交互重做（默认全图裁剪框、8 控制点、遮罩、缩放/平移、比例、旋转）、新增 还原/应用裁剪、`ImageEditorActionButton`、`onSend`、`image-editor-cancel` 键 |
| `apps/mobile_flutter/lib/features/matrix/image_picker_page.dart` | 相册大图新增「编辑」入口（编辑/选择/闪照）、编辑源与错误提示、编辑结果作为新媒体对象返回 |
| `apps/mobile_flutter/lib/features/matrix/device_gallery_source.dart` | 新增 `editedGalleryPhoto(bytes)`（把编辑结果包装成可发送的相册条目） |
| `apps/mobile_flutter/test/features/matrix/reply_message_resolution_test.dart` | **新增**：21 条（状态机 + 控制器集成 + 缓存隔离 + 卡片五态） |
| `apps/mobile_flutter/test/ui/chat/image_crop_geometry_test.dart` | **新增**：12 条（命中/拖拽/最小尺寸/夹取/比例/坐标映射） |
| `apps/mobile_flutter/test/ui/chat/image_crop_editor_test.dart` | **新增**：12 条（Test1–Test6 + 像素级遮罩/边框/控制点 + 高亮 + 比例 + 旋转 + 缩放平移 + 按钮一致性） |
| `apps/mobile_flutter/test/features/matrix/gallery_preview_edit_test.dart` | **新增**：3 条（编辑入口与顺序 + 编辑→发送产生新媒体对象 + 取消无副作用） |
| `apps/mobile_flutter/test/ui/chat/wechat_image_editor_test.dart` | 更新：画布映射改走 `painter.viewBox`；裁剪用例改为拖**左上角控制点**并断言裁剪真的收进 |
| `frontend/src/components/image-editor.js` | HTML 演示同步：裁剪框/遮罩/控制点/三分线、比例与旋转、还原/应用裁剪、完成菜单「发送」 |
| `frontend/src/styles/components.css` | 新增 `.c-image-editor__crop-options/__crop-chip/__crop-actions/__crop-action`（全 token，无硬编码颜色） |
| `packages/ui-contracts/changliao-component-registry.json` | `image-editor` 组件补 `onSend` prop 与 `crop-reset` state |
| `docs/verification/2026-09-17-media-architecture-audit.md` | **新增**：媒体架构审计报告 |
| `docs/verification/2026-09-17-media-quote-image-editor.md` | **新增**：本报告 |
| `docs/workflow/tasks/2026-09-17-media-quote-image-editor.md` | **新增**：任务记录 |
| `docs/workflow/current-state.md` | 追加本次条目 |

`git diff --stat`：11 个已跟踪文件 `+1445 / −335`，另有 8 个新增文件（4 源码 + 4 测试）。
基线 commit `81d9e612`（`main`，工作树干净）。

---

## 6. 新增测试

命令：`flutter test <文件>`（工作目录 `apps/mobile_flutter`）

### 6.1 引用消息（`test/features/matrix/reply_message_resolution_test.dart`，21 条全绿）

| 用例 | 断言要点 |
| --- | --- |
| 默认超时 3 秒 | `resolver.timeout == Duration(seconds: 3)`（"绝不无限 loading"的策略被钉住） |
| **Test 1** 引用最近消息 | 本机命中即 `loaded`，`lookups` 为空、`historyCalls == 0`（不产生任何解析请求） |
| **Test 2** 引用 1000 条以前 | 构造 1000 条窗口内消息 + 窗口外目标；解析一次即 `loaded`，`lookups == ['event-old']`、`historyCalls == 0`（不走 1000 次分页），且结果并入 `findMessage` |
| **Test 3** 重启/重进会话 | 全新 controller + resolver（不共享进程内状态）仍 `loaded`；同时断言 `MessageTimelineCache` 按账号+房间隔离，未写入时不得命中 |
| **Test 4** 网络断开 | 挂起 → 超时 → `networkError` + 文案「原消息加载失败，点击重试」+ `canRetry`；网络恢复后 `retry()` 变 `loaded` |
| notFound / permissionDenied | 各有专属文案；`permissionDenied.canRetry == false` |
| 单飞 / 终局缓存 | 并发两次只发 1 次请求；重复解析不再请求 |
| 未知异常 vs 编程错误 | `StateError` → 发布成可重试失败；`ArgumentError` 继续抛出（不被吞成"加载失败"） |
| dispose 后 | 不再回调 UI |
| 控制器集成 | 不支持单事件解析的适配器回退分页且 `historyCalls <= replyHistoryPageBudget`；解析结果可被遗忘 |
| `MessageTimelineCache` | 账号/房间隔离 + 超容量淘汰最久未使用 |
| 卡片五态 widget 测试 | loading/loaded/excerpt/notFound/permissionDenied/networkError 六种渲染；失败态点击=重试、成功态点击=跳转、无权限不可重试 |

### 6.2 裁剪几何（`test/ui/chat/image_crop_geometry_test.dart`，12 条全绿）

四角优先命中、四边中点命中、框内/框外不命中；拖角改两条边、拖边只改一条边、最小尺寸、夹在图片内；
固定比例拖角（对侧锚点不动）/拖边（垂直居中）；切换比例（中心锚点、不越界）；
视图→图像坐标（整图、半幅、退化输入返回整图而不是空矩形）。

### 6.3 裁剪交互与编辑器（`test/ui/chat/image_crop_editor_test.dart`，12 条全绿）

| 用例 | 断言要点 |
| --- | --- |
| **Test1** 默认裁剪框 | `selection` 与 `viewBox` 四边一致、面积 ≥95%、`viewScale == 1`、`viewOffset == 0` |
| 遮罩/边框/控制点（像素级） | 渲染 painter 后采样：框内亮度 >0.9、框外 <0.7、左边框 >0.85、左上角控制点 >0.95 且明显亮于同一条边上的非角点 |
| 拖动中高亮 | 拖动中 `activeHandle == topLeft` 且采样为品牌色；松手后 `activeHandle == none` |
| **Test2** 拖四角 | 左上角 (+60,+40) 只改左上；右下角 (−50,−30) 只改右下 |
| **Test3** 拖四边 | 上边下移 45 只改上边；左边右移 55 只改左边 |
| **Test4** 还原 | 拖框 + 旋转 + 双指放大后点还原：`rotation == 0`、`crop == 原图全幅`、`marks` 清空、`viewScale == 1`、`viewOffset == 0`、裁剪框回到默认 |
| **Test5** 应用裁剪 | 裁剪框收进后应用：`document.crop` 变小且左上偏移；导出 PNG 尺寸 ≈ 预期裁剪像素；`source` 字节与副本完全相等（原图保持） |
| **Test6** 取消 | 退出编辑器回到宿主、`onForward`/`onSend` 均未被调用、原字节不变 |
| 比例 / 旋转 / 缩放平移 | 1:1 → 16:9 比例断言；自由裁剪不再强制比例；旋转 1→2 且还原回 0；双指放大 `viewScale > 1.4` 且可拖动改变 `viewOffset` |
| 按钮一致性 | 两按钮尺寸完全相等、`height == ImageEditorActionButton.height`、圆角一致、间距 12、左右留白一致、应用裁剪为填充色且与还原不同 |

### 6.4 相册编辑入口（`test/features/matrix/gallery_preview_edit_test.dart`，3 条全绿）

1. 相册 → 点缩略图右半区进大图 → 三枚操作存在且 **x 坐标递增（编辑 → 选择 → 闪照）** → 点「编辑」进入
   `WeChatImageEditorPage` 且工具栏可用；原图字节不变。
2. 编辑 → 完成 → 「发送」→ 选择器关闭并返回 `photos: [edited-*]`（`mimeType == image/png`、非视频、
   字节非空、`original == true`、`flash == false`），设备原 `GalleryPhoto` 的 `compressedBytes/originalBytes` 仍是原字节。
3. 编辑页取消 → 回到大图预览，三枚操作仍在，不产生任何媒体对象。

### 6.5 既有测试更新

`test/ui/chat/wechat_image_editor_test.dart`（6 条全绿）：
- 画布现在是整个编辑区域，图片按 contain 居中 → 所有"图片坐标"改为经 `painter.viewBox` 映射
  （新增 `_imagePoint`/`_viewBoxGlobal`/`_cropFrameGlobal` 辅助）；
- 裁剪用例改为**拖左上角控制点**收进裁剪框，并新增"裁剪必须真的收进（`crop.width < 100`）"的断言，
  避免交互改变后用例变成空转；
- 其余（emoji 网格居中与固定触控、转发先于导出、橡皮擦只擦标注层、撤销/重做、裁剪后像素定位）全部保持通过。

---

## 7. flutter analyze

```
$ cd apps/mobile_flutter && flutter analyze
Analyzing mobile_flutter...
No issues found! (ran in 14.4s)
```

工具链：Flutter 3.44.9 (stable) / Dart 3.12.2 / 引擎 `b9499e4c`（Windows 工作站）。

---

## 8. flutter test

| 范围 | 命令 | 结果 |
| --- | --- | --- |
| 本次新增 4 个测试文件 | `flutter test test/features/matrix/reply_message_resolution_test.dart test/ui/chat/image_crop_geometry_test.dart test/ui/chat/image_crop_editor_test.dart test/features/matrix/gallery_preview_edit_test.dart` | **48 通过 / 0 失败** |
| 受影响既有套件 | `flutter test test/features/matrix test/performance test/ui/message_bubble_anchor_test.dart`（引用链改动后回归） | **1576 通过 / 0 失败**（退出码 0） |
| 编辑器/相册既有套件 | `flutter test test/ui/chat/wechat_image_editor_test.dart test/features/matrix/scanner_gallery_test.dart test/features/matrix/image_picker_page_test.dart` 等 | **76 通过 / 0 失败** |
| **全量** | `flutter test --timeout 120s` | **3070 通过 / 0 失败（退出码 0）**（引用修复收尾改动后复跑一次，结果一致） |

前端与契约：

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| UI 契约 | `python scripts/verify_ui_contract.py` | `UI contract drift: PASS (31 components, 369 screens)` |
| HTML demo 测试 | `npm test`（`frontend/`） | **209 通过 / 0 失败**（含 `image-editor-demo`、`source-contract` 无硬编码颜色扫描） |
| 全仓门禁 | `pwsh -NoProfile -File scripts/verify.ps1` | **`Verification: PASS`（退出码 0）**——仓库策略/部署策略/模板单测/渲染冒烟/infra/getui/matrix-bot/Business API+Worker/Flutter boundary/UI 契约/API import/AST parse/Alembic head+offline upgrade/OpenAPI/Compose render 全通过 |

设计演示（HTML demo，Figma 已退役）：
- 页面/组件：`app-image-editor`（`frontend/index.html` 聊天分类 · screen id `chat/image-editor`）
- 变更可见项：裁剪框默认覆盖整图、遮罩、四角/四边控制点、三分线、比例预设（自由/1:1/4:5/16:9）、
  旋转、`还原` 与 `应用裁剪` 同风格操作条、完成菜单「发送」
- `Figma 已退役：本次变更仅更新 HTML demo（frontend/src/components/image-editor.js + frontend/src/styles/components.css，
  screen id chat/image-editor）`

---

## 9. 性能变化

> 说明：本次**没有**做真机基准测量（用户明确不需要真机测试），因此不声称任何实测毫秒数。
> 下面区分「结构性变化（可由代码与测试断言证明）」与「未测量项」。

**引用消息（结构性、已有测试覆盖）**

| 维度 | 修复前 | 修复后 |
| --- | --- | --- |
| 距离 1000 条的引用目标 | 卡片永久 loading；只有点击才尝试，最坏 O(历史页数) 次分页请求 | 卡片自动解析，`lookups == 1`、`historyCalls == 0`（Test 2 断言） |
| 请求次数 | 每次渲染都可能重复尝试 | 单飞 + 终局缓存：同一目标一次请求；重进会话命中 `MessageTimelineCache` |
| 失败可见性 | 只有一次 toast，卡片仍 loading | 3 秒内进入五态之一，失败可点击重试 |
| 首帧代价 | — | 解析请求在帧后执行；行缓存把状态纳入 key，状态不变时不重建整行 |

**图片/相册（结构性）**

- 相册大图预览的编辑入口使用**原图字节**编辑，不额外下载、不重复压缩；导出只产生一份新 PNG。
- 裁剪框/遮罩/控制点都画在同一张 `CustomPaint` 上（单层绘制，无额外 widget 子树/无动画控制器），
  拖动只是重绘覆盖层，不触发图片重新解码。
- `ImageCropGeometry` 是纯函数（无 IO、无 async），可在测试里毫秒级跑完。

**未测量项（诚实标注）**：真机上的裁剪手势帧率、大图（4096px）进入编辑器的解码耗时、3 秒超时在弱网下的
主观体感、视频封面兜底下载（审计 P0-2）的流量收益。这些都需要真机/性能剖析，本次未执行。

---

## 10. Remaining Risks

| # | 风险 | 影响 | 现状/缓解 |
| --- | --- | --- | --- |
| R1 | **未做「Room local database」写回**（刻意） | 引用目标若从未在本地加密库落库过，重启后首次仍需要一次服务器单事件查询（可接受：一次请求 + 本地缓存） | 原因：SDK 无"不动 timeline 片段、只覆盖单条事件"的公开 API，手工 `storeEventUpdate` 会把旧事件插成最新/追加到末尾，破坏本地顺序。已在第 3.3 节写明；后续若 SDK 暴露安全 upsert，可在 `lookupMessage` 成功后补写 |
| R2 | 引用解析的 3 秒超时在极慢网络下可能"过早失败" | 用户看到「加载失败，点击重试」，需要再点一次 | 失败态可点击重试（单飞 + 不缓存进行中请求）；3 秒是需求给定值，集中在 `ReplyMessageResolver.timeout` 一处可调 |
| R3 | `permissionDenied` 判定依赖 `MatrixException.errcode == M_FORBIDDEN/M_UNAUTHORIZED` | 若服务端用别的错误码表达无权限，会落到"网络失败，可重试" | 已把映射集中在一处；未做真机/服务端联调（本次不部署） |
| R4 | 裁剪「还原」是**全量还原**（清空全部标注/裁剪/旋转） | 用户的直觉可能只想还原裁剪框 | 这是需求「还原 → 恢复原始图片状态 / 默认裁剪框 / 默认缩放 / 默认旋转」的字面实现；若产品希望只还原裁剪，需要改文案或拆成两个入口（建议真机验收时确认） |
| R5 | 未在真机验证手势细节 | 双指缩放与"拖边框"的手势竞争、小屏上角控制点的可点性（24px 容差是否足够）、`minFrameSize = 56` 是否偏大 | 单测覆盖了命中/拖拽/夹取逻辑；真机手感需用户验收（用户已说明由其执行） |
| R6 | 相册「编辑 → 发送」会**替换**原本的整批选择 | 若用户已勾选多张再进大图编辑并发送，返回的是"仅编辑后的这一张" | 该行为与"编辑结果是新的媒体对象"一致且可预期；如需"追加到已选"需改选择器返回契约（本次不改，避免影响朋友圈评论/扫码两个既有调用方） |
| R7 | 审计 P0-1/P0-2/P0-3、P1-1..P1-5 均**未修复** | 视频封面兜底整文件下载、磁盘命中全量重哈希、跨域三份上传、账号间配额互相淘汰等仍然存在 | 任务明确要求本阶段只输出审计+方案+优先级；P0/P1 清单已写入审计文档，可作为下一批任务输入 |
| R8 | 审计中「服务端是否按内容哈希去重」「SDK 上传前是否按摘要复用 mxc://」为**未确认** | 无法在客户端单方面承诺"最终只存一份" | 已在审计附录 A 显式标注，需服务端/SDK 侧证据 |
| R9 | 未做端到端真机验证与真机性能测量 | 交互手感、弱网表现、大图内存峰值未验证 | 用户明确本次不需要真机测试；相关证据缺口已在第 9 节标注 |
| R10 | 未 push / 未构建 / 未部署 | 产物与远端仍为基线 `81d9e612` | 用户明确本次不需要；工作树改动完整保留在本地，便于后续审阅与提交 |
