# ChatFlow Media Engine v1 — 设计（Phase 0）

- 状态：**设计（Phase 0）**。本文件只描述目标与迁移路径；除 Phase 1 的视频加载优化外，**不包含实现**。
- 范围：Flutter 客户端 `apps/mobile_flutter`（聊天 / 群聊 / 朋友圈 / 头像 / 文件 / 视频）。
- 硬约束（用户给定，必须遵守）：
  - **不修改** Matrix 协议、E2EE 加密流程、消息事件格式、登录、好友、群聊业务逻辑、朋友圈业务逻辑；
  - **不删除**现有缓存机制、**不用**「清空缓存」解决问题、**不用** `Future.delayed` 掩盖加载问题；
  - **不大规模替换**现有媒体架构；
  - 本阶段**不做远端去重**（不改服务端存储 / 上传协议 / 加密协议）。
- 相关证据：媒体现状审计见
  [`docs/verification/2026-09-17-media-architecture-audit.md`](../verification/2026-09-17-media-architecture-audit.md)；
  Phase 1 实现与验证见 [`docs/verification/2026-09-17-media-engine-v1-phase1.md`](../verification/2026-09-17-media-engine-v1-phase1.md)。

---

## 1. 当前媒体链路

> 行号会随改动漂移，定位时以函数名/字符串为准。

### 1.1 聊天图片

```
选择图片（相册 ImagePickerPage / 拍摄 MediaMessageService.captureToFile）
  ↓
压缩（DeviceGallerySource._readImage → photo_manager thumbnailDataWithSize(1280,1280,q80)；
      拍摄走 image_picker(maxWidth:2160, imageQuality:92)；
      「原图」开关与 GIF 绕过压缩）
  ↓
生成缩略图（buildChatImageThumbnail：最长边 ≤800px、≤100KB、JPEG，质量阶梯 75/60/50/40）
  ↓
本地保留（MediaCache.store → objects/<sha256(bytes)> + refs/<sha256([roomId,eventId])>.ref；
          正文与缩略图各一份）
  ↓
加密信封（MediaEnvelope：确定性加密——密钥/nonce 由 sha256(明文) 经固定域 HKDF 派生，
          计数器固定为零；事件扩展 chatflow_media = {v, content_sha256, thumbnail_sha256}）
  ↓
上传（SDK room.sendFileEvent，正文 1 个 mxc:// + 缩略图 1 个 mxc://）
  ↓
消息事件（m.room.message + info.thumbnail_file + chatflow_media）
  ↓
下载 + 解密（downloadMediaContent / downloadMediaContentBounded → SDK downloadAndDecryptAttachment）
  ↓
缓存（内存 LRU MediaMemoryCache(48 条/64MiB) → 磁盘对象库（384/512MiB 配额、mtime LRU）
      → 房间级加密预览 RoomImagePreviewCache）
  ↓
展示（ContainImageBubble：缩略图优先，缺失回退正文；解码约束 ResizeImage(720)）
```

标注：

| 维度 | 位置 |
| --- | --- |
| **压缩位置** | 客户端发送前：`DeviceGallerySource._readImage`（相册）/ `MediaMessageService`（拍摄）/ `MomentImagePreprocessor`（朋友圈） |
| **缩略图生成位置** | 客户端发送前：`buildChatImageThumbnail`（聊天/群）；朋友圈**不生成**缩略图；视频封面见 1.2 |
| **缓存位置** | 内存 `MediaMemoryCache`（账号命名空间）；磁盘 `{docs}/chat-media/v2/<sha256(accountId)>/{objects,refs}`；房间加密预览 `EncryptedEmojiPreviewStore`；Flutter `imageCache` |
| **数据生命周期** | 内存：进程/房间 dispose/内存压力；磁盘：账号级清理（`clearLocalChatData` → `MediaCache.clearAccount`）或配额 LRU 淘汰；远端：服务端策略（客户端不可见） |

### 1.2 聊天视频

```
选择视频（相册 / 拍摄 / 文件选择器）
  ↓
压缩（transcodeForChat：H.264+AAC；normal 640×480 1.2Mbps 24fps，
      超 20MiB 或失败再 aggressive 320px/12fps 动态码率）
  ↓
生成 poster（extractVideoPoster：多时间点抽帧 + 近黑帧判定；**发送侧默认列表含 0ms**）
  ↓
上传（正文 = 压缩 mp4；poster = 缩略图附件，≤480px；两者都加密上传）
  ↓
消息展示（VideoMessageCard：封面 + 播放按钮 + 时长角标）
  ↓
播放（resolveCachedVideoFile：磁盘直读 → 内存在途去重 → 下载解密落盘；VideoPlayerController.file）
```

重点问题的**当前答案**（Phase 1 前的现状）：

| 问题 | 现状 |
| --- | --- |
| **poster 生成失败怎么办** | 发送侧失败 → 消息不带缩略图；接收侧此时会**为了封面下载整段视频并抽帧**（旧行为，Phase 1 已改）；抽帧再失败 → 占位底 |
| **是否下载完整视频** | **会**（且是旧行为最严重的问题）：事件没有可用缩略图时，`_loadVideoPoster` 走 `resolveCachedVideoFile` 把整段视频下载+解密到磁盘，只为抽一帧 |
| **是否支持 lazy load** | 部分：视频**文件**是懒加载（点开才下载）；但封面在 `VideoMessageCard.initState` 无条件触发，且没有可见性门控 |
| **是否存在重复解密** | 单次会话内不重复（`MediaCache`/`VideoPosterSessionCache` 都有在途去重 + 磁盘命中直读）；跨会话重进房间会重读磁盘（不重复解密，但会重复读盘/校验） |

### 1.3 朋友圈媒体

```
Moment 发布/浏览（MomentComposerPage / MomentsPage）
  ↓
Media API（业务 API：beginMomentUpload → PUT /moments/media/uploads/{id}/content → completeMomentUpload）
  ↓
Client Cache（flutter_cache_manager：stalePeriod 7 天 / 200 对象 / 并发 3；
              + MediaCache 对象库复用（朋友圈也走 content-addressed 对象）
              + 首页 JSON 快照（SharedPreferences）+ 分页/墓碑（SQLite））
  ↓
展示（Moments 九宫格 / MomentImageViewerPage）
```

**是否与聊天媒体共享缓存**：**部分共享**。

- **共享**：解密后的字节对象库（`MediaCache` 的 `objects/<sha256>`）——同一账号下同一份字节只占一个物理对象，跨房间/跨域可命中；内存预算也是共享的（`sharedMediaMemoryBudget`）。
- **不共享**：HTTP 层缓存（朋友圈与头像各用一个 `flutter_cache_manager` 实例，聊天/朋友圈的解密产物不走 HTTP 缓存）；缓存键、TTL/LRU 策略、账号清理注册点各不相同（朋友圈注册了 `MediaCache` 的账号清理回调，头像没有）。
- **不共享演绎版**：朋友圈 ≤1080px/≤500KB、聊天正文 1280px/q80、聊天缩略图 ≤800px/≤100KB 是三套参数 → 同一张图在不同域产生**不同字节**，即使内容寻址也无法互相命中。

---

## 2. Media Engine v1 设计

### 2.1 分层

```
                              MediaService
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
   ChatMediaConsumer        MomentsMediaConsumer       AvatarMediaConsumer
        │                          │                          │
        └──────────────┬───────────┴───────────┬──────────────┘
                       │                       │
                 MediaGateway            FileMediaConsumer
        ┌──────────────┴──────────────┐
        │                             │
  MatrixMediaGateway            BusinessMediaGateway
  (SDK sendFileEvent /           (业务 API /moments/media/*)
   downloadAndDecryptAttachment)
                       │
        ┌──────────────┴──────────────┐
        │                             │
   MediaObjectStore              MediaEnvelope
   （objects/refs/配额/LRU）       （确定性加密信封，**保持不变**）
                       │
        ┌──────────────┴──────────────┐
        │                             │
  MediaMemoryBudget             MediaLoadScheduler
  （跨消费者字节预算）            （并发/优先级/取消）
                       │
                 MediaCodecPolicy
        （每个 purpose 的压缩/缩略图/抽帧参数表）
```

设计原则：

1. **消费者只描述「要什么」**（用途、上限、可见性），不接触存储/加密/调度细节；
2. **网关是唯一出口**：Matrix 与业务 API 两条上传/下载通路，E2EE 与协议层不动；
3. **对象存储与配额只实现一次**（复用现有 `MediaCache`），消费者不得自己删文件；
4. **演绎版参数集中一张表**（`MediaCodecPolicy`），先集中、后归一；
5. **引用计数与配额解耦**：配额淘汰先跳过仍被引用的对象。

### 2.2 接口草图（Dart）

```dart
enum MediaPurpose { chatBody, chatThumbnail, momentBody, avatar, videoPoster, file }

abstract interface class MediaService {
  /// 送达并取回可用字节（内部完成：内存 → 磁盘 → 网关下载 → 解密 → 落盘）。
  Future<MediaHandle> resolve(MediaRequest request,
      {MediaLoadPriority priority = MediaLoadPriority.visible});

  /// 出站：生成缺失演绎版 + 本地保留 + 经网关加密上传。
  Future<MediaUploadResult> publish(MediaPublishRequest request);

  /// 引用式回收（替代各域自己删文件）。
  Future<void> release(MediaRef ref);

  /// 账号级清理（唯一入口，串行 + 代次围栏）。
  Future<void> clearAccount(String accountId);
}

final class MediaRequest {
  final String accountId;
  final MediaSource source;     // matrixEvent / businessUrl / localFile / avatarUri
  final MediaPurpose purpose;   // 决定演绎版与尺寸上限
  final int? maxBytes;          // 上限由调用方声明，服务内部强制
  final Object consumerScope;   // 可见性/取消/优先级
}

final class MediaHandle {
  final Uint8List? bytes;       // 小对象直接给字节
  final File? file;             // 大对象（视频）给文件
  final MediaVariantId variant;
  final bool fromCache;
}
```

### 2.3 交付物与现状的映射

| 组件 | 职责 | 现有可复用件 |
| --- | --- | --- |
| `MediaObjectStore` | `sha256` 对象库 + `.len` + `refs` 引用 + 配额 LRU + 账号命名空间 | `MediaCache`（已实现，直接复用） |
| `MediaMemoryBudget` | 跨消费者字节预算 | `media_memory_budget.dart`（已实现） |
| `MediaLoadScheduler` | 网络/解码并发与优先级 | `media_load_scheduler.dart`（已实现） |
| `MediaEnvelope` | 确定性加密信封 + `chatflow_media` | `content_addressed_media.dart`（**保持不变**） |
| `MediaCodecPolicy` | 各 purpose 的压缩/缩略图参数 | `media_thumbnail.dart`、`moment_image_preprocessor.dart`、`video_transcode.dart`（参数需归一） |
| `MediaGateway` | Matrix / Business 两条出口 | `matrix_e2ee_client.dart`、`business_api_client.dart` |
| 消费者适配器 | Chat / Moments / Avatar / File | `RoomImagePreviewCache`、`MomentMediaCache`、`AvatarCache` 收敛为适配器 |

---

## 3. 核心数据模型

### 3.1 `MediaObject`

```
MediaObject {
  media_id      : String     // 逻辑主键 = sha256(明文) 的稳定短标识（16~64 hex）
  sha256        : String     // 明文内容摘要（64 hex）
  mime_type     : String     // image/jpeg, video/mp4, image/gif ...
  size          : int        // 字节数
  width         : int?       // 图片/视频像素宽
  height        : int?       // 图片/视频像素高
  duration_ms   : int?       // 视频/音频时长
  created_at    : DateTime   // 首次入库时间（本机）
  storage_path  : String?    // 本机对象文件路径（本地视图；远端不可见）
}
```

契约要点：

- `media_id` **由内容派生**（= `sha256` 或其稳定截断），因此「同一份字节」天然只有一个
  `MediaObject`；
- 语言/时区无关：`created_at` 只用于 LRU 与诊断，不参与身份；
- **本地视图 vs 远端视图**：`storage_path` 只在本机有意义；远端身份是 `mxc://`（Matrix）或
  business media id（朋友圈），本阶段**不做**远端统一（见 §5）。

### 3.2 `MediaVariant`

同一 `MediaObject` 的不同**演绎版**（参数来自 `MediaCodecPolicy`，各自是一个独立的
`MediaObject`，由 `variant_of` 指回原始对象）：

```
MediaVariantKind {
  // 图片
  original            // 用户原始字节（"原图"开关）
  thumbnail_small     // 列表/气泡用（当前 ≤800px/≤100KB 的聊天缩略图）
  thumbnail_medium    // 大图/详情用（当前 1280px q80 的聊天正文 = 事实上的 medium）
  preview             // 全屏查看器占位（当前 720/2048 解码约束）

  // 视频
  poster              // 封面帧（≤480px）
  preview_video       // 渐进播放用短片（**当前不存在**，见 §6 差距）
  compressed_video    // 聊天实际发送的压缩演绎版（640×480 / aggressive）
  original_video      // 原始文件（发送者的相册原片）
}
```

```
MediaVariant {
  variant_id    : String          // = sha256(该演绎版字节)
  media_id      : String          // 指向原始 MediaObject
  kind          : MediaVariantKind
  purpose       : MediaPurpose    // 由哪类消费者产出
  sha256        : String
  size          : int
  width/height  : int?
  duration_ms   : int?
  storage_path  : String?
}
```

### 3.3 `MediaReference`

统一引用：把「业务对象」与「媒体对象」解耦，一个媒体可被多个业务对象引用（引用计数）。

```
MediaReference {
  media_id       : String
  business_type  : MediaBusinessType   // message | group_message | moment | moment_comment | avatar | announcement | file
  business_id    : String              // eventId / momentPostId / userId ...
  variant_kind   : MediaVariantKind    // 引用的是哪个演绎版
  created_at     : DateTime
}
```

示例（用户要求的两条）：

```
media_id=abc123  type=message  business_id=$event1        # 聊天：一条消息引用一份媒体
media_id=abc123  type=moment   business_id=moment_post_5  # 朋友圈：同字节另一处引用
```

- **引用计数**：`refcount(media_id) = |MediaReference(media_id)|`；为 0 才允许删除对象。
- 现有 `refs/<sha256([roomId,eventId])>.ref` **已经是一份**「业务对象 → 对象文件」的引用表；
  缺的是**反向索引**（对象 → 引用集合）与「有引用则不淘汰」的配额策略。

### 3.4 与当前实现的差距（本阶段只记录）

| 能力 | 现状 | v1 目标 |
| --- | --- | --- |
| 内容寻址对象 | ✅ 已实现（`objects/<sha256>`） | 保持 |
| 多账号隔离 | ✅ 已实现（`chat-media/v2/<sha256(account)>`） | 保持 |
| 配额 LRU | ✅ 已实现（384/512MiB，**全局跨账号**） | 改为「账号内配额 + 全局硬上限」 |
| 引用计数回收 | ❌ 无（只有 LRU） | `MediaReference` + 引用优先 |
| 演绎版族谱 | ❌ 无（正文/缩略图各自独立，无 `variant_of`） | `MediaVariant` + `MediaCodecPolicy` |
| 统一入口 | ❌ 无（各域各自调用） | `MediaService` 门面 |
| 远端去重 | ❌ 无 | **本阶段不做**（需后端配合） |

---

## 4. Phase 1：视频加载优化（本次唯一实现）

详细实现与验证见 [`docs/verification/2026-09-17-media-engine-v1-phase1.md`](../verification/2026-09-17-media-engine-v1-phase1.md)。
本节记录设计意图，供 Phase 2 复用。

### 4.1 旧流程（问题）

```
VideoMessageCard.initState
  ↓
posterLoader()
  ↓
事件有缩略图? ── 有 ──→ 只下载小图（≤480px）→ 显示 ✅
  │
  否
  ↓
resolveCachedVideoFile()   ← 下载 + 解密**整段视频**到磁盘
  ↓
extractVideoPoster(本地文件)  ← 解码抽帧
  ↓
显示
```

代价：首屏慢、流量浪费（一个 500MB 视频为了封面下满 500MB）、低端机（小米/红米）明显卡顿；
且 `initState` 无可见性门控 → 进入列表即全量触发。

### 4.2 新流程

```
VideoMessageCard（可见性门控：可见区域 ± 5 行 才允许请求）
  ↓
VideoPosterPipeline.resolve(mediaId)
  ├─ ① 会话内存 LRU（VideoPosterSessionCache，单飞）        → 命中即显示
  ├─ ② 会话/持久磁盘缓存
  │      · 会话层：VideoPosterDiskStore（AES-GCM 临时目录，原样保留）
  │      · 持久层：MediaCache（账号命名空间 + 内容寻址 + 配额 LRU）
  ├─ ③ 服务端 poster：事件自带加密缩略图附件（≤480px，**不是视频**）
  ├─ ④ 本地抽帧：**仅当本地已存在视频文件**（自己发的 / 已离线缓存 / 播放过）
  │      → 生成后写回 ②（"生成后更新缓存"）
  └─ ⑤ 占位图（videocam 占位底）
```

**结构性不变量**：`VideoPosterPipeline` 的构造参数里**没有任何下载入口**，因此
「为了封面下载完整视频」在类型层面不可能发生（有源码级防回归测试）。

### 4.3 缓存策略（Phase 1 落地）

| 层 | 实现 | 淘汰 | 账号隔离 |
| --- | --- | --- | --- |
| 内存 | `VideoPosterSessionCache`（32MiB / 256 条 LRU + 在途合并） | LRU（仅内存） | 键含账号；房间实例销毁即失效 |
| 会话磁盘 | `VideoPosterDiskStore`（AES-GCM，临时目录） | 会话销毁整体删除（按设计不淘汰） | 目录按进程临时目录隔离 |
| 持久磁盘 | `MediaCache` 对象库（复用） | 384/512MiB mtime LRU（既有） | `chat-media/v2/<sha256(accountId)>` |
| 服务端 | 事件缩略图附件（≤480px） | 服务端策略 | 随房间成员资格 |

磁盘缓存元数据映射（用户要求 `poster_id / size / last_access / media_id`）：

| 要求字段 | 现有承载 |
| --- | --- |
| `poster_id` | 对象文件名 = `sha256(封面字节)` |
| `size` | 同目录 `<sha256>.len` |
| `last_access` | 对象文件 mtime（`MediaCache.cached` 命中即 `setLastModified(now)`） |
| `media_id` | `refs/<sha256([roomId, eventId])>.ref` 的内容（指向对象文件名）；封面用虚拟 eventId `<eventId>#video-poster-v1` |

> 说明：**没有**新建 `cache/<account_hash>/video_poster/` 目录树，而是复用现有账号命名空间的
> 对象库（任务同时要求「不要复制新的缓存系统」「优先复用 media_cache」）。若后续需要独立目录，
> 可在同一账号命名空间内新增子目录而不改变键语义。

### 4.4 诊断

`VideoPosterDiagnostics` 只记录白名单字段（其余一律不记录）：

```
[chatflow/videoposter] id=<12hex 加盐哈希> source=server cache_hit=false generate_ms=3 decode_ms=0 download_bytes=0
```

**禁止**：视频内容/字节、媒体原始 ID、房间 ID、用户 ID、token、房间密钥。日志回调抛异常
被静默隔离（诊断不得影响封面加载）。

### 4.5 `SentVideoLocalRegistry` 审计结论（按要求：只报告，不强改）

- **确认问题**：`SentVideoLocalRegistry.register` 登记的是
  `GalleryPhoto.localVideoFile` = `asset.originFile`（**相册原片**），而不是实际发送的压缩产物；
  注释与实现不符。相机拍摄的视频完全不登记。
- **为什么不强改**：压缩产物由 `prepareLocalChatVideo` 在 `finally` 中
  `rendition.dispose()` **主动删除**（设计如此：产物归发送任务所有，成功后释放）。
  要让登记指向压缩产物，必须改动 outgoing 任务/转码产物的所有权与生命周期
  （引用计数或延迟删除），属于「不影响消息发送」红线附近的高风险改动。
- **影响**：发送者点开自己的视频会播放相册原片（例如 4K/200MB），与接收方看到的
  压缩版不同，解码/内存压力大；「零下载」承诺只在相册视频上成立。
- **后续建议（Phase 2）**：让 `MatrixOutgoingVideoFileRequest` 保留转码产物的引用
  （reference-counted，任务完成 + 发送完成后删除），并登记该文件；或登记**发送字节的
  内容摘要**，让 `MediaCache` 承载（发送字节已在 `_sendMedia` 中入对象库）。
- **一处待真机确认的疑点**：对于可信（content-addressed）消息，`resolveCachedVideoFile`
  的键含 `content_sha256`，而 `cacheOutgoingMedia` 也按同一份字节写入对象库——两者可能在
  内容寻址层已经命中，此时 `SentVideoLocalRegistry` 对**已发送**消息可能是冗余的。
  本阶段不改动，标记为待核对（真机/日志证据）。

---

## 5. 本阶段刻意不做的事（以及原因）

| 不做 | 原因 |
| --- | --- |
| 远端去重 / 服务端内容寻址 | 需要后端共同改造（存储、上传协议、查重接口）；本阶段禁止改服务端存储与上传协议 |
| 统一加密/上传协议 | E2EE 与协议层冻结；`MediaEnvelope` 保持现状 |
| 演绎版参数归一（1280 vs 1080 vs 800） | 会改变发送字节与既有测试的既有语义；需要产品/兼容性评估后单独排期 |
| 删除 `VideoPosterDiskStore` / `RoomImagePreviewCache` | **禁止删除现有缓存**；它们是会话层保护，保留 |
| 视频渐进播放（`preview_video` / Range） | 需要发送端产出短片 + 播放器改造；属 Phase 2/3 |
| 独立 `cache/<account_hash>/video_poster/` 目录 | 与「不复制新缓存系统」冲突；复用账号命名空间对象库（见 §4.3） |

---

## 6. 迁移路径（Phase 2+ 建议顺序）

1. **门面落地（纯重构）**：新增 `MediaService`，内部委派给现有 `MediaCache` /
   `loadMediaWithCache` / `resolveCachedVideoFile`；先把聊天、朋友圈、头像三处调用点改为经门面，
   行为不变、测试复用。
2. **`MediaCodecPolicy` 参数集中**：把「聊天正文 1280/q80、缩略图 800/100KB、朋友圈 1080/500KB、
   视频 640×480、封面 480、抽帧时间点」集中为一张表（先不改参数）。
3. **`MediaVariant` 族谱**：为对象库补 `variant_of` 关系与反向索引（可从现有
   `refs/*.ref` 与 `chatflow_media` 扩展重建）。
4. **引用计数与配额解耦**：配额淘汰跳过仍被引用的对象；配额从「全设备共享」改为
   「账号内配额 + 全局硬上限兜底」。
5. **删除入口收敛**：撤回 / 删除 / 账号清理统一走 `release()` / `clearAccount()`。
6. **视频渐进播放**：发送端产出 `preview_video`（低码率短片）+ 播放器先播 preview 再切正文。
7. **（需服务端）远端内容寻址与上传前查重**：需要服务端提供「按 sha256 查询/复用 blob」的只读接口。
8. **P0 收尾**：磁盘命中全量重哈希（`MediaCache._valid`）降级为后台抽样校验；跨账号配额隔离。

---

## 7. 不变量（任何阶段都不得破坏）

1. Matrix 明文只在设备内存与 SDK 加密本地库（SQLCipher）中解密；不上传明文、密钥、恢复密钥。
2. 业务 API 是身份/资金/账本权威；媒体链路的任何改动都不写入资金状态。
3. 事件格式（`chatflow_media` 扩展字段、`m.relates_to`、`info.thumbnail_file`）保持不变。
4. 现有缓存层的语义与清理路径不得削弱（可以新增，不能悄悄替换/删除）。
5. 媒体失败必须**降级为占位/占位底**并可通过诊断定位，禁止无限 loading、禁止用延时掩盖。
6. 每个阶段结束必须有：失败用例先红后绿、`flutter analyze` 无问题、全量测试通过、证据落盘。
