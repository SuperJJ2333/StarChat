# ChatFlow Media Engine Phase 3 — 服务端媒体现状审计

- **阶段定位**：Phase 3 的**第一步**（现状审计）。Phase 3 整体是 **Architecture Design Only —— 只设计，不编码**。
- **本文件性质**：只读审计报告。本次**未修改任何源码、未修改任何配置、未运行构建、未部署、未 push**。
- **日期**：2026-09-17（Asia/Hong_Kong）
- **仓库**：`SuperJJ2333/StarChat`（本地工作树，分支 `main`，基线 `81d9e612`）
- **审计范围**：服务端的媒体存储、上传链路、生命周期、权限与可复用性（Matrix / 业务 API / 头像 / 文件）。
- **配套设计**：[`media-engine-phase3-server-design.md`](media-engine-phase3-server-design.md)
- **前序阶段**：Phase 0 [`media-engine-v1.md`](media-engine-v1.md)、Phase 1 [`2026-09-17-media-engine-v1-phase1.md`](../verification/2026-09-17-media-engine-v1-phase1.md)、
  Phase 2 [`media-engine-phase2-local-index.md`](media-engine-phase2-local-index.md)、
  客户端审计 [`2026-09-17-media-architecture-audit.md`](../verification/2026-09-17-media-architecture-audit.md)、
  ADR-0060 [`docs/adr/0060-content-addressed-media-dedup.md`](../adr/0060-content-addressed-media-dedup.md)
- **未确认项**：统一登记在 §8「未确认与不确定项」，不以推测充当事实。

---

## 0. 结论速览

| 问题 | 结论 | 关键证据 |
| --- | --- | --- |
| 存储在哪里 | **两套完全独立的字节存储**：Matrix `media_store`（宿主机 bind mount）+ 业务 API 私有对象目录（另一个 bind mount），**都在同一台服务器同一块盘上，都不是对象存储，都没有 CDN** | `data/synapse/homeserver.yaml:47`；`docker-compose.yml:34,262` |
| 谁管理生命周期 | Matrix 侧 = Synapse + ChatFlow 补丁的引用表；业务侧 = 各业务表 + **内联删除**（没有 GC） | `third_party/synapse/chatflow_media_dedup.py:119-158,270-283`；`services/business-api/app/modules/identity/profile.py:365,383,427` |
| 谁负责删除 | Matrix：按 (media_id,user_id) **逻辑删除引用** + 宽限期 + 管理员 purge；业务：上传会话取消 / 头像替换 / 头像删除时**立即物理删除**，朋友圈删除**从不删除对象** | 同上一行 |
| 谁控制权限 | Matrix：房间成员资格 + access token（**无签名 URL、无过期概念**）；业务：Fernet 签名令牌（300s/7d）+ 朋友圈可见性复核 | `apps/mobile_flutter/third_party/matrix/lib/src/utils/uri_extension.dart:60-61`；`services/business-api/app/modules/moments/media_access.py:60-96` |
| 是否可复用 | **Matrix 密文层已可复用**（同密文摘要 → 同一 `media_id`，跨用户共享，已有引用模型）；**业务侧完全不可复用**（随机 UUID key，没有跨域/跨用户查重） | `third_party/synapse/chatflow_media_dedup.py:191-240`；`services/business-api/app/api/media.py:66-71` |
| 同一张图发聊天+朋友圈+头像 | **远端至少 3 个对象**（且头像还会被 worker 额外复制进 Matrix，共 4 个远端对象）；三处演绎版参数不同，字节不同 | 本文 §1.4、§2.3；`services/business-worker/app/tasks/identity.py:187-188` |
| 明文哈希是否泄露给服务器 | **聊天：不泄露**（`chatflow_media` 扩展在 Megolm 密文内）；**朋友圈/头像：服务器本来就持有明文**，头像还自行计算了明文 SHA-256（仅用于会话内冲突检查，未用于去重） | `docs/adr/0060-content-addressed-media-dedup.md:17`；`services/business-api/app/modules/identity/profile.py:279,295,302` |
| 现在能不能做"服务端媒体对象平台" | **可以，且比预期更近**：Matrix 侧已经有 `digest → media_id` + 引用表 + 宽限期 + 隔离墓碑的完整骨架；业务侧只差"内容寻址 + 引用表" | §3.1 |

---

## 1. 当前上传链路（三条链路逐一审计）

### 1.1 Chat（Matrix / E2EE）

```
Flutter Client
  │  ① 选择 → 压缩（相册 1280×1280 q80 / 原图 / GIF 原样）
  │  ② 生成本地缩略图（≤800px、≤100KB JPEG）
  │  ③ 生成确定性信封（HKDF(sha256(plaintext)) → key/IV；AES-256-CTR）
  │  ④ 事件 content 里附 chatflow_media = {v:1, content_sha256, thumbnail_sha256}
  ↓  SDK 加密事件（Megolm）→ 只上传**密文**
Matrix upload        POST /_matrix/media/v3/upload?filename=…（Bearer token，body=密文，无哈希参数）
  ↓
Matrix media server  ChatFlow 补丁：流式算**密文**摘要 → 摘要索引查重 → 复用 canonical media_id
  │                  → 写 chatflow_media_blobs / chatflow_media_references
  ↓
event content        'file': {'url': mxc://…, 'hashes': {'sha256': <密文摘要>}, 'key': …, 'iv': …}
                     + Megolm 密文内的 chatflow_media（明文摘要与附件密钥只存在于密文内）
```

要点：

- 上传的**唯一**客户端出口是 SDK `room.sendFileEvent`（`apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart:6275-6288`）。
- 明文摘要在**加密事件内**传送，不进入上传参数、日志、业务 API 或推送（ADR-0060 §4，`docs/adr/0060-content-addressed-media-dedup.md:17`）。
- 服务端看到的 `hashes.sha256` 是**密文**摘要（`apps/mobile_flutter/third_party/matrix/lib/src/room.dart:856`）。
- 因为加密是**确定性**的（key/IV 由 `sha256(plaintext)` 经固定域 HKDF 派生、计数器固定为零），
  **相同明文字节 ⇒ 相同密文 ⇒ 相同密文摘要**，所以"只按密文摘要去重"在协议上等价于按明文去重，
  而服务器**从未**持有明文摘要（`docs/adr/0060-content-addressed-media-dedup.md:11`）。
- 服务端去重实现（**已在生产镜像中**，非本次新增）：
  - 摘要索引与引用表：`third_party/synapse/99_chatflow_media.sql:2-26`
    （`chatflow_media_blobs(digest PK, media_id, unreferenced_ts, retiring)`、
    `chatflow_media_references(media_id,user_id,created_ts,last_uploaded_ts,deleted_ts,…)`、
    `chatflow_media_pending(digest PK, media_id)`）。
  - 上传流程：`third_party/synapse/chatflow_media_dedup.py:169-240` —
    `content_digest()` 流式哈希并校验长度（`:44-55`）；`lookup` 命中即复用（`:191-208`）；
    未命中则先写 `pending` 意图、再落盘、再 `publish` 引用（`:213-240`）；
    新 `media_id` 是 **随机** `secrets.token_hex(12)`（`:214`），**不是摘要**。
  - 引用语义：引用是 **(media_id, user_id)**，不是消息数（`third_party/synapse/README.md:37-38`）；
    按用户删除只删该用户引用（`:253-268`）；最后一个引用删除后 blob 保留、等宽限期（`:119-133`）；
    隔离（quarantine）行作为**摘要墓碑**保留以防重传（`:141-151`）。
  - 串行化：数据库级分布式锁 + 每 HomeServer `Linearizer`（`:23-41`），
    文档明确"偏重正确性而非最大写吞吐，分片前先测量"（`third_party/synapse/README.md:33-36`）。
  - 物理回收：**不由补丁自行调度**，走 Synapse 既有 retention/admin purge（`third_party/synapse/README.md:47-49`）；
    当前仓库配置里**没有** `media_retention` 段（§4.4）。
- 兼容/回退：`CHATFLOW_MEDIA_DEDUP=false` 停止新去重但保留读/引用/清理能力（`third_party/synapse/README.md:64-70`）。

### 1.2 Moments（业务 API）

```
Flutter Client
  │  ① 压缩（最长边 ≤1080px、质量阶梯 [85,70,55]、目标 ≤500KB）
  │  ② POST /api/v1/moments/media/uploads   {file_name, mime_type, byte_size} + Idempotency-Key
  ↓                                        → 返回 {id, upload_url, expires_at(+30min)}
  │  ③ PUT  …/media/uploads/{id}/content   body=图片字节，Content-Type=image/*
  ↓  （服务端校验 mime 与 byte_size 完全一致；GIF 额外做容器级像素预算校验）
Business API
  │  ④ 落盘 LocalPrivateObjectStorage.put(object_key, content)
  │     object_key = moments/{actor}/{uuid4}{.jpg|.png|.webp|.gif}
  │                 或 moments/covers/{actor}/{uuid4}{ext}（封面）
  │  ⑤ 状态 PENDING → UPLOADED →(complete)→ SCANNING/COMPLETED（表 moment_media_uploads）
  ↓
Moment record
  │  ⑥ 发布动态时把"能力 URL"（Fernet 令牌）写进 moment 记录的图片字段/评论 image_object_keys
  │  ⑦ 读取：GET /api/v1/moments/media/content/{token}
  │        → decode_key(ttl=300) → 复核 moment 仍 PUBLISHED + 可见性 + 该 key 确实挂在该动态/评论上
  │        → 返回明文图片字节
```

要点（全部为服务器**明文**，不做客户端加密）：

- 上传三步（begin/put/complete）与幂等键：`services/business-api/app/api/moments.py:183-215`。
- 校验与落盘：`services/business-api/app/modules/moments/media.py:122-164` —
  mime 白名单与 ≤20MiB（`:14-16`）、`content_type` 与 `byte_size` 必须与会话一致（`:155`）、
  GIF 容器与解码像素预算（`:21-99`）、`storage.put(row.object_key, content)`（`:161-162`）。
- 随机 key：`upload_id = str(uuid4())`（`:128`）、`object_key = f"{directory}/{actor}/{upload_id}{suffix}"`（`:131`）。
  **没有内容寻址**：同一张图上传两次 = 两个对象。
- 发布/封面/评论图片：`services/business-api/app/api/moments.py:201-220`（封面）、
  `:241-250`（评论带图，`image_upload_ids`）。
- **状态机不完整**：`PENDING → UPLOADED → COMPLETED`，若在无内容时调用 complete 则进入
  `SCANNING`（`media.py:141-142`）；但**全仓库没有任何 `SCANNING → COMPLETED` 的生产者**
  （worker 的 moments 任务只改 `Moment.status`：`services/business-worker/app/tasks/moments.py:15-23`），
  测试也固化了"空内容 complete ⇒ SCANNING"（`tests/business_api/moments/test_moments_media.py:32`）。
  由于 `put_content` 只拦截 `COMPLETED`（`media.py:153-154`），这类行可长期滞留。
- **过期只在 complete 检查**：`expires_at = created_at + 30min`（`media.py:131`）仅在 `complete()` 强制（`:140`），
  `put_content()` 不检查（`:147-164`）⇒ **可以向已过期、永远无法 COMPLETED 的上传写入字节**。
- **没有"取消/删除上传"端点**（`@router` 清单里只有 begin/put/complete；对比头像有 `DELETE`）。
- **删除不解引用对象**：删除动态是软删除（`service.py:228`）、删除评论也是软删除（`:306`），
  字节永不删除；替换封面时**旧封面对象也不删**（`service.py:429-432`）。
- 读取授权链：`services/business-api/app/modules/moments/media_access.py:60-96` —
  令牌内含 `{domain:"moment-media-v1", key, moment, viewer}`（`:51`），
  读取时以 **硬编码 300s** 解码（`:64`），**复核**动态未删除/PUBLISHED/`VisibilityPolicy.can_view(viewer, moment)`
  （`:77-79`，viewer 来自令牌），并要求该 key 确实挂在动态图片或"可见评论"上（`:80-92`）；
  另有一条 `moment-upload-v1` 域用于上传后自读（`:65-70`，要求 `owner==viewer`、`key` 相符、`COMPLETED`、
  `purpose==MOMENT_IMAGE`）。
- **读取端点本身无鉴权**：`GET /api/v1/moments/media/content/{token}` 没有 auth 依赖
  （`services/business-api/app/api/moments.py:173-181`），令牌即能力；生产验证文档记录了
  "匿名 GET 该 URL 返回 200 与真实 JPEG 字节"（`docs/verification/2026-08-31-moments-image-fix.md:44`）。
- **引用可被"洗白"**：把已签名 URL 变成永久 `media://` 引用时，`resolve_reference` 用
  **不限制 TTL** 的 `decode_key`（`media_access.py:22,31`），因此一个早就过期的自有权 URL 仍可
  被写进新动态（所有权检查仍在，`:35-45`）。
- **读取不复核上传过期**：`media_access.py:68` 只查 owner/status/purpose/key，不查 `expires_at`。 

### 1.3 Avatar（Profile Media）

```
Client
  │  ① POST /api/v1/profile/avatar/uploads {mime_type, byte_size} + Idempotency-Key
  ↓                                        → {upload_id, upload_url, expires_at(+30min)}
  │  ② PUT …/avatar/uploads/{id}/content   body=图片字节（流式读，≤5MiB）
  │  ③ POST …/avatar/uploads/{id}/complete → 校验图片可解码 → users.avatar_object_key = 新 key
  ↓                                        → 返回 profile（含 300s 签名 avatar_url）
Profile API → 私有对象目录 avatars/{user_id}/{uuid4}{ext}
  ↓
（异步）business-worker → 把同一份字节**再上传一份到 Matrix**
                        POST /_matrix/media/v3/upload（管理员令牌）→ users.matrix_avatar_mxc_uri
```

要点：

- 端点与限制：`services/business-api/app/api/profile.py:104-200`；`MAX_AVATAR_BYTES = 5 MiB`（`services/business-api/app/modules/identity/profile.py:23`）。
- 明文摘要：`digest = sha256(content).hexdigest()`（`profile.py:279`），
  仅用于"同一上传会话不能写入不同内容"（`:295-299`）与 complete 前的内容存在性判断（`:336`），
  **没有任何跨会话/跨用户去重**（全仓库只有 4 处引用，`services/business-api/app/modules/identity/models.py:139` 等）。
- 生命周期（**立即物理删除**）：替换头像后删旧对象（`profile.py:365`）、取消上传删对象（`:383`）、
  删除头像删对象（`:427`）。
- 读取 URL：Fernet 签名、`expires_in=300`（`profile.py:25`；`private_storage.py:66` 允许 `(300, 604800)`）。
  **TTL 由请求的 `expires_in` 查询参数决定**：客户端把它改成 `604800` 就能拿到 7 天有效链接
  （`private_storage.py:82-89`、`:66`），令牌本身不含过期时间戳。
- **读取端点无鉴权**：`GET /api/v1/profile/avatar/content/{token}`（`services/business-api/app/api/profile.py:202-213`，`include_in_schema=False`）。
- **重复远端对象**：头像同时存在于业务对象目录与 Matrix 媒体库
  （`services/business-worker/app/tasks/identity.py:187-188`，缓存到 `users.matrix_avatar_mxc_uri`）。
- 头像不是 E2EE（`third_party/synapse/README.md:5-6`："Ordinary avatars are still ordinary media; this patch does not encrypt them"）。

### 1.3b 压缩演绎版（`/media/images/compress`）— 无主对象

- 端点：`POST /api/v1/media/images/compress`（Bearer 必需），尺寸档位 `160/240/320/480/640/800/1280`、
  单请求最多 4 档、输出 `webp|jpeg`（`services/business-api/app/api/media.py:41-96`；
  `services/business-api/app/modules/media/images.py:28,36,57-88`）。
- 限额 10 MiB（`config.py:167`），但**请求体先全量缓冲再校验**（`media.py:48-54`）；
  应用层限流 30 次/60s/用户（`:63-65`，在 Pillow 压缩之后才计数）。
- key = `media/renders/{uuid4}/{size}{ext}`（`:66-71`），**不写任何数据库行** ⇒
  这些渲染产物只通过返回的令牌可达，**没有任何清单/引用**，是审计意义上最难回收的一类孤儿对象。
- 读取端点同样无鉴权（`media.py:98-109`），且 `moments/`（除 `moments/covers/`）键被硬编码拒绝（`private_storage.py:92-102`）。


### 1.4 File / Group（附件媒体）

- 聊天附件与"文件"消息走**与图片/视频相同的 Matrix 出口**（`room.sendFileEvent`），
  因此自动继承 §1.1 的密文去重与引用模型；客户端侧的证据与限制见
  `docs/verification/2026-09-17-media-architecture-audit.md:29`（客户端只有两条上传出口）。
- 群聊 = 同一出口 + 房间成员资格，协议层没有额外的媒体权限。
- **没有独立的"文件服务"**：附件不经过业务 API，也不占用业务对象目录。
- 大小上限（分层，实际生效的是最小者）：Synapse `max_upload_size: 50M`
  （`data/synapse/homeserver.yaml:77`）< nginx `/_matrix/` `100m`（`infra/nginx/nginx.conf.template:136`）。

### 1.5 客户端侧上传约束（服务器设计的接口事实）

服务端设计必须与客户端的**真实能力与限制**对齐，否则协议无人能用：

| 事实 | 值 / 行为 | 证据 |
| --- | --- | --- |
| 聊天文件上限 | **100 MiB**，在 `readAsBytes()` **之前**校验；视频豁免该检查（先转码，转码后再按 20 MiB 卡） | `apps/mobile_flutter/lib/features/matrix/media_message_service.dart:17,120-129,181-186` |
| 聊天图片 / GIF | 20 MiB（GIF 另加 400 万像素预算） | `lib/features/matrix/gallery_media_payload.dart:8`；`lib/features/matrix/gif_image_policy.dart:3` |
| 聊天视频 | 转码后 **20 MiB**（normal 640px/1.2 Mbps/24fps；aggressive 320px/12fps） | `lib/features/matrix/video_transcode.dart:7,54-65,196-200` |
| 图片压缩 | 相册 1280×1280 q80；缩略图 ≤800px/≤100KB；朋友圈 ≤1080px/≤500KB（软目标） | `lib/features/matrix/device_gallery_source.dart:644-647`；`lib/features/matrix/media_thumbnail.dart:8-9`；`lib/features/moments/moment_image_preprocessor.dart:7-8` |
| 头像 | ≤1024px、JPEG q88，**客户端无字节上限**（服务端 5 MiB 兜底） | `lib/features/matrix/avatar_source.dart:11,60-66`；服务端 `services/business-api/app/modules/identity/profile.py:23` |
| 上传并发 | 媒体发送信号量 **3** | `lib/features/matrix/media_message_service.dart:20,32-57` |
| **可续传上传** | **不存在**：全仓库无 `createContent`/`Content-Range`/resumable 用法；SDK 虽然生成了 `POST /_matrix/media/v1/create` 与 `PUT /_matrix/media/v3/upload/{server}/{mediaId}`，但**没有任何调用者** | 客户端审计 §「retry / resume」；`apps/mobile_flutter/third_party/matrix/lib/matrix_api_lite/generated/api.dart:5084-5113,5441` |
| 上传失败重试 | Matrix：**整请求重试**，固定 1 s 间隔，受 `sendTimelineEventTimeout`（默认 60 s）总时限约束；业务 API：8 s 单请求 / 20 s 总时限，仅"刷新令牌后重试一次"，头像与朋友圈 PUT **没有**重试循环 | `third_party/matrix/lib/src/room.dart:805-835,1097`；`lib/core/business_api_client.dart:1490-1493,1505-1529` |
| 客户端上传去重 | **没有**（从不查询"是否已上传过"）；只有**本地**对象库按 `sha256(bytes)` 去重 | `lib/features/matrix/matrix_e2ee_client.dart:6275-6288`；`lib/features/matrix/media_cache.dart:587-622` |
| **非确定性信封的真实例子** | Emoji 保险库附件走 `MatrixFile(...).encrypt()`（随机密钥）并**绕过** `prepareContentAddressedMedia` ⇒ 该路径**不参与**内容寻址去重 | `lib/features/matrix/matrix_e2ee_client.dart:3141-3150` |
| 客户端是否收到过明文摘要 | 是（自己的，用于本地校验）；但**从不回传**任何摘要给服务端；朋友圈的 `image_cache_keys` 是**服务端→客户端**字段 | 客户端审计 §1b/§2 |

设计含义（直接约束 §10 与 §16 的设计）：① 大文件协议必须**从头设计**（客户端今天连"断点续传"的概念都没有）；
② 重试预算很紧（60 s / 20 s），新协议必须让"失败一大段就重来"变成"只补缺失分片"；
③ 必须容纳"随机信封、不可去重"的合法路径（`dedup_eligible=false`）。

### 1.6 三条链路对照表

| 维度 | Chat / File（Matrix） | Moments（业务 API） | Avatar（Profile API） |
| --- | --- | --- | --- |
| 客户端加密 | **是**（确定性信封，E2EE） | 否 | 否 |
| 服务器可见内容 | 仅密文 | 明文 | 明文 |
| 服务器可见摘要 | 密文摘要（自算） | 无（未计算） | 明文 SHA-256（仅会话内冲突检查） |
| 存储位置 | `{project}/data/synapse/media_store`（容器 `/data/media_store`） | `{project}/data/business-media`（容器 `/data/private-media`） | 同 Moments（`avatars/` 前缀） |
| 对象命名 | 随机 `media_id`（`secrets.token_hex(12)`），摘要另存索引 | 随机 `uuid4` | 随机 `uuid4` |
| 去重 | **有**（密文摘要 → 共享 `media_id` + 逐用户引用） | **无** | **无** |
| 引用/引用计数 | 有（`(media_id,user_id)`） | 无（业务表直接持 key） | 无（`users.avatar_object_key` 单点持有） |
| 删除语义 | 逻辑删除引用 → 宽限期 → purge | 动态删除**不删对象**；上传取消/头像替换/头像删除**立即物理删除** | 同左 |
| 读取鉴权 | access token + 房间成员资格；`mxc://` **无签名/无过期** | 读取端点**无鉴权**，Bearer capability（固定 300s）；引用洗白不校验 TTL | 读取端点**无鉴权**；Bearer capability，TTL 由客户端 `expires_in` 决定，可到 7 天 |
| 缓存头 | Synapse 默认 | `private, no-store`（`api/media.py:105`、`api/moments.py:181`） | `private, no-store`（`api/profile.py:218`） |
| 配额 | **无**（无 `media_retention`，无 per-user 字节配额） | 单请求大小上限，**无配额/无计量** | 同左 |
| 审计/指标 | Synapse 日志（不含摘要/文件名：`chatflow_media_dedup.py:238-239`） | **无审计、无指标**（上传不写 audit 行） | complete/delete 写 audit + outbox（`identity/profile.py:351-361,414-424`） |

---

## 2. 存储、生命周期、权限、可复用性（用户要求的四个问题）

### 2.1 存储在哪里

| 层 | 实体 | 位置 | 证据 |
| --- | --- | --- | --- |
| Matrix 字节 | 加密附件 + Synapse 缩略图 | 容器 `/data/media_store` ← 宿主机 `{project}/data/synapse/media_store` | `data/synapse/homeserver.yaml:47`；`docker-compose.yml:34` |
| Matrix 元数据 | `local_media_repository` 等 + 补丁三张表 | Matrix PostgreSQL 16.9（`./data/postgres`） | `docker-compose.yml:2-12`；`third_party/synapse/99_chatflow_media.sql:2-26` |
| 业务字节 | 朋友圈图/封面、头像、压缩演绎版 | 容器 `/data/private-media` ← 宿主机 `{project}/data/business-media`（API 读写、worker 只读） | `docker-compose.yml:262,314`；`services/business-api/app/core/config.py:157` |
| 业务元数据 | `moment_media_uploads`、`avatar_uploads`、`users.avatar_object_key`、`moments_preferences.cover_object_key`、`moment_comments.image_object_keys` | 业务 PostgreSQL 16.9（`./data/business-postgres`） | `docker-compose.yml:185-193`；`services/business-api/migrations/versions/0016_moment_media.py:6` 等 |
| 边缘 | nginx 网关（容器）→ 宿主机 Caddy（仓库外）→ 公网 | `docker-compose.production.yml:43-61` | 同左 |
| CDN | **不存在** | — | §4.5 |

关键结构性事实：**两个媒体根目录都在同一台服务器、同一块盘、只做 bind mount，没有对象存储、没有副本、没有跨机冗余**；
`data/synapse` 与 `data/business-media` 均在同一项目目录下（生产 `/opt/starchat`）。

### 2.2 谁管理生命周期 / 谁负责删除

| 域 | 创建 | 读取 | 删除 | 物理回收 |
| --- | --- | --- | --- | --- |
| Matrix 媒体 | `POST /_matrix/media/v3/upload`（补丁重写为引用发布） | `/_matrix/client/v1/media/*`（v1.11 起需鉴权） | 按用户删除 = 删该用户引用；全局删除 = 撤销该 ID 的所有活引用；管理员 quarantine | 无引用 + 宽限期（`CHATFLOW_MEDIA_RETENTION_MS`，默认 7 天）→ 管理员/retention purge 才真正 unlink（**当前未调度**） |
| 朋友圈媒体 | begin/put/complete | 无鉴权能力 URL + 可见性复核 | 动态/评论删除都是**软删除，不动字节**；**没有上传取消端点** | **不存在**（孤儿对象永久驻留；`SCANNING` 滞留行也一样） |
| 朋友圈封面 | begin/put/complete + `PUT /moments/cover` | 300s 签名 URL（preferences 里 7 天） | 替换封面**不删旧对象**（`service.py:429-432`） | **不存在** |
| 压缩演绎版 | `POST /media/images/compress` | 无鉴权令牌 URL | **无任何记录** | **不存在**（连"哪些对象存在"都无从枚举） |
| 头像 | begin/put/complete | 无鉴权令牌 URL（TTL 可被客户端拉到 7 天） | 替换/取消/删除头像时**立即 delete** | 即时 |

证据：`third_party/synapse/chatflow_media_dedup.py:119-158,253-283`；`third_party/synapse/README.md:44-56`；
`services/business-api/app/modules/identity/profile.py:365,383,427`；
`services/business-api/app/modules/moments/service.py:228,306,429-432`；
`docs/runbooks/profile-avatar.md:27`（运行手册要求"清理任务只能删除已过期且非 COMPLETED 的对象"，
但**该任务在 worker 维护列表里不存在**：`services/business-worker/app/main.py:229`，
而且 worker 把媒体目录挂载为**只读**，`docker-compose.yml:314` —— 即使写了任务也删不掉）。

### 2.3 谁控制权限 / 是否可复用

**权限**

| 域 | 事实 | 证据 |
| --- | --- | --- |
| Matrix | 没有应用层媒体 ACL：任何持 token 且仍在该房间的用户可读；`mxc://` 本身长期有效；**没有签名 URL / 过期时间** | `apps/mobile_flutter/third_party/matrix/lib/src/utils/uri_extension.dart:60-61` |
| Matrix 管理员 | `/_synapse/admin/` 在边缘 404，内网可用；补丁给按用户列表/统计/删除加了引用视图 | `infra/nginx/nginx.conf.template:67-69`；`third_party/synapse/upstream-manifest.json`（改 `rest/admin/media.py`、`storage/.../stats.py`） |
| Moments | 读取端点**无鉴权**，令牌即能力（Bearer capability）；令牌内绑定 `{key, moment, viewer}`，读时复核 PUBLISHED + 可见性 + 该 key 确实挂在该动态/可见评论上；能力 TTL **固定 300s** | `services/business-api/app/api/moments.py:173-181`；`services/business-api/app/modules/moments/media_access.py:64-96` |
| Moments（引用洗白） | 把签名 URL 变永久 `media://` 引用时不校验 TTL ⇒ 过期链接仍可入新动态（所有权仍校验） | `services/business-api/app/modules/moments/media_access.py:22,31,35-45` |
| 头像 / 压缩演绎版 | 读取端点**无鉴权**；令牌内**不含 viewer**（只有 key）；`expires_in` 由**客户端请求参数**决定，允许 `{300, 604800}` ⇒ 可自行拉到 7 天 | `services/business-api/app/api/profile.py:202-213`；`services/business-api/app/api/media.py:98-109`；`services/business-api/app/integrations/private_storage.py:55-71,82-89` |
| 跨域 | 有一步硬编码防护：头像读取端点**拒绝** `moments/`（非 `moments/covers/`）对象键 | `services/business-api/app/integrations/private_storage.py:92` |
| 管理端 | **不存在**任何管理/客服读取或删除媒体的端点 | `services/business-api/app/api/admin.py`（router 清单无媒体路由）、`services/business-api/app/api/support.py`（无媒体引用） |

**可复用性**

| 问题 | 现状 |
| --- | --- |
| 同一密文（聊天）跨用户 | ✅ 已复用：`digest → media_id`，逐用户引用（`chatflow_media_dedup.py:191-208`） |
| 同一明文（朋友圈/头像）重复上传 | ❌ 不复用：随机 UUID key（`api/media.py:66-71`；`modules/moments/media.py:128-131`；`modules/identity/profile.py:248-257`） |
| 跨域（聊天 ↔ 朋友圈 ↔ 头像）复用 | ❌ 完全不可能：两套存储 + 三套演绎版参数（1280 q80 / ≤1080 q55-85 / 服务器裁剪头像） |
| 头像 | ❌ 反而**多一份**：业务目录一份 + Matrix 媒体库一份（`services/business-worker/app/tasks/identity.py:187-188`） |
| 同一文件"聊天 + 朋友圈 + 头像" | 客户端审计结论：**远端至少 3 次上传**（`docs/verification/2026-09-17-media-architecture-audit.md:32`）；加上头像的 Matrix 副本共 **4 个远端对象** |

---

## 3. 现有服务端"媒体对象"骨架（设计必须继承的部分）

Phase 3 设计**不是**从零开始。Matrix 侧已经存在一个可用的服务端媒体对象骨架：

| 目标模型（Phase 0/3） | 现有对应物 | 差距 |
| --- | --- | --- |
| `MediaObject` | `chatflow_media_blobs(digest → media_id)` + Synapse `local_media_repository` 行 | 身份是"密文摘要"，缺 `mime/size/dimensions` 的规范元数据视图；**无版本/无变体** |
| `MediaVariant` | 无（只有 Matrix v2 正文 + `thumbnail_*` 两个独立附件） | 完全缺失：没有 variant 表、没有族谱、没有转码产物 |
| `MediaReference` | `chatflow_media_references(media_id, user_id, …)` | 语义是"上传者持有"，**不是"业务对象引用"**（服务器无法从加密事件得知消息数，README 明确承认） |
| 引用计数回收 | `unreferenced_ts` + `grace` + `retiring` + 管理员 purge | **没有自动 GC 调度**；没有"业务引用"概念 |
| 权限 | 房间成员资格（Matrix 层） | 没有媒体级 access grant（没有 `expires_at`、没有 per-object subject） |
| 生命周期状态机 | 补丁的 pending/publish/retire/forget + quarantine 墓碑 | 没有统一的 `status` 字段与可观测的转换日志 |
| 存储抽象 | `media_storage.py`（Synapse 内建）+ `LocalPrivateObjectStorage`（业务） | 两套互不相干的实现，无共同接口 |
| 上传会话/断点续传 | 无（单次 POST/PUT） | 完全缺失（1GB+ 视频必须先有此能力） |

### 3.1 已有能力清单（可直接复用，不需要重新发明）

1. **内容寻址的密文去重**（跨用户、跨房间、并发安全，含崩溃补偿）——`chatflow_media_dedup.py:169-240`。
2. **摘要墓碑**：隔离（quarantine）对象保留摘要行，防止被封禁内容换个用户重传（`:141-151`）。
3. **可恢复的发布协议**：`pending` 意图先落库，失败留可恢复状态，绝不发布坏 ID（`:213-240`）。
4. **逻辑删除 + 宽限期 + 显式 purge**（`:119-133,270-283`）。
5. **按用户媒体列表/统计/删除**（补丁改了 admin REST、stats、media repository、room 四个上游文件）。
6. **业务侧令牌化读取 + 实时可见性复核**（`media_access.py:60-96`）。
7. **两层可用的"临时上传会话"**（Moments/Avatar 的 begin/put/complete + `expires_at`），
   这是未来统一 `media_upload_sessions` 的雏形。

### 3.2 明确缺失（Phase 3 要解决的目标）

1. 统一对象身份：跨域同一字节 → 一个 `MediaObject`（今天不可能，见 §2.3）。
2. 演绎版（variant）体系：多分辨率图片 / 多清晰度视频 / 渐进播放短片 / poster。
3. 业务引用（`business_type + business_id`）与引用计数 GC（今天只有"上传者引用"）。
4. 媒体级 access grant（subject/permission/expires_at）与可撤销链接。
5. 大文件分片上传 + 续传 + 校验 + 后台重试。
6. 生命周期自动化：过期上传会话清理、孤儿对象 GC、配额与计量。
7. 边缘分发：CDN/签名 URL/防盗链/缓存分层（当前 `no-store` 全灭缓存）。
8. 可观测性：对象数、字节数、去重命中率、GC 回收量、错误率（当前基本没有）。

---

## 4. 基础设施与运行事实（设计约束）

### 4.1 拓扑

```
公网 80/443
  └─ 宿主机 Caddy（仓库外资产，终止 TLS）           docker-compose.production.yml:57-59
       └─ nginx 网关容器（127.0.0.1:9443→443）      docker-compose.production.yml:43-61
            ├─ /_matrix/                → synapse:8008（client+media；compress:false）
            │                              docker-compose.yml:19-37；data/synapse/homeserver.yaml:17-20
            ├─ /_matrix/client/.../sync → synapse-sync-worker:8081   infra/nginx/nginx.conf.template:124
            └─ /api/v1/                 → business-api:8082          docker-compose.yml:224-264
业务 worker（business-worker）         → 同一 business-media 目录（只读）+ Matrix 上传出口
```

- 14 个服务 + 生产 `gateway`；**任何服务都没有 `deploy.replicas`、没有 CPU/内存上限**
  （仅 tron-watch 与 iOS call gateway 例外）。
- 两套 PostgreSQL 16.9（`postgres` / `business-postgres`）、两套 Redis 7.4.2
  （`matrix-redis` **无持久化、无卷**；`business-redis` AOF + 卷）。
- 生产宿主（2026-09-10 记录）：8 vCPU / ≈7.9 GB RAM / 174 GB 可用磁盘，**同机还运行其他服务**。

### 4.2 上传大小上限（四道独立闸门，实际取最小）

| 层 | 上限 | 证据 |
| --- | --- | --- |
| nginx `/_matrix/` | 100m | `infra/nginx/nginx.conf.template:136` |
| **Synapse `max_upload_size`** | **50M（实际生效）** | `data/synapse/homeserver.yaml:77` |
| nginx `/api/v1/` | 25m | `infra/nginx/nginx.conf.template:79,208` |
| 业务 API 压缩接口 | 10 MiB | `services/business-api/app/core/config.py:167` |
| 朋友圈图片 | 20 MiB | `services/business-api/app/modules/moments/media.py:16` |
| 头像 | 5 MiB | `services/business-api/app/modules/identity/profile.py:23` |

> 设计含义：**50 MiB 的硬上限使"1GB+ 视频"在今天的配置下根本无法上传**，分片上传不是优化而是前提。

### 4.3 边缘行为

| 能力 | 现状 | 证据 |
| --- | --- | --- |
| TLS | nginx 也有证书（双终止）| `infra/nginx/nginx.conf.template:63-65` |
| 代理缓存 | **无**（无 `proxy_cache`） | 全仓库 0 命中 |
| 限流 | **nginx 层无**，仅应用层（如压缩 30 次/分/用户） | `services/business-api/app/api/media.py:63-65` |
| gzip | 无；Synapse 监听显式 `compress: false` | `data/synapse/homeserver.yaml:20` |
| 缓存头 | 业务媒体一律 `private, no-store` | `api/media.py:105`、`api/moments.py:181`、`api/profile.py:218` |
| `/_synapse/admin/` | 边缘 404 | `infra/nginx/nginx.conf.template:67-69` |

### 4.4 保留/清理配置

- Synapse **没有** `media_retention`（本地/远端保留期）配置段；
  **没有** `media_storage_providers`/S3；**没有** `thumbnail_sizes` 自定义；**没有** `enable_authenticated_media` 显式配置。
  （全部由子代理逐文件确认 0 命中；鉴权媒体由服务端默认行为提供，见 §8 未确认项。）
- 补丁的宽限期由 `CHATFLOW_MEDIA_RETENTION_MS`（默认 `604800000` = 7 天）控制，
  但**宽限期不等于到期自动回收**（`third_party/synapse/README.md:47-49`）。
- 业务侧**没有任何定时清理**（worker 维护任务列表不含媒体：
  `services/business-worker/app/main.py:229`）。

### 4.5 CDN（明确"不存在"）

- 仓库内**没有任何 CDN/边缘缓存配置**；唯一 Cloudflare 引用是时钟校准数据源
  （`docs/adr/0067-production-clock-discipline.md:11`）。
- 既有结论已写明：密文媒体带鉴权头，**不可公共 CDN 缓存**，属部署层决策
  （`docs/verification/2026-09-02-media-video-invite-image-optimization.md:43`）。
- 设计含义：CDN 章节必须从"当前无 CDN"出发，并解决"鉴权头 vs 可缓存"的根本矛盾（见设计文档 §12）。

### 4.6 实测容量基线（设计性能目标的起点）

来自 `docs/verification/2026-09-10-media-capacity-runtime.md`（本机隔离环境，非生产基准）：

- 200 VU：6 轮全部 PASS（首次同步 p95 最好 0.399s，最差 22.967s）。
- 500 VU：**首次升档 2 轮 FAIL**（请求触及 30s 客户端超时），预热后 4 轮 PASS；
  报告明确"不能判定 500 档稳定达标，更不能据此宣称千人群验收通过"。
- 服务峰值：postgres CPU 299.85%、synapse 112.24%、sync worker 116.34%（4 vCPU 测试机）。
- 媒体写路径的已知瓶颈：**全局数据库锁串行化**（`chatflow_media_dedup.py:32`），
  补丁 README 明确要求"分片前先测量"。

### 4.7 备份与恢复

- **仓库内没有备份/恢复脚本**；备份是服务器侧运行手册要求（`docs/runbooks/matrix-framework-deployment.md:20-21`、
  `docs/runbooks/public-domain-deployment.md:36-39`、`docs/runbooks/profile-avatar.md:20`）。
- 已知生产备份目录 `/opt/starchat-backups/media-20260910`，但**只验证过数据库恢复**（549 条媒体记录一致）。
- 设计含义：未来对象存储必须把"字节 + 元数据 + 引用表"定义为**同一个恢复点**，
  否则会出现"引用存在但字节缺失"或反之。

### 4.8 契约与测试现状（设计可依赖的既有保证）

- OpenAPI 合同：`packages/api-contracts/openapi/liuhetong-v1.yaml`，由 `scripts/export_openapi.py` 生成，
  `--check` 漂移门禁接在 `scripts/verify.ps1:123`，并由 `tests/business_api/test_openapi_contract.py:11-13` 断言。
  媒体相关路径**在合同内**：`/media/images/compress`、`/moments/media/uploads*`、`/moments/cover*`、
  `/profile/avatar*`；**刻意不在合同内**（`include_in_schema=False`）：
  `/media/images/content/{token}`、`/profile/avatar/content/{token}`；
  `/moments/media/content/{token}` 在合同内但**没有 security 段**。
- 既有媒体测试（设计变更必须保持绿灯）：
  - `tests/business_api/media/test_media_images.py`：未鉴权 401、多尺寸 webp 往返、413/422 边界、不放大小图。
  - `tests/business_api/moments/test_moments_media.py`：>20MiB 拒绝、无内容 complete ⇒ `SCANNING`、封面用途隔离。
  - `tests/business_api/moments/test_media_privacy.py`：可见性撤销后 404、篡改令牌 404、旧 7 天 URL 404、
    盗用他人引用 422、400s 前的能力令牌仍可用。
  - `tests/business_api/moments/test_moment_gif_media.py`：GIF 容器/像素预算/伪装/流式中断。
  - `tests/business_api/moments/test_moments_api.py`：评论 `image_object_keys`、非法上传拒绝、带图动态立即发布。
  - `tests/business_api/identity/test_profile_api.py`：头像往返/幂等/取消/删除后存储清空。
  - **没有**任何针对"过期上传清理""孤儿对象 GC""配额"的测试（因为功能不存在）。

---

## 5. 与 Phase 0/1/2 的关系（避免重复劳动）

| 阶段 | 交付 | 与 Phase 3 的接口 |
| --- | --- | --- |
| Phase 0 | 客户端链路审计 + `MediaService`/`MediaObject`/`MediaVariant`/`MediaReference` 概念设计 | Phase 3 直接沿用同名概念，把"本地视图"扩展为"服务端视图" |
| Phase 1 | `VideoPosterPipeline` + 可见性门控 | 证明"封面/海报必须作为独立 variant 提前产出"是正确方向；服务端侧 poster 仍是随事件的独立附件 |
| Phase 2 | 本地 `MediaIndex`、账号配额隔离、GC/pin、`refs` 引用恢复 | **本地引用语义与服务端引用语义必须对齐**：本地 `refs/*.ref`（事件→对象）↔ 服务端 `media_references`（用户→对象）↔ 未来 `business references`（业务对象→对象） |
| ADR-0060 | 确定性加密 + 密文摘要去重 + 逐用户引用 | Phase 3 的"加密去重"分析（设计 §7）建立在此之上：**不必新造 convergent encryption，它已经在跑** |

---

## 6. 关键风险与差距（审计结论）

| # | 差距/风险 | 影响 | 证据 |
| --- | --- | --- | --- |
| A1 | 跨域零复用（聊天/朋友圈/头像三套存储） | 同一文件远端 ≥3 份（头像 4 份）；存储与带宽成倍浪费 | §2.3 |
| A2 | 业务侧孤儿对象永久驻留 | 动态删除后对象永不回收；上传中断的对象也不会被清 | `services/business-worker/app/main.py:229`；`docs/runbooks/profile-avatar.md:27` |
| A3 | Matrix 侧回收未调度 | 宽限期到期的 blob 不会自动消失；只能靠管理员 purge | `third_party/synapse/README.md:47-49` |
| A4 | 无配额、无计量 | 任何用户可以无限占用磁盘；无法做容量规划或滥用治理 | `private_storage.py`（121 行，仅 TTL/路径校验） |
| A5 | 50 MiB 上传上限 + 无分片 | "1GB+ 视频"当前不可能；弱网大文件必然失败重来 | `data/synapse/homeserver.yaml:77` |
| A6 | 无 CDN + 全 `no-store` | 每次查看都回源；高峰期（万人）直接把压力压到单机磁盘与单进程 | §4.3、§4.5 |
| A7 | 无 variant 体系 | 图片只有"原图/缩略图"，视频只有"转码/封面"；无法按网络质量选档，也无法渐进播放 | 客户端审计 §1.4 |
| A8 | 单点：媒体字节与数据库同机同盘，无副本、无备份脚本 | 磁盘故障 = 字节与元数据一起丢 | §4.1、§4.7 |
| A9 | 头像"签名即能力"（令牌不含 viewer） | 300s 内 URL 泄露即可被任意人读取 | `private_storage.py:55-71` |
| A10 | 媒体写路径全局串行 | 上传高峰吞吐受单锁限制；分片前必须先测量 | `third_party/synapse/README.md:33-36` |
| A11 | `matrix-redis` 无持久化 | 缓存类状态可丢（当前仅作缓存/限流协调，未见媒体正确性依赖） | `docker-compose.yml:45-48` |
| A12 | 鉴权媒体依赖服务端默认（无显式配置） | 版本升级可能改变行为；legacy `/_matrix/media/v3/download` 仍可达 | §8 未确认项 |
| A13 | 头像/压缩演绎版 TTL **由客户端 `expires_in` 决定**（可到 7 天） | 令牌泄露窗口被客户端单方面放大；与"300s"的运行手册承诺不符 | `private_storage.py:66,82-89` |
| A14 | 三个业务读取端点**无鉴权**（能力 URL 即权限） | URL 一旦泄露（日志、Referer、截图、转发）即可被任意人读取；无 per-viewer 绑定、无单次使用 | `api/moments.py:173-181`；`api/profile.py:202-213`；`api/media.py:98-109` |
| A15 | `SCANNING` 无生产者；过期只在 complete 校验 | 上传行可永久滞留；可向已过期会话写入字节（永远无法 COMPLETED） | `modules/moments/media.py:140-154` |
| A16 | 朋友圈没有"取消上传"端点 | 用户无法主动回收；只能等（不存在的）清理任务 | §1.2 |
| A17 | 媒体操作**无审计、无指标**（除头像 complete/delete） | 无法回答"谁在什么时候上传/下载了什么"、无法做滥用治理与容量规划 | `api/media.py`（无 audit/log）；`services/business-api`（无 metrics） |
| A18 | 合同覆盖不全：两个 content 端点 `include_in_schema=False`，`compress` 200 为自由对象 | 客户端无契约可依，跨端一致性靠实现猜测 | `packages/api-contracts/openapi/liuhetong-v1.yaml`（无这两个路径）；`api/media.py:98`、`api/profile.py:204` |

---

## 7. 审计方法

- **只读**：全部结论来自源码/配置/文档的第一手读取；未修改任何文件，未运行构建/部署/网络请求。
- **证据规则**：每条结论附 `path:line`；"不存在"类结论附检索范围。
- **并行审计**：本次审计由三个独立只读审计（基础设施与 Matrix 媒体、Flutter 客户端链路、业务 API 生命周期）
  与主审计交叉核对；不一致处以源码为准并记录。
- **行号漂移**：`apps/mobile_flutter` 在本阶段之前刚被 Phase 1/2 及引用消息/相册编辑批次修改，
  引用客户端行号时以**函数名/字符串**为准。

---

## 8. 未确认与不确定项

1. **生产 `.env` 实际值**（`BUSINESS_AVATAR_STORAGE_ROOT`、`BUSINESS_AVATAR_PUBLIC_BASE_URL`、
   `BUSINESS_MEDIA_MAX_UPLOAD_BYTES`、`CHATFLOW_MEDIA_DEDUP`）：仓库只有默认值/示例值；生产值在服务器 0700 目录。
2. **`enable_authenticated_media` 的 Synapse 1.132.0 默认值**：仓库无该配置键；
   客户端能力门控（`apps/mobile_flutter/third_party/matrix/lib/src/client.dart:1224-1229`）与既有验证文档
   （`docs/verification/2026-08-21-avatar-repository-remediation.md:8`）表明服务端声明 v1.11 ⇒ 媒体需鉴权，
   但未从 Synapse 源码确认默认值。
3. **两个媒体根目录的真实磁盘占用**（`data/synapse/media_store`、`data/business-media`）：
   本地为空目录，无服务器访问权限。
4. **生产备份是否包含字节**：只验证过数据库恢复。
5. **`/opt/starchat-backups/media-20260910` 的完整内容清单**。
6. **朋友圈对象键与动态记录的对应关系全貌**（评论图片、封面、草稿、审核中动态），
   本次只核对了 `media_access.py` 读取路径所覆盖的三种挂载点。
7. **是否存在仓库外的清理/巡检脚本**：仓库内 0 命中，但不能排除服务器 crontab/systemd timer。
8. **Matrix 媒体读取的实际缓存头**：Synapse 默认行为未逐条核对。
9. **生产部署的 `moments/service.py` 与本工作树是否一致**：`docs/superpowers/plans/2026-09-09-mobile-parity.md:35`
   明确警告生产有"更新的图片评论逻辑"，本文所有 Moments 结论以本工作树为准。
10. **`resign_read_url` 与文档不一致**：`docs/verification/2026-08-31-moments-image-fix.md:25` 称 feed 图片重签为 7 天，
    但本工作树内 `moment_read_url` 不带 TTL、读取端硬编码 300s，且 `resign_read_url`（`private_storage.py:68-71`）
    **没有运行时调用者**（只有测试）。以哪一版为准未确认。
11. **是否存在运维手工删除 `/data/private-media` 对象的惯例**：仓库内无脚本、无运行手册。

---

## 9. 下一步

按用户要求，Phase 3 的产出是**设计**而非实现：

- 设计文档：[`media-engine-phase3-server-design.md`](media-engine-phase3-server-design.md)
  （17 章：现状 / 问题 / 目标 / MediaObject / MediaVariant / MediaReference / 加密去重分析 /
  权限 / 生命周期 / 上传协议 / 下载协议 / CDN / 数据库模型 / 迁移 / 安全 / 性能 / Phase 4 路线）。
- **本阶段不做**（用户明确禁止，或属于 Phase 3 后半段）：
  修改 Matrix Server / Matrix 协议 / E2EE / 媒体上传接口 / 朋友圈 API / 数据库 schema / 客户端缓存代码；
  实现全球媒体去重、CDN 改造、服务端对象迁移。
