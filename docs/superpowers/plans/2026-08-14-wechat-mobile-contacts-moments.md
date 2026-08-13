# 微信风格客户端、通讯录与朋友圈 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立统一微信风格 Flutter 设计系统，补全登录、聊天、语音、附件、红包、钱包，并交付业务后端权威通讯录和可搜索/推荐/治理的朋友圈。

**Architecture:** Flutter 页面只组合 `lib/ui/` 公开组件和 feature controller。Matrix 域继续负责 E2EE 聊天与媒体；FastAPI 模块化业务后端新增 friendship/moments，PostgreSQL 负责权威关系、可见性与全文检索，Worker 负责媒体和治理异步任务。

**Tech Stack:** Flutter 3.44、Dart、matrix 0.34、FastAPI、SQLAlchemy、Alembic、PostgreSQL 16、Redis 7、Docker Compose、pytest。

## Global Constraints

- `UI_DESIGN.md` 是唯一移动端视觉依据；业务页面禁止硬编码主题值。
- 主色 `#07C160`；页面背景 `#EDEDED`；浅表面 `#F7F7F7`；主文字 `#191919`。
- Android/iOS 使用同一套 Flutter 微信风格组件。
- Matrix 私聊、群聊、附件和通话保持 E2EE；业务服务不得读取明文。
- 朋友圈不使用 E2EE，允许服务端搜索、推荐和内容治理。
- CAIBI 两位小数，USDT 六位小数；不得使用二进制浮点。
- 所有业务写要求幂等键、原因码、操作者、审计和 Outbox。
- 不操作 Compose 项目 `starchat` 之外的容器。

---

### Task 1: 微信设计 Token 与基础组件

**Files:**
- Create: `apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart`
- Create: `apps/mobile_flutter/lib/ui/theme/wechat_theme.dart`
- Create: `apps/mobile_flutter/lib/ui/components/wechat_button.dart`
- Create: `apps/mobile_flutter/lib/ui/components/wechat_scaffold.dart`
- Create: `apps/mobile_flutter/lib/ui/components/wechat_list_tile.dart`
- Create: `apps/mobile_flutter/test/ui/wechat_theme_test.dart`
- Modify: `apps/mobile_flutter/lib/main.dart`

**Interfaces:**
- Produces: `WeChatColors`, `WeChatSpacing`, `WeChatRadius`, `WeChatTypography`, `WeChatTheme.build(Brightness)`, `WeChatPrimaryButton`, `WeChatPageScaffold`, `WeChatListTile`.

- [ ] **Step 1: 写失败 Widget 测试**，断言亮色主色为 `Color(0xFF07C160)`、背景为 `Color(0xFFEDEDED)`，按钮加载时不可点击，深色主题主文字为浅色。
- [ ] **Step 2: 运行红测**

```powershell
pwsh -NoProfile -Command "$env:Path='C:\src\flutter\bin;'+$env:Path; Set-Location apps/mobile_flutter; flutter test test/ui/wechat_theme_test.dart"
```

预期：因 `wechat_theme.dart` 不存在而失败。

- [ ] **Step 3: 实现 Token、主题和三个基础组件**；所有数值逐项复制 `UI_DESIGN.md`，在 `main.dart` 用 `WeChatTheme` 替代现有靛蓝主题。
- [ ] **Step 4: 运行测试与 analyze**，预期全部通过且无硬编码靛蓝色。
- [ ] **Step 5: 提交**

```powershell
git add apps/mobile_flutter/lib/ui apps/mobile_flutter/lib/main.dart apps/mobile_flutter/test/ui
git commit -m "feat(ui): add wechat design tokens and foundations"
```

### Task 2: 聊天与金融复用组件

**Files:**
- Create: `apps/mobile_flutter/lib/ui/chat/wechat_message_bubble.dart`
- Create: `apps/mobile_flutter/lib/ui/chat/wechat_timestamp.dart`
- Create: `apps/mobile_flutter/lib/ui/chat/wechat_unread_badge.dart`
- Create: `apps/mobile_flutter/lib/ui/chat/wechat_voice_bubble.dart`
- Create: `apps/mobile_flutter/lib/ui/chat/wechat_attachment_tile.dart`
- Create: `apps/mobile_flutter/lib/ui/finance/wechat_red_packet_card.dart`
- Create: `apps/mobile_flutter/lib/ui/finance/wechat_status_chip.dart`
- Create: `apps/mobile_flutter/docs/COMPONENTS.md`
- Test: `apps/mobile_flutter/test/ui/wechat_components_test.dart`

**Interfaces:**
- Produces: `MessageDirection`, `MessageDeliveryState`, `VoicePlaybackState`, `RedPacketVisualState`, `FinanceSemanticStatus` and corresponding widgets.

- [ ] **Step 1:** 写失败测试，覆盖消息最大宽度 72%、自己/对方气泡色、`99+` 未读、语音 1–60 秒宽度、红包五种状态和金融状态文字+图标。
- [ ] **Step 2:** 运行红测并确认缺失类型导致失败。
- [ ] **Step 3:** 实现小型无业务状态组件；创建 `COMPONENTS.md`，列出构造函数、示例和扩展限制。
- [ ] **Step 4:** 运行组件测试、全部 Flutter 测试和 analyze。
- [ ] **Step 5:** 提交 `feat(ui): add reusable chat and finance components`。

### Task 3: Docker 恢复、端口与登录根因验证

**Files:**
- Modify: `docker-compose.yml`（仅当实际配置仍与规格不符）
- Create: `docs/verification/2026-08-14-docker-recovery.md`

**Interfaces:**
- Produces: 宿主机 `http://127.0.0.1:8082/api/v1/health/live` 和模拟器 `http://10.0.2.2:8082/api/v1/health/live`。

- [ ] **Step 1:** 保存 `docker ps -a`、`docker compose ps` 和 `docker inspect starchat-business-api-1` 的端口证据。
- [ ] **Step 2:** 按 PostgreSQL/Redis → API → Worker → Synapse 顺序重建：

```powershell
docker compose up -d business-postgres business-redis
docker compose up -d --force-recreate business-api
docker compose up -d business-worker postgres synapse
```

- [ ] **Step 3:** 对非 healthy 容器执行 `docker logs --tail 200 <name>`，仅根据明确错误修复 Compose/配置。
- [ ] **Step 4:** 验证 health、OpenAPI、Android `adb shell` 到 `10.0.2.2:8082`，写入验证文档。
- [ ] **Step 5:** 提交 `ops: restore emulator-accessible local services`。

### Task 4: 登录友好错误与三次自动重试

**Files:**
- Create: `apps/mobile_flutter/lib/features/auth/login_controller.dart`
- Create: `apps/mobile_flutter/test/features/auth/login_controller_test.dart`
- Modify: `apps/mobile_flutter/lib/features/auth/login_page.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`

**Interfaces:**
- Produces: `LoginController.submit(credentials)`, `LoginState`, `LoginFailureKind`, `retryNow()`。

- [ ] **Step 1:** 用伪 API 写红测：网络异常重试 3 次，退避 250/500ms；401 不重试；点击重试复用安全凭证生命周期；请求中防重复。
- [ ] **Step 2:** 运行红测，确认 controller 缺失。
- [ ] **Step 3:** 实现错误映射：“网络连接不稳定，请重试”“用户名或密码错误”“服务暂时不可用”；页面使用 `WeChatPrimaryButton` 和重试按钮，不展示 `ClientException`。
- [ ] **Step 4:** 运行单测、Widget 测试、真实错误密码 API 测试。
- [ ] **Step 5:** 提交 `feat(auth): add resilient login retry experience`。

### Task 5: 好友权威域与通讯录 API

**Files:**
- Create: `services/business-api/app/modules/friendship/models.py`
- Create: `services/business-api/app/modules/friendship/service.py`
- Create: `services/business-api/app/api/friendship.py`
- Create: `services/business-api/alembic/versions/<revision>_friendship.py`
- Create: `services/business-api/tests/test_friendship_api.py`
- Modify: `services/business-api/app/main.py`

**Interfaces:**
- Produces: `/api/v1/friends/requests`, `/friends`, `/friends/{id}`, `/friends/{id}/privacy`, `/blocks`, `/contact-tags`, `/users/search`；稳定游标分页。

- [ ] **Step 1:** 写 API 红测，覆盖申请、幂等重复、接受/拒绝、删除、备注、标签、拉黑、朋友圈权限、非好友拒绝和审计/Outbox。
- [ ] **Step 2:** 运行 `pytest tests/test_friendship_api.py -q`，确认路由不存在。
- [ ] **Step 3:** 实现 append-only 审计事件、唯一双向关系键和服务层权限；禁止跨模块直接写 identity 表。
- [ ] **Step 4:** 运行迁移 upgrade/downgrade/upgrade、API 测试和全后端测试。
- [ ] **Step 5:** 更新 OpenAPI 并提交 `feat(friendship): add authoritative contacts domain`。

### Task 6: 朋友圈核心模型、可见性与互动 API

**Files:**
- Create: `services/business-api/app/modules/moments/models.py`
- Create: `services/business-api/app/modules/moments/visibility.py`
- Create: `services/business-api/app/modules/moments/service.py`
- Create: `services/business-api/app/api/moments.py`
- Create: `services/business-api/alembic/versions/<revision>_moments.py`
- Create: `services/business-api/tests/test_moments_api.py`
- Modify: `services/business-api/app/main.py`

**Interfaces:**
- Produces: `VisibilityPolicy.can_view(actor, moment)`；发布/时间线/详情/删除/点赞/评论/回复/举报/通知/封面 API。

- [ ] **Step 1:** 写五种可见范围×好友/非好友/黑名单×四种时间范围的参数化红测；增加点赞/评论幂等和删除权限测试。
- [ ] **Step 2:** 确认红测因模块缺失失败。
- [ ] **Step 3:** 实现稳定游标、软删除、原因码、审计和 Outbox；每个读取入口调用同一 `VisibilityPolicy`。
- [ ] **Step 4:** 运行迁移往返、并发互动测试和完整 API 测试。
- [ ] **Step 5:** 提交 `feat(moments): add visibility-safe social timeline`。

### Task 7: 朋友圈图片、搜索、推荐和治理 Worker

**Files:**
- Create: `services/business-api/app/modules/moments/media.py`
- Create: `services/business-api/app/modules/moments/search.py`
- Create: `services/business-api/app/modules/moments/recommendation.py`
- Create: `services/business-worker/app/tasks/moments.py`
- Create: `services/business-api/tests/test_moments_search_recommendation.py`
- Create: `services/business-worker/tests/test_moments_tasks.py`

**Interfaces:**
- Produces: 预签名上传完成接口、全文搜索、推荐/最新流、审核/下架/申诉状态、媒体清理任务。

- [ ] **Step 1:** 写红测覆盖 9 图上限、20MiB、MIME 伪造、无权搜索泄露、关闭个性化、风险降权、扫描失败和删除清理。
- [ ] **Step 2:** 运行红测并保存预期失败。
- [ ] **Step 3:** 实现 PostgreSQL FTS 和结构化索引；推荐特征只允许好友、新鲜度、互动、已读和举报风险；Worker 通过应用接口消费 Outbox。
- [ ] **Step 4:** 运行业务 API/Worker 测试和 OpenAPI 契约测试。
- [ ] **Step 5:** 提交 `feat(moments): add media search recommendation and moderation`。

### Task 8: Flutter 通讯录与好友管理

**Files:**
- Create: `apps/mobile_flutter/lib/features/contacts/contacts_controller.dart`
- Create: `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`
- Create: `apps/mobile_flutter/lib/features/contacts/friend_requests_page.dart`
- Create: `apps/mobile_flutter/lib/features/contacts/contact_detail_page.dart`
- Create: `apps/mobile_flutter/test/features/contacts/contacts_page_test.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `apps/mobile_flutter/lib/app_home.dart`

**Interfaces:**
- Consumes: Task 5 API；Task 1 components。
- Produces: 微信式通讯录 Tab、好友申请、备注/标签/黑名单/朋友圈权限页面。

- [ ] **Step 1:** 写 Widget 红测：固定入口、拼音分组、索引、申请状态和黑名单确认。
- [ ] **Step 2:** 运行红测。
- [ ] **Step 3:** 实现 controller 与 API DTO，禁止以 Matrix 房间推导好友。
- [ ] **Step 4:** 运行 Widget/集成测试和 analyze。
- [ ] **Step 5:** 提交 `feat(mobile): add wechat-style contacts experience`。

### Task 9: Matrix 时间线控制器与统一消息 UI

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/room_page.dart`
- Create: `apps/mobile_flutter/test/features/matrix/room_timeline_controller_test.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`

**Interfaces:**
- Produces: `RoomMessageViewModel`, `sendText`, `retry`, `loadHistory`, `markRead`；拥有并释放 `Timeline`。

- [ ] **Step 1:** 写红测覆盖历史分页、实时插入、发送中/失败/重试、撤回显示、已读更新和 dispose。
- [ ] **Step 2:** 确认红测失败。
- [ ] **Step 3:** 实现 controller；UI 使用 Task 2 消息、时间戳、附件组件。
- [ ] **Step 4:** 双 Matrix 测试用户发送 E2EE 文本并确认两端 Timeline。
- [ ] **Step 5:** 提交 `feat(chat): add controlled encrypted room timeline`。

### Task 10: 按住说话、取消、试听与播放

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/voice_recording_controller.dart`
- Create: `apps/mobile_flutter/lib/ui/chat/wechat_hold_to_talk.dart`
- Create: `apps/mobile_flutter/test/features/matrix/voice_recording_controller_test.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/media_message_service.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/room_page.dart`

**Interfaces:**
- Produces: `VoiceRecordingState` 的 idle/recording/cancelArmed/preview/uploading/failed；`confirmSend()` 与 `discard()`。

- [ ] **Step 1:** 用假 recorder/player 写红测：60dp 取消、<1秒拒发、60秒自动停止、试听后确认、取消清理临时文件、波形归一化。
- [ ] **Step 2:** 运行红测。
- [ ] **Step 3:** 实现手势控件、20–24 段波形和本地试听；只有确认后调用 Matrix 加密发送。
- [ ] **Step 4:** 运行单测、权限拒绝 Widget 测试和模拟器录音测试。
- [ ] **Step 5:** 提交 `feat(chat): add hold-to-talk voice workflow`。

### Task 11: 图片/文件 Matrix 加密上传、进度与重试

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/attachment_upload_controller.dart`
- Create: `apps/mobile_flutter/test/features/matrix/attachment_upload_controller_test.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/media_message_service.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/room_page.dart`
- Modify: `apps/mobile_flutter/android/app/src/main/AndroidManifest.xml`
- Modify: `apps/mobile_flutter/ios/Runner/Info.plist`

**Interfaces:**
- Produces: `AttachmentUploadState`、0–100 进度、`retry()`、类型/大小校验。

- [ ] **Step 1:** 写红测覆盖取消选择、权限拒绝、图片 20MiB、文件 100MiB、类型拒绝、加密失败、上传重试和临时文件清理。
- [ ] **Step 2:** 运行红测。
- [ ] **Step 3:** 实现选择器和 SDK 加密发送；不得把明文或密钥交给业务 API。
- [ ] **Step 4:** 两台模拟器发送图片/PDF并验证接收端解密。
- [ ] **Step 5:** 提交 `feat(chat): add encrypted attachment upload workflow`。

### Task 12: 红包房间卡片与领取详情

**Files:**
- Create: `apps/mobile_flutter/lib/features/redpacket/red_packet_controller.dart`
- Create: `apps/mobile_flutter/lib/features/redpacket/red_packet_detail_sheet.dart`
- Create: `apps/mobile_flutter/test/features/redpacket/red_packet_flow_test.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/room_page.dart`
- Modify: `apps/mobile_flutter/lib/features/redpacket/redpacket_page.dart`

**Interfaces:**
- Produces: E2EE Matrix 卡片事件仅含 packet ID/祝福语/类型；权威详情始终查询业务 API。

- [ ] **Step 1:** 写红测覆盖可领取、已领取、已领完、过期、撤回，并发领取失败刷新和重复点击幂等。
- [ ] **Step 2:** 运行红测。
- [ ] **Step 3:** 实现卡片、详情 Sheet、创建后 Matrix 投递和领取后刷新；不得从卡片更新余额。
- [ ] **Step 4:** 运行红包 API 并发测试与双模拟器领取测试。
- [ ] **Step 5:** 提交 `feat(redpacket): add authoritative room card flow`。

### Task 13: 钱包交易历史与提现详情

**Files:**
- Modify: `services/business-api/app/api/wallet.py`
- Modify: `services/business-api/app/modules/wallet/service.py`
- Create: `services/business-api/tests/test_wallet_history_api.py`
- Create: `apps/mobile_flutter/lib/features/wallet/wallet_history_controller.dart`
- Create: `apps/mobile_flutter/lib/features/wallet/withdrawal_detail_page.dart`
- Create: `apps/mobile_flutter/test/features/wallet/wallet_history_test.dart`
- Modify: `apps/mobile_flutter/lib/features/wallet/wallet_page.dart`

**Interfaces:**
- Produces: 当前用户 USDT 交易和提现稳定游标分页；全部/充值/提现筛选；详情轮询。

- [ ] **Step 1:** 写后端红测覆盖用户隔离、六位小数、分页、筛选、完整状态机；写 Flutter 红测覆盖状态文字+图标和终态停止轮询。
- [ ] **Step 2:** 运行红测。
- [ ] **Step 3:** 实现只读查询服务和微信钱包式页面；完整地址仅详情页可复制。
- [ ] **Step 4:** 运行后端、Flutter 与 Sandbox 托管契约测试。
- [ ] **Step 5:** 提交 `feat(wallet): add transaction history and withdrawal details`。

### Task 14: Flutter 朋友圈时间线、发布、搜索与设置

**Files:**
- Create: `apps/mobile_flutter/lib/features/moments/moments_controller.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moment_composer_page.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moment_detail_page.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moments_search_page.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moments_settings_page.dart`
- Create: `apps/mobile_flutter/lib/ui/moments/wechat_moment_tile.dart`
- Create: `apps/mobile_flutter/lib/ui/moments/wechat_moment_image_grid.dart`
- Create: `apps/mobile_flutter/test/features/moments/moments_flow_test.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `apps/mobile_flutter/lib/app_home.dart`

**Interfaces:**
- Consumes: Tasks 5–7 APIs。
- Produces: 发现→朋友圈、推荐/最新、九宫格、发布、详情、互动、通知、个人主页、五种权限和四种时间范围。

- [ ] **Step 1:** 写 Widget 红测覆盖 1/4/9 图布局、无视频入口、可见性选择、推荐关闭、审核中/下架和无权内容不渲染。
- [ ] **Step 2:** 运行红测。
- [ ] **Step 3:** 按 `UI_DESIGN.md` 实现页面和 controller；公开发布明确展示审核提示。
- [ ] **Step 4:** 运行 Widget、API 集成、亮暗主题和可见性端到端测试。
- [ ] **Step 5:** 提交 `feat(mobile): add wechat-style moments experience`。

### Task 15: 导航收敛、回归、Release 与文档

**Files:**
- Modify: `apps/mobile_flutter/lib/app_home.dart`
- Modify: `apps/mobile_flutter/docs/COMPONENTS.md`
- Modify: `UI_DESIGN.md`（只记录实现中确认的规范变化）
- Create: `docs/verification/2026-08-14-wechat-mobile-regression.md`

**Interfaces:**
- Produces: 消息/通讯录/发现/我四 Tab；“我”内彩币、红包、钱包入口；签名 Release APK/AAB。

- [ ] **Step 1:** 写导航 Widget 测试，断言四 Tab 顺序和资产入口不再并列。
- [ ] **Step 2:** 运行 `scripts/verify.ps1`、全部 Flutter/后端/Worker 测试和 OpenAPI 契约测试。
- [ ] **Step 3:** 在两台雷电模拟器回归正确登录、错误密码、网络断开恢复、退出登录、好友、E2EE 消息、语音、附件、红包、钱包和朋友圈权限；若登录策略提供验证码则覆盖输入和错误验证码。
- [ ] **Step 4:** 使用外部 keystore 构建并校验：

```powershell
Set-Location apps/mobile_flutter
flutter build apk --release
flutter build appbundle --release
```

- [ ] **Step 5:** 写入真实结果、异常和修复提交；进行规格符合性审查后再做质量/安全审查。
- [ ] **Step 6:** 提交 `release: complete wechat-style mobile regression`。

## Plan Self-Review

- 规格覆盖：设计系统、复用组件、Docker、登录、Matrix 时间线、语音、附件、红包、钱包、通讯录、朋友圈、搜索、推荐、治理与回归均有独立任务。
- 安全覆盖：聊天 E2EE 与朋友圈非 E2EE 明确隔离；财务权威状态、精度和幂等保持不变。
- 类型边界：UI 组件由 Tasks 1–2 提供；好友与朋友圈 API 由 Tasks 5–7 提供；Flutter 消费端在 Tasks 8/14。
- 无占位步骤；Alembic 文件名中的 `<revision>` 是由 `alembic revision` 生成的实际修订 ID，不是业务实现占位。
