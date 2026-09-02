# 自测报告：最近图片视频、referral 邀请码、聊天图片加载优化

**日期**：2026-09-02
**计划**：`docs/superpowers/plans/2026-09-02-media-video-invite-image-optimization.md`
**需求来源**：畅聊 APP 功能修复需求说明（四部分）
**运行环境**：Windows 10，Python 3.12.10，Flutter 3.44.9（本机 flutter test 实跑）

## 1. 实现摘要（需求 → 交付）

### 一、"最近图片"页面视频（`apps/mobile_flutter`）

| 需求 | 交付 | 状态 |
| --- | --- | --- |
| 1. 加载 MP4/AVI/MOV/MKV 等视频 | 相册混排已具备（`RequestType.common` + 系统 MIME 透传，缩略图解码失败仍可选中发送）；本轮回归覆盖 | 保持+回归 |
| 2. 优先压缩版（减缩版），失败回退原图**并明确提示** | 预览页与发送共用同一份 480p 压缩产物；回退时页面顶部明确提示"压缩版不可用，已使用原始视频（xxM）"，**不静默** | 新增 |
| 3. 压缩策略 ≥50% 减量 | 见 §2 策略表：480p H.264/AAC；未达 50% 且原件 >10MB 自动降档 `LowQuality` 重压一次取更小者（`shouldRetryVideoAtLowerQuality` 纯逻辑有专测） | 新增 |
| 4. 缩略图/预览/进度/重试/懒加载 | 缩略图+分页懒加载既有；新增：准备压缩版的**进度百分比**（`VideoCompress.compressProgress$` 驱动）、失败**重试**按钮、分页失败"点击重试"页脚 | 补齐 |

说明：本页为本地相册选择器，媒体在设备本地，不经服务器；"服务端压缩版"在聊天域的等效实现是发送端生成压缩演绎版并加密附带（规格 §8.1 服务端不可持有聊天明文），已在计划文档 §0 明确该映射。

### 二、"我"页邀请码（服务端 + 客户端）

- 入口：「我」→ 列表新增「邀请码」（钱包与设置之间，key=`profile-invite-entry`）。
- 页面：专属 8 位码 + **30:00 倒计时**自动更新（到点自动拉新码，服务端旧码同步失效）+ 手动刷新。
- 分享：复制邀请码 / 复制邀请链接 / 保存分享图片（卡片渲 PNG 存相册）/ 跳转微信 / 跳转 QQ；未安装回退复制。
- 注册绑定：注册页新增选填「好友邀请码（选填）」，提交前公开校验，无效提示"邀请码无效，请核对或留空"；
  服务端注册事务内写入 `referral_bindings`（每名新用户至多一条，唯一约束防重放）。
- 安全/规模：详见 `docs/runbooks/referral-invite-codes.md`（HMAC 30 分钟轮换、旧码即失效、sha256 落库、
  双层限流防爆破/防枚举、索引反查 O(1)；1000 次校验 <1s，单次 « 200ms）。
- 奖励：`BUSINESS_REFERRAL_REWARD_ENABLED=false`；资金奖励需 ADR（受保护变更），本轮只记录绑定。

### 三、图片消息加载优化

- 发送端（E2EE 内）：图片自动生成 **≤800px、≤100KB** JPEG 缩略图（质量 75→40 逐级 + 600/480 降尺寸兜底），
  视频附带 ≤480px 海报帧，经 SDK `sendFileEvent(thumbnail:)` **加密上传**并写入 `info.thumbnail_file`；
  生成失败不阻断发送。
- 接收端：气泡**缩略图优先**（独立内存缓存，键 `thumb:`）；旧消息无缩略图自动回退全量下载，行为完全兼容。
  点击查看器后按需加载原图：进度指示、失败"点击重试"、"查看原图 xK/M"按 `info.size` 精确显示。
  视频消息卡渲染真实海报帧（免下载整段视频），全屏播放失败可重试。
- 服务端压缩接口（业务域，非 E2EE 聊天媒体）：`POST /api/v1/media/images/compress`，支持
  JPEG/PNG/GIF/WebP 输入（≤10MB），按需多规格（160~1280 档，≤4 规格），WebP/JPEG 输出，签名 URL 回读。
- 传输链路：缩略图 ≤100KB + 双层缓存（SDK 数据库缓存 + 本地磁盘缓存 `MediaCache` + 会话内存 LRU）显著降低
  聊天图片白屏时间；CDN 说明——密文媒体带鉴权头，不可公共 CDN 缓存，属部署层决策。

### 四、其他要求落实

- UI：全部沿用 WeChat 风格组件（`WeChatPageScaffold`/`WeChatColors`/`CupertinoListSection`），深色模式适配；
  UI 契约检查（Flutter/HTML/Figma 漂移）通过。
- 测试：红→绿证据齐备（§3）；自测矩阵见 §4。

## 2. 视频压缩策略（需求一.3）

| 参数 | 值 |
| --- | --- |
| 编码 | H.264 + AAC MP4（`video_compress` 预设） |
| 分辨率档位 | 首选 640×480（`Res640x480Quality`）；降档重试 `LowQuality` |
| 目标减量 | ≥50%（`videoCompressionTargetRatio=0.5`） |
| 降档触发 | 压缩产物 ≥原件 50% 且原件 >10MB（`videoCompressionRetryThresholdBytes`） |
| 兜底 | 压缩失败→回退原文件并提示；原图发送单视频 >20MB 拦截（既有） |
| 复用 | 预览播放与发送共用同一压缩产物，不二次转码；结果按 asset 缓存 |

≥50% 说明：480p 重编码对手机实拍视频普遍减量远超 50%；对压不动的短片取"压缩产物与原件更小者"，
不静默放大流量。真机批量样本回归列入 §5 待办。

## 3. 测试与红→绿证据

### 服务端（pytest，实跑）

- **红**：`test_referral_api.py` 首跑 `ImportError: cannot import name 'ReferralBinding'`（模型未建，按预期失败）；
  `test_media_images.py` 首跑全部 404（路由未建，按预期失败）。
- **绿**：referral 10/10 + media 8/8 通过（`docs/verification/artifacts/2026-09-02/pytest-referral-media.txt`）。
- 全量：`tests/business_api + tests/business_worker` **259 passed, 1 skipped**（verify.ps1 内实跑），
  含迁移 head 断言（`0034_referral_bindings` 唯一 head）、离线 upgrade SQL、OpenAPI 漂移检查 PASS。

### 客户端（flutter test，本机实跑）

- **红**：`ProfileExperiencePage`/`RegistrationGateway` 契约变化使既有 2 个测试文件编译失败（预期性的接口扩展），
  `media_thumbnail` 插件路径在纯单测环境不可用（平台通道缺失）→ 收敛为纯函数 `chatThumbnailTargetSize` 测试。
- **绿**：全量 **505 passed**（`docs/verification/artifacts/2026-09-02/flutter-test-full.txt`），新增 21 个用例：
  压缩策略/回退语义 8、缩略图尺寸/解析 7、邀请码控制器+页面 4、注册推荐码 3（含无效阻断、留空跳过）。

### 门禁（verify.ps1 分步实跑）

Repository policy PASS / Deployment policy PASS / Template PASS / Matrix Bot 9 passed /
Business API+Worker 259 passed / **UI contract drift PASS** / Business API import PASS /
OpenAPI drift PASS / Alembic 唯一 head+离线升级 PASS / Compose render PASS。

### 自测矩阵（需求四.1）

| 场景 | 覆盖方式 | 结果 |
| --- | --- | --- |
| 弱网 | 分页失败重试页脚、视频准备失败重试、查看器原图失败重试、播放失败重试、注册推荐码校验网络重试（`_retryNetwork`） | 用例+路径覆盖 |
| 大文件 | 视频 >20MB 原图拦截（既有回归）；图片 >10MB 服务端 413；压缩 ≥50% 策略降档；海报帧不为封面下载整段视频 | 用例覆盖 |
| 异常输入 | 非图片 MIME 415、损坏图片 422、垃圾字节返回 null 不崩、错误推荐码/旧窗口码/停用邀请人、`sizes` 非法档位 422 | 用例覆盖 |
| 高并发/规模 | 校验吞吐基准（1000 次 <1s）；`code_hash` 唯一索引 O(1) 反查；注册幂等重放不重复绑定（用例）；唯一约束防并发重复绑定 | 用例+基准 |
| E2EE 边界 | 缩略图走 SDK `encrypt()` 加密上传（服务端仅密文）；服务端压缩接口仅限业务域媒体（模块注释+runbook 声明） | 代码评审+设计约束 |

## 4. 已知限制与说明

1. **既有失败（非本轮引入）**：`tests/mobile/test_flutter_boundaries.py::test_video_call_surface_uses_flexible_height_on_compact_devices`
   失败——工作区存在未提交的 `call_page.dart` 改动（473 行 diff，HEAD 含 `maxHeight: 360` 而工作区已无），
   该测试在本次改动前即不通过；未触碰该文件，待该工作所有者收口。
2. 真机项（模拟器无法覆盖）：MKV/AVI 实机转码与播放、微信/QQ 深链调起、相册权限变更回流、
   真机批量视频 ≥50% 减量抽样。建议发布前真机回归一轮。
3. 推荐码资金奖励未启用（需 ADR + 双评审）；当前仅绑定关系与审计（`identity.referral.bound`）。
4. GIF 压缩接口输出为静态 WebP（首帧），动图聊天发送走既有"原样发送"路径不受影响。

## 5. 变更清单（摘要）

- 服务端：`modules/identity/referral.py`（新）、`models.py`、`registration.py`、`api/identity.py`、
  `modules/media/images.py`（新）、`api/media.py`（新）、`main.py`、`core/config.py`、
  `integrations/private_storage.py`、`migrations/versions/0034_referral_bindings.py`（新）、
  `.env.example`、`packages/api-contracts/openapi/liuhetong-v1.yaml`（重导出）。
- 客户端：`device_gallery_source.dart`、`gallery_video_preview.dart`、`image_picker_page.dart`、
  `media_thumbnail.dart`（新）、`matrix_e2ee_client.dart`、`matrix_room_timeline_adapter.dart`、
  `room_timeline_controller.dart`、`room_page.dart`、`encrypted_media_view.dart`、`wechat_video_message.dart`、
  `profile_page.dart`、`invite_controller.dart`（新）、`invite_code_page.dart`（新）、`app_home.dart`、
  `business_api_client.dart`、`registration_controller.dart`、`registration_page.dart`。
- 测试：`tests/business_api/identity/test_referral_api.py`（新）、`tests/business_api/media/test_media_images.py`（新）、
  `tests/business_api/test_health.py`、`tests/business_api/test_migrations.py`、
  `apps/mobile_flutter/test/...`（新增 4 个文件 + 3 个既有文件适配）。
- 文档：计划（本报告顶部链接）、runbook `docs/runbooks/referral-invite-codes.md`（新）、本报告。

---

# 第二轮修复（2026-09-02 下午，用户回归反馈 6 项）

| # | 反馈 | 根因 | 修复 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | 聊天记录上滑无加载反馈 | 滚动到顶未接历史加载，也无 UI 状态 | `RoomTimelineController` 新增 `historyLoading/historyExhausted` 状态机（加载后消息数不增长即判耗尽）；room_page 监听滚动（距顶 240px 触发），列表顶部显示 loading「加载中…」/「没有更多了」 | `room_timeline_controller_test.dart` 新增状态机用例（含耗尽后幂等） |
| 2 | 语音/通话气泡文字颜色不统一 | 两类气泡硬编码白色文字/图标 | `wechat_voice_bubble.dart`、`wechat_call_bubble.dart` 全部改为黑色 `CupertinoColors.black`（#000000），含音纹波形与电话图标 | analyze 0 告警；气泡底色为浅绿/白，黑字对比达标 |
| 3 | 媒体选择器读不到视频（多次反馈） | **AndroidManifest 只声明 `READ_MEDIA_IMAGES`，缺 `READ_MEDIA_VIDEO`**——Android 13+ 图片/视频权限分离，系统只授予图片，Dart 层相册代码（含视频条目、时长角标）一直正确但被权限层拦截 | manifest 补 `READ_MEDIA_VIDEO`；`tests/mobile/test_android_release_network.py` 增加双权限断言防回归 | pytest 断言通过；需重新打包安装后真机确认视频可见、角标“分:秒” |
| 4a | 长按菜单宽度过大 | `_MenuItem` 最小宽度 64px | 减为 32px（四项行宽约减半）；“添加到表情”改为微信式两字文案「收藏」（宽度由内容自然撑开） | 菜单/面板/测试文案同步 |
| 4b | 语音、通话气泡可转发 | 通话摘要被映射为 `text` 类型、语音在可转发集合 | 新增 `MessageContentKind.call`；`isForwardable` 排除 voice+call；通话摘要菜单仅剩「删除/多选」，语音为全菜单去转发 | `message_action_policy_test.dart` 新增用例 |
| 4c | 长按菜单缺“删除” | 功能已存在（`deleteLocal` → `LocalHiddenEvents.hide`，仅本地隐藏、不走撤回） | 行为确认无误；语音/通话气泡的菜单也含删除（见 4b 用例断言） | 既有 `local_hidden_events_test.dart` 覆盖隐藏语义 |
| 5 | “我”页邀请码入口缺失 | 代码中入口存在（`profile-invite-entry`，位于「钱包」与「设置」之间，即设置上方）；未显示最可能是测试安装包早于本轮工作树改动 | 增加存在性+位置 widget 测试（断言入口在「设置」上方渲染）固化 | `profile_controller_test.dart` 新增断言；**需用当前工作树重新打包** |
| 6 | 裁剪头像“确定”被状态栏遮挡 | 之前只在 manifest 的 activity 上声明 `fitsSystemWindows`（该属性对 activity 标签无效）；targetSdk 35 起 Android 强制 edge-to-edge，UCrop 工具栏被状态栏压住 | `Ucrop.CropTheme` 增加 `statusBarColor=#F7F7F7` + `windowLightStatusBar` + `windowOptOutEdgeToEdgeEnforcement`（API 35+ 退出强制），恢复“内容在系统栏以下”的传统布局 | styles.xml 变更；需真机（含全面屏/Android 15）确认 |

### 门禁（第二轮后）

- `flutter analyze`：0 告警；`flutter test` 全量 **507 passed**（新增 3 用例：历史状态机、前向策略、入口存在性）。
- `pytest tests/mobile`：25 passed（含新 manifest 视频权限断言）；唯一失败仍为**第一轮报告 §4.1 的既有项**
  （`call_page.dart` 未提交改动所致，非本轮范围）。

---

# 第三轮修复（2026-09-02 晚，聊天页体验需求 3 项）

| # | 需求 | 实现 | 验证 |
| --- | --- | --- | --- |
| 1 | 更多面板外点自动收起，且不影响原交互 | 面板（更多/工具/表情）外包 `TapRegion(groupId: chatComposerPanelGroupId, onTapOutside: 收起)`；「表情/更多」切换按钮归入同一 TapRegion 组（避免"点按钮收起又被按钮重新展开"）。TapRegion 不消费事件：点输入框仍正常聚焦（`_dismissEmojiPanelForInput` 语义扩展为收起任意面板）、点消息列表仍可滚动/选择 | `flutter analyze` 0 告警；TapRegion 为 Flutter 官方非消费型区域语义 |
| 2 | 「拍摄」短按拍照 / 长按录像，录完带回发送区确认，发送前压缩（带进度） | ① `ChatMorePanel` 拍摄项支持 `onCameraLongPress`（手势竞技场中长按优先于点击）；② `MediaMessageService.captureVideoToFile()` 经 `image_picker.pickVideo(camera)` 调起系统相机录像；③ 录像完成在输入栏上方显示**待发预览条**（封面帧+体积+取消/发送），点「发送」执行 `transcodeForChat`（480p 策略，与相册发送共用同一实现：≥50% 减量目标、大文件自动降档、回退明确提示），进度按百分比显示在预览条上；④ 发送附带封面帧与时长（`info.duration`），压缩失败且原件 >20MB 拒发 | 新增 `video_transcode.dart`（策略收敛，相册路径重构复用）；`chat_display_name_and_video_send_test.dart` 验证回退语义（转码不可用→回退原件+明确提示，不静默）；真机项：系统相机录像调起与压缩进度观感 |
| 3 | 会话内名称优先级：私聊 备注>昵称；群聊 群昵称>备注>昵称 | 提取纯函数 `resolveChatSenderDisplayName`（conversation_presentation.dart），room_page `_displayName` 接入。群昵称判定：Matrix 成员 displayname 与全局昵称不同（或非好友无对照）才视为显式设置，否则回落备注。规格本就规定"展示名优先级：备注名 > 昵称"，原实现层"不读备注"注释为过时决定，已替换 | 纯函数测试覆盖需求示例：私聊"兄弟"；未设群昵称群聊"兄弟"；群昵称"二马"的群聊"二马"；非好友回退成员名 |

### 门禁（第三轮后）

- `flutter analyze`：0 告警；`flutter test` 全量 **510 passed**（新增 3 用例）。
- `pytest tests/mobile`：25 passed；唯一失败仍为既有 `call_page.dart` 项（非本轮范围）。
- UI 契约漂移检查：PASS。

### 需真机确认（本轮）

1. 更多面板：点输入框/列表/面板外任意区域收起，面板内操作不收起，切换按钮开合正常。
2. 长按拍摄 → 系统录像 → 返回后预览条 → 发送（观察压缩百分比进度与明确提示）。
3. 群聊中给好友设置备注/群昵称后，气泡发送者名按优先级显示（对照需求示例）。

---

# 第四轮修复（2026-09-02 深夜，社交二维码与工具入口 4 项）

| # | 需求 | 实现 | 验证 |
| --- | --- | --- | --- |
| 1 | 「我」页二维码入口（头像区右上角）+ 我的二维码页 | `_IdentityCard` 改为 Stack，右上角常驻 `qrcode` 角标（`profile-qr-entry`，44×44 触达区）；新页 `MyQrCodePage`：头像+昵称+二维码卡+「扫一扫上面的二维码图案，加我为朋友」+畅聊号。二维码载荷 `changliao://u/<畅聊号>`（`friend_qr.dart` 纯逻辑编解码，拒绝无关 URL） | `qr_and_tools_test.dart` 6 用例 + `profile_controller_test.dart` 入口断言 |
| 2 | 申请添加朋友页 | **已存在**（`RequestFriendPage`，工作树既有实现）：打招呼≤50字、备注≤20字、标签多选(≤5)+新建、朋友圈权限三项（含"仅聊天"）、发送+申请已发送确认；好友通过后写入通讯录 | 既有 `request_friend_page_test.dart` 全绿 |
| 3 | 扫一扫识别好友码 → 申请页（不自动发送） | 新增依赖 `mobile_scanner 5.2.3`（相机权限已有）+ `ScanQrPage`：取景框+提示+识别流程（解析载荷→`searchUsers(畅聊号)` 精确匹配→携带 user_id/username/nickname/avatar 进入 RequestFriendPage→用户手点「发送」才发起请求；无效码/查无此人/相机失败均有明确提示）。入口：「发现」页首格「扫一扫」 | 载荷编解码测试；相机取景为真机项 |
| 4 | 恢复「更多」面板「工具」入口 | 链路（更多面板工具格 → ChatToolsPanel → 统计助手 → 全屏页）在当前工作树已完整（注册于 room_page、navigatorKey 挂载于 main.dart）——未显示应为测试包早于该实现 | 新增面板级 widget 测试：工具格点击回调 ✓、工具面板列出"统计助手"并路由点击 ✓ |

### 门禁（第四轮后）

- `flutter analyze`：0 告警；`flutter test` 全量 **516 passed**（新增 6 用例）。
- 新增依赖：`qr_flutter 4.1.0`（纯 Dart 渲染）、`mobile_scanner 5.2.3`（相机扫码，所需 CAMERA 权限已存在，无新增权限）。
- 需真机确认：扫一扫相机取景与识别成功率；二维码页深色模式观感。
