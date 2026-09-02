# 最近图片视频、referral 邀请码、聊天图片加载优化实施计划

**日期**：2026-09-02
**状态**：执行中（自主执行，需求来源：畅聊 APP 功能修复需求说明）
**前置阅读**：`docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`（§3.1 信任边界、§6.2 邀请码、§8.1 附件）、`docs/superpowers/plans/2026-08-31-video-ux-requirements.md`

## 0. 需求到架构的映射（E2EE 边界约束）

规格 §8.1 明确：聊天附件**上传前在设备端加密，服务端不得持有明文/不得提供附件预览**。
因此本轮需求中所有"服务端生成压缩版"的字面表述，在聊天域一律落地为
**发送端客户端生成压缩演绎版（rendition）并加密附带在消息事件里**——
带宽/存储收益相同，且不破坏 E2EE；"服务端图片压缩接口"仅在业务域
（非 E2EE 的业务媒体，如头像/朋友圈类业务上传）提供。

| 需求条目 | 落地方案 |
| --- | --- |
| 一.1 最近图片页加载视频 | 已具备（`RequestType.common` 混排+MIME 透传），本轮回归保护 |
| 一.2 视频优先"压缩版(减缩版)"，失败回退原图并明确提示 | 相册预览/发送优先客户端压缩产物；聊天视频为发送端 480p 压缩演绎版；回退原图时给出明确 toast |
| 一.3 压缩策略≥50% | 640×480 H.264/AAC 档位 + 未达 50% 时降档重试一次 + 取更小者（`selectVideoRendition` 纯逻辑可测） |
| 一.4 缩略图/预览/进度/重试/懒加载 | 缩略图、分页懒加载已有；新增：转码进度（%）、失败重试、降档重试 |
| 二.邀请码 | 业务 API 新增 referral 域（下详）；奖励入账属受保护变更，仅记录绑定+Outbox 前置状态，不发资金 |
| 三.1/3.2 聊天图片先压缩后原图 | 发送端附带 ≤800px、≤100KB 加密缩略图；接收端气泡优先缩略图，查看器点按加载原图（已有查看器改造） |
| 三.3 服务端图片压缩接口 | 业务 API `POST /api/v1/media/images/compress`（Pillow 多规格，JPEG/PNG/GIF/WebP 输入） |
| 三.4 传输链路 | 缩略图≤100KB + SDK/本地双层缓存 + 查看器失败重试；CDN 说明见 runbook（密文媒体不可公共 CDN 缓存） |

## 1. 任务 A：referral 邀请码（服务端 + 客户端）

### 设计

- **确定性轮换码**：`code = base32_unambiguous(HMAC-SHA256(secret, "{user_id}:{window_index}"))[:8]`，
  `window_index = floor(epoch_seconds / 1800)`。校验只算**当前窗口**——旧码随窗口切换立即失效，
  无需每 30 分钟写库轮换；万级用户校验路径为 1 次 HMAC + 1 次 Redis 限流命中，**无 DB 查询**，P99 « 200ms。
- **表 `referral_bindings`**（迁移 0034，expand-only 幂等）：
  `id PK / inviter_user_id IDX / invited_user_id UNIQUE / code_hash / code_window_index / status / reward_state / bound_at / created_at`。
  同一新用户只可绑定一次（唯一约束天然防重放/防重复绑定）。
- **安全**：码仅存 sha256；比较用 `hmac.compare_digest`；码表 32 个无易混字符，8 位 ≈ 2^40；
  公开校验接口限流 `referral:validate`（IP+码 10/60s，IP 30/3600s）；绑定走注册同事务 + 唯一约束 + 幂等键重放安全；
  不回显邀请人身份（防枚举）；不记录明文码到日志/审计。
- **奖励策略**：默认 `REFERRAL_REWARD_ENABLED=false`，`reward_state=NOT_CONFIGURED`；
  资金奖励需按 AGENTS.md 走 ADR + 双评审后接账本（规格 §6.2：不形成默认层级返佣）。
- **API**：
  - `GET /api/v1/invitations/referral`（鉴权）→ `{code, rotates_at, rotates_in_seconds, share_url}`
  - `POST /api/v1/invitations/referral/validate`（公开限流）→ `{valid}`
  - `RegisterRequest.referral_code`（选填，≤32）；注册事务内有效则绑定，无效不阻断注册（管理邀请码仍是硬门槛）
- **配置**：`BUSINESS_REFERRAL_CODE_SECRET`（生产必填校验）、`BUSINESS_REFERRAL_ROTATION_SECONDS=1800`、
  `BUSINESS_REFERRAL_SHARE_BASE_URL`、`BUSINESS_REFERRAL_REWARD_ENABLED=false`

### 文件所有权

- 新增：`backend/app/modules/identity/referral.py`、`backend/migrations/versions/0034_referral_bindings.py`、`tests/business_api/identity/test_referral_api.py`
- 修改：`backend/app/modules/identity/models.py`、`backend/app/modules/identity/registration.py`、`backend/app/api/identity.py`、`backend/app/core/config.py`、`.env.example`
- 客户端：`lib/core/business_api_client.dart`、新增 `lib/features/profile/invite_controller.dart`、`lib/features/profile/invite_code_page.dart`、修改 `lib/features/profile/profile_page.dart`、`lib/app_home.dart`、`lib/features/auth/registration_controller.dart`、`lib/features/auth/registration_page.dart`
- 测试：`apps/mobile_flutter/test/features/profile/invite_code_page_test.dart` 等

## 2. 任务 B：服务端图片压缩接口

- 新增 `backend/app/modules/media/images.py`（Pillow：EXIF 转正、LANCZOS 缩放、规格档位
  `160/240/320/480/640/800/1280`，输出 WebP/JPEG）、`backend/app/api/media.py`。
- `POST /api/v1/media/images/compress`：Bearer 鉴权；原始字节体 + `Content-Type` 校验
  （JPEG/PNG/GIF/WebP，≤10MB）；query `sizes`（≤4 档）；产物写入既有私有存储 `media/renders/` 前缀，
  返回各规格 `{width,height,size,format,url(签名300s)}`；限流 30/60s/用户。
- `GET /api/v1/media/images/content/{token}`：与头像一致的签名读取（`read_signed` 扩展 `.gif/.jpeg`、
  支持自定义路径模板）。
- 明确注释/文档：该接口仅服务业务域媒体；E2EE 聊天媒体压缩在客户端（规格 §8.1）。
- 测试：`tests/business_api/media/test_media_images.py`（四格式、多规格、超限、鉴权、签名回读）。

## 3. 任务 C：最近图片页视频体验补齐（客户端）

- `device_gallery_source.dart`：
  - 新增纯逻辑 `selectVideoRendition(originalBytes, compressedBytes)`：压缩更小即采用；
    未达 ≥50% 且原件 >10MB 时自动降档（LowQuality）重试一次再取更小者（满足"尽量≥50%"）。
  - 新增 `posterThumbnail`（视频封面帧，供发送时附带与聊天展示）。
- `gallery_video_preview.dart`：准备压缩版阶段显示进度（`VideoCompress.compressProgress$` 百分比 +
  文案"正在准备压缩版…"）；压缩失败回退原视频播放并 toast"压缩版不可用，已切换原始视频"；
  失败态提供"重试"。
- `image_picker_page.dart`：分页/缩略图/懒加载保持；分页加载失败时底部"加载更多失败，点击重试"。

## 4. 任务 D：聊天图片/视频缩略图优先（客户端，Matrix E2EE）

- 新增 `lib/features/matrix/media_thumbnail.dart`：
  - 图片：最长边 ≤800px、JPEG 质量自 75 逐级降至 40，目标 ≤100KB（flutter_image_compress）。
  - 视频：`VideoCompress.getByteThumbnail` 取海报帧（≤480px）。
- `matrix_e2ee_client.dart`：`sendEncryptedMedia` 增加 `thumbnailBytes/thumbnailWidth/thumbnailHeight`，
  经 SDK `sendFileEvent(thumbnail: MatrixImageFile(...))` 加密上传并写入 `info.thumbnail_file`（SDK 0.34 原生支持）。
- 发送接线：`room_page._pickAndSendImages`、相机/文件路径（`media_message_service.dart`）附带缩略图。
- 接收接线：`matrix_room_timeline_adapter.dart` 新增 `loadThumbnail(eventId)`（SDK
  `downloadAndDecryptAttachment(getThumbnail:true)`，旧消息无缩略图自动回退全量，行为兼容）；
  `room_page` 新增缩略图内存缓存（键前缀 `thumb:`）；`EncryptedImageMessage` 增加 `loadThumbnail`
  （缩略图优先、失败可重试）；查看器"查看原图"保持并增加失败点击重试；`VideoMessageCard` 增加海报帧渲染
  替换黑块；`VideoViewerPage` 失败增加"重试"。
- 消息模型透传 `info.size` 供查看器"查看原图 xK/M"精确显示。

## 5. 验证与门禁

1. 服务端：新增 pytest 先红后绿（记录失败输出）；`verify.ps1` 全量通过（含 OpenAPI drift → 重新导出契约）。
2. 客户端：`flutter test`（本机 `C:\src\flutter`，3.44.9）新增红→绿证据；弱网/大文件/异常输入场景以
   单测 + 代码路径论证覆盖，真机项在报告中标注为待真机回归。
3. 产物：`docs/verification/2026-09-02/`（红绿证据、契约 diff 摘要、自测报告）。

## 6. 明确不做

- 不做资金奖励发放（受保护变更，需 ADR）；不做 USDT 相关能力。
- 不让服务端接触任何聊天明文/密钥；不在服务端为 E2EE 聊天媒体生成缩略图。
- 不做破坏性迁移；不做破坏性 OpenAPI 变更（仅新增字段/端点）。
