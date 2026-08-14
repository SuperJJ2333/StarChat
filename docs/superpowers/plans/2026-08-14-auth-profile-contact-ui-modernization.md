# 六合通注册、资料、好友交互与 UI 现代化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付强制邀请码注册、邮箱双通道验证、Business 与 Matrix 安全登录衔接、个人资料与头像、可用的好友主页和音视频入口，并统一应用沉浸式认证页与现代白底图文按钮。

**Architecture:** Business API 是身份、资料和好友关系的权威源；所有跨域副作用经事务 Outbox 交给 Worker。Flutter 只向 Business API 提交业务密码，再用短期一次性令牌执行 Matrix `m.login.token` 登录；Matrix 继续负责 E2EE 私聊和加密通话。页面按 Page、Controller、View Model、公共组件分层，不允许 UI 直接跨域写状态。

**Tech Stack:** Python 3.12、FastAPI、SQLAlchemy、Alembic、PostgreSQL、pytest、Synapse Admin API、Mailpit/SMTP、Flutter 3.44、Dart 3.12、Matrix Dart SDK 0.34、`flutter_webrtc`、`image_picker`、`image_cropper`、`flutter_svg`、`flutter_launcher_icons`、`flutter_test`、Docker Compose。

---

## 全局约束与交付顺序

1. 每项任务严格执行 RED → GREEN → focused regression → commit。
2. 不提交 `.env`、令牌、SMTP 密码、Synapse 管理密钥、签名材料或真实邮箱。
3. 认证、RBAC、E2EE 变更以已接受的 `docs/adr/0004-business-auth-matrix-login-token.md` 为依据。
4. 用户资料只允许通过 identity/profile 公共接口修改；friendship、moments、Worker 不得直接跨模块写 identity 表。
5. Matrix 房间消息、通话信令和密钥不得成为业务身份或好友关系权威源。
6. 每个后端写请求带 `Idempotency-Key`；Outbox 事件与业务写入同事务提交。
7. 任务 1–8 完成后执行 Domain Review；任务 9–16 完成后执行 Quality/Security Review；评审未通过不得进入最终验收。
8. 现有用户资源 `liuhetong_logo.svg` 与 `landing.png` 在对应 UI 任务中纳入版本控制；不得重绘或覆盖源文件。未被规格引用的 `LOGO.png` 保持原样，不作为图标权威源。

## 文件地图

### 后端与基础设施

- Modify: `services/business-api/app/modules/identity/models.py`
- Modify: `services/business-api/app/modules/identity/registration.py`
- Create: `services/business-api/app/modules/identity/profile.py`
- Create: `services/business-api/app/integrations/matrix_admin.py`
- Create: `services/business-api/app/integrations/profile_storage.py`
- Modify: `services/business-api/app/api/identity.py`
- Modify: `services/business-api/app/core/config.py`
- Modify: `services/business-api/app/modules/friendship/service.py`
- Modify: `services/business-api/app/api/friendship.py`
- Create: `services/business-api/migrations/versions/0017_registration_profile.py`
- Create: `services/business-worker/app/integrations/email_sender.py`
- Create: `services/business-worker/app/integrations/synapse_profile.py`
- Create: `services/business-worker/app/tasks/identity.py`
- Modify: `services/business-worker/app/main.py`
- Modify: `services/business-worker/requirements.txt`
- Modify: `docker-compose.yml`
- Modify: `.env.example`
- Modify: `scripts/export_openapi.py` generated contract output, if generated artifact exists
- Create: `docs/runbooks/registration-email-matrix.md`

### Flutter

- Modify: `apps/mobile_flutter/pubspec.yaml`
- Modify: `apps/mobile_flutter/pubspec.lock`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `apps/mobile_flutter/lib/core/session_bootstrap_controller.dart`
- Modify: `apps/mobile_flutter/lib/session_gate.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`
- Create: `apps/mobile_flutter/lib/features/auth/registration_controller.dart`
- Create: `apps/mobile_flutter/lib/features/auth/registration_page.dart`
- Create: `apps/mobile_flutter/lib/features/auth/email_verification_page.dart`
- Modify: `apps/mobile_flutter/lib/features/auth/login_controller.dart`
- Modify: `apps/mobile_flutter/lib/features/auth/login_page.dart`
- Create: `apps/mobile_flutter/lib/features/profile/profile_controller.dart`
- Create: `apps/mobile_flutter/lib/features/profile/profile_page.dart`
- Create: `apps/mobile_flutter/lib/features/profile/profile_edit_page.dart`
- Modify: `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`
- Create: `apps/mobile_flutter/lib/features/contacts/contact_profile_page.dart`
- Create: `apps/mobile_flutter/lib/features/contacts/contact_more_page.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/direct_chat_controller.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/call_controller.dart`
- Create: `apps/mobile_flutter/lib/features/matrix/call_page.dart`
- Create: `apps/mobile_flutter/lib/ui/components/immersive_auth_scaffold.dart`
- Create: `apps/mobile_flutter/lib/ui/components/modern_action_button.dart`
- Create: `apps/mobile_flutter/lib/ui/components/user_avatar.dart`
- Create: `apps/mobile_flutter/lib/ui/components/user_identity_header.dart`
- Create: `apps/mobile_flutter/lib/ui/components/network_status_capsule.dart`
- Modify: `apps/mobile_flutter/lib/app_home.dart`
- Modify: `apps/mobile_flutter/android/app/src/main/AndroidManifest.xml`
- Modify: `apps/mobile_flutter/ios/Runner/Info.plist`
- Create: `apps/mobile_flutter/tool/generate_brand_assets_test.dart`

### 测试与证据

- Modify: `tests/business_api/identity/test_registration.py`
- Create: `tests/business_api/identity/test_email_verification.py`
- Create: `tests/business_api/identity/test_profile_api.py`
- Create: `tests/business_api/identity/test_matrix_login_token.py`
- Modify: `tests/business_api/friendship/test_friendship_api.py`
- Modify: `tests/business_api/test_openapi_contract.py`
- Create: `tests/business_worker/test_identity_tasks.py`
- Create: `tests/business_worker/test_email_sender.py`
- Create: `apps/mobile_flutter/test/features/auth/registration_controller_test.dart`
- Modify: `apps/mobile_flutter/test/features/auth/login_controller_test.dart`
- Create: `apps/mobile_flutter/test/features/profile/profile_controller_test.dart`
- Create: `apps/mobile_flutter/test/features/contacts/contact_flow_test.dart`
- Create: `apps/mobile_flutter/test/features/matrix/direct_chat_controller_test.dart`
- Create: `apps/mobile_flutter/test/features/matrix/call_controller_test.dart`
- Modify: `apps/mobile_flutter/test/session_gate_test.dart`
- Modify: `apps/mobile_flutter/test/ui/wechat_components_test.dart`
- Create: `docs/verification/2026-08-14-auth-profile-contact-ui-modernization.md`

---

### Task 1: 扩展注册、验证和个人资料持久模型

**Files:** identity models、`0017_registration_profile.py`、identity model tests。

- [ ] **Step 1: 写失败的模型和迁移测试**

断言 `EmailVerificationChallenge` 具备 `registration_session_hash`、`code_hash`、`link_token_hash`、`resend_available_at`、`attempt_count`、`invalidated_at`；`User` 具备 `nickname`、`signature`、`avatar_object_key`、`profile_updated_at`。断言明文字段不存在。

- [ ] **Step 2: 验证 RED**

Run: `py -3.12 -m pytest tests/business_api/identity/test_models.py -q`

Expected: 新列和约束不存在而失败。

- [ ] **Step 3: 实现 expand migration 与模型**

新增可空列，回填 `nickname = username` 和 `profile_updated_at = created_at`，再设置必要的非空约束。为注册会话哈希建立唯一索引，为活动验证挑战建立查询索引。迁移只向前扩展，`downgrade()` 仅删除本迁移新增对象。

- [ ] **Step 4: 验证迁移往返和 GREEN**

Run: `py -3.12 -m pytest tests/business_api/identity/test_models.py tests/business_api/test_migrations.py -q`

- [ ] **Step 5: Commit**

Commit: `feat(identity): add registration and profile persistence`

### Task 2: 强制邀请码与幂等注册会话

**Files:** `registration.py`、`invitations.py`、`identity.py`、`test_registration.py`。

- [ ] **Step 1: 写注册契约失败测试**

覆盖空、无效、过期、耗尽邀请码；并发消费只成功一次；相同 `Idempotency-Key` 重放返回同一 `registration_session`，不重复创建用户或消耗次数。响应不得暴露 `user_id`。

```json
{
  "registration_session": "opaque-public-token",
  "status": "PENDING_EMAIL",
  "resend_after_seconds": 60
}
```

- [ ] **Step 2: 验证 RED**

Run: `py -3.12 -m pytest tests/business_api/identity/test_registration.py -q`

- [ ] **Step 3: 最小实现**

要求 `Idempotency-Key` 请求头；在一个事务内锁定邀请码、检查有效期/次数、创建用户、验证挑战、Outbox 和幂等结果。稳定错误码固定为 `INVITATION_REQUIRED`、`INVITATION_INVALID`、`INVITATION_EXPIRED`、`INVITATION_EXHAUSTED`、`IDEMPOTENCY_CONFLICT`。

- [ ] **Step 4: GREEN 与并发回归**

Run: `py -3.12 -m pytest tests/business_api/identity/test_registration.py -q`

- [ ] **Step 5: Commit**

Commit: `feat(identity): enforce idempotent invitation registration`

### Task 3: 实现 6 位验证码与验证链接双通道

**Files:** `registration.py`、`identity.py`、`test_email_verification.py`。

- [ ] **Step 1: 写失败测试**

覆盖正确验证码、正确链接、10 分钟过期、最多 5 次、60 秒内禁止重发、重发后旧挑战立即失效、重复成功验证幂等、注册状态查询不泄露用户 UUID。

- [ ] **Step 2: 验证 RED**

Run: `py -3.12 -m pytest tests/business_api/identity/test_email_verification.py -q`

- [ ] **Step 3: 实现公共接口**

实现：

- `POST /api/v1/auth/email-verifications/verify`，请求只允许 `registration_session` 加 `code` 或 `token` 二选一；
- `POST /api/v1/auth/email-verifications/resend`；
- `GET /api/v1/auth/registrations/{registration_session}`。

为每个新 challenge 使用 CSPRNG 生成不可预测 id，再由独立服务端 verification secret 通过 HMAC 派生 6 位验证码和链接 Token，使 API 与 Worker 可重现待发送值而无需保存明文；数据库仅写入带 pepper 的哈希。验证成功在同一事务将用户置为 `PENDING_MATRIX` 并发布 `identity.matrix.provision.requested`。

- [ ] **Step 4: GREEN 与日志脱敏检查**

Run: `py -3.12 -m pytest tests/business_api/identity/test_email_verification.py tests/business_api/identity/test_rate_limits.py -q`

- [ ] **Step 5: Commit**

Commit: `feat(identity): add dual-channel email verification`

### Task 4: 接通 Mailpit、可配置 SMTP 与邮件 Worker

**Files:** email sender、identity task、worker main、Compose、`.env.example`、worker tests、runbook。

- [ ] **Step 1: 写发送器和 Handler 失败测试**

断言 STARTTLS/SSL 配置互斥、超时生效、邮件同时包含 code/link、Outbox payload 不含密码、错误字符串不含 SMTP secret，并断言 `identity.email.verification.requested` 已注册到 Worker。

- [ ] **Step 2: 验证 RED**

Run: `py -3.12 -m pytest tests/business_worker/test_email_sender.py tests/business_worker/test_identity_tasks.py tests/business_worker/test_worker.py -q`

- [ ] **Step 3: 实现适配器和本地 Mailpit**

`EmailSender` 从事件中的 challenge id 使用同一 verification secret 在内存中派生 code/link，发送后立即丢弃局部值；Outbox、数据库和日志均不保存明文。Compose 增加固定版本 Mailpit，SMTP 端口 `1025`，开发 Web UI 端口 `8025`；生产由 `SMTP_HOST/PORT/SECURITY/USERNAME/PASSWORD/FROM` 配置。

- [ ] **Step 4: GREEN 与容器契约验证**

Run: `docker compose config`，再运行 focused pytest；使用本地收件箱完成一次发送但不把邮件正文写入验证文档。

- [ ] **Step 5: Commit**

Commit: `feat(worker): deliver registration verification email`

### Task 5: 接通幂等 Matrix 创建 Worker

**Files:** `provisioning.py`、identity worker task、Synapse integration、worker tests。

- [ ] **Step 1: 写失败契约测试**

覆盖首次创建、MXID 已存在、请求超时后查询同一 MXID、事件重放不创建第二账号、成功后 `ACTIVE` 与 `matrix_user_id` 原子保存。

- [ ] **Step 2: 验证 RED**

Run: `py -3.12 -m pytest tests/business_api/identity/test_matrix_provisioning.py tests/business_worker/test_identity_tasks.py -q`

- [ ] **Step 3: 注册 `identity.matrix.provision.requested` Handler**

使用规范化 username 构造稳定 localpart；服务端派生密码仅存在请求内存；Synapse 未知结果先 GET 用户再决定重试。Worker 不跨模块直接写表，而是调用 `MatrixProvisionTask` 公共接口。

- [ ] **Step 4: GREEN 与集成验证**

启动 Synapse、API、Worker 后注册一个测试用户，验证只产生一个 MXID。

- [ ] **Step 5: Commit**

Commit: `feat(worker): provision verified matrix identities`

### Task 6: 增加 Matrix 一次性 Login Token 交换

**Files:** Matrix admin integration、identity API、OpenAPI tests、token tests。

- [ ] **Step 1: 写失败的身份绑定与安全测试**

断言只有有效 Business access token 可交换；目标 MXID 必须来自当前 `sub`；非 `ACTIVE`、缺少 MXID、Synapse 拒绝均使用稳定错误码；响应仅含 `login_token`、`homeserver`、`expires_in`；日志不含 Token。

- [ ] **Step 2: 验证 RED**

Run: `py -3.12 -m pytest tests/business_api/identity/test_matrix_login_token.py -q`

- [ ] **Step 3: 实现受认证端点**

`POST /api/v1/auth/matrix-login-token` 调用 `POST /_synapse/admin/v1/users/{urlencoded_mxid}/login`，设置短期有效期且不写数据库、Outbox 或审计 details。审计只记录 actor、action 和结果。

- [ ] **Step 4: 导出并验证 OpenAPI**

Run: `py -3.12 scripts/export_openapi.py`；Run: `py -3.12 -m pytest tests/business_api/test_openapi_contract.py tests/business_api/identity/test_matrix_login_token.py -q`

- [ ] **Step 5: Commit**

Commit: `feat(identity): exchange business session for matrix token`

### Task 7: 实现个人资料与头像 API

**Files:** profile service、storage adapter、identity API、profile tests、OpenAPI。

- [ ] **Step 1: 写失败测试**

覆盖读取、昵称/签名长度、用户名不可修改、邮箱脱敏、幂等 PATCH；头像上传创建/内容/完成/删除；JPEG/PNG/WebP 真 MIME、1024×1024 与 5 MiB 上限；取消和同 upload id 重试。

- [ ] **Step 2: 验证 RED**

Run: `py -3.12 -m pytest tests/business_api/identity/test_profile_api.py -q`

- [ ] **Step 3: 实现服务和端点**

采用私有对象存储适配器；读取 URL 使用短期签名。资料写入、审计和 `identity.profile.changed` Outbox 同事务提交。默认头像由响应字段 `avatar_fallback_seed` 驱动，不生成长期公共对象。

- [ ] **Step 4: GREEN、OpenAPI 和越权回归**

Run: `py -3.12 -m pytest tests/business_api/identity/test_profile_api.py tests/business_api/test_openapi_contract.py -q`

- [ ] **Step 5: Commit**

Commit: `feat(identity): add profile and avatar management`

### Task 8: 同步 Matrix 资料并扩展好友投影

**Files:** Synapse profile integration、identity task、friendship service/API、friendship and worker tests。

- [ ] **Step 1: 写失败测试**

断言资料事件重放幂等；头像上传到 Matrix media 后才设置 MXC；同步失败不回滚 Business 资料；好友列表和申请返回 nickname/remark/avatar/MXID，展示所需字段完整且不以 UUID 作为 subtitle。

- [ ] **Step 2: 验证 RED**

Run: `py -3.12 -m pytest tests/business_worker/test_identity_tasks.py tests/business_api/friendship/test_friendship_api.py -q`

- [ ] **Step 3: 实现公开查询接口和 Worker 同步**

friendship 通过 profile read service 获取投影。字段固定为 `user_id`、`username`、`nickname`、`remark`、`avatar_url`、`matrix_user_id`、`moments_permission`、`tags`；客户端显示优先级由同一响应测试固化。

- [ ] **Step 4: GREEN 与 Domain Review**

执行 identity/friendship/worker 全套测试，记录认证边界、幂等、Outbox 和 E2EE 不降级的 Domain Review 结论。

- [ ] **Step 5: Commit**

Commit: `feat(contacts): expose authoritative friend profiles`

### Task 9: Flutter 注册状态机与 Business/Matrix 双域登录

**Files:** Business API client、registration/login controllers、Matrix adapter、对应 tests。

- [ ] **Step 1: 写失败 Controller 测试**

覆盖邀请码预校验、注册、验证码/链接验证、60 秒倒计时、状态轮询、网络重试；登录时先恢复 Matrix 会话，否则交换 Token 并调用 `m.login.token`，不得把 Business 密码交给 Matrix。

- [ ] **Step 2: 验证 RED**

Run: `flutter test test/features/auth/registration_controller_test.dart test/features/auth/login_controller_test.dart`

- [ ] **Step 3: 实现类型化 API 和纯状态机**

Controller 只依赖接口注入；为每个稳定错误码提供中文字段提示。Login Token 仅作为局部变量传入 Matrix adapter，成功或失败后立即丢弃。

- [ ] **Step 4: GREEN 与会话恢复回归**

Run: `flutter test test/features/auth test/core/session_bootstrap_controller_test.dart`

- [ ] **Step 5: Commit**

Commit: `feat(mobile): add invitation registration and matrix token login`

### Task 10: 建立现代化 UI 基础组件与品牌资源流水线

**Files:** `pubspec.yaml`、品牌资源、五个 UI 组件、theme/components tests、Android/iOS icon assets。

- [ ] **Step 1: 写失败 Widget 和资源测试**

断言 `ModernActionButton` 为白底、1dp 边框、图标加文字、44dp 最小点击区；危险态红色；减少动态效果无缩放。断言 `ImmersiveAuthScaffold` 引用 `landing.png`，`UserAvatar` 有默认回退，图标清单引用由 SVG 生成的资源。

- [ ] **Step 2: 验证 RED**

Run: `flutter test test/ui/wechat_components_test.dart`

- [ ] **Step 3: 实现组件和依赖**

加入固定版本 `flutter_svg`、`image_cropper`、`flutter_launcher_icons`；将 `landing.png` 加入 assets；实现 0.98 可中断按压反馈与 reduced-motion 分支。`generate_brand_assets_test.dart` 在 Flutter test binding 中通过 `flutter_svg` 将唯一源 SVG 渲染为 1024×1024 PNG，再由 `flutter_launcher_icons` 生成 Android adaptive/legacy 与 iOS AppIcon；生成结果和源 SVG SHA-256 清单纳入 Git。

- [ ] **Step 4: GREEN 与图标检查**

Run: `flutter pub get`、`flutter test tool/generate_brand_assets_test.dart --update-goldens`、`dart run flutter_launcher_icons`、`flutter test test/ui/wechat_components_test.dart`；检查 Android manifest、iOS Contents.json 与源 SVG SHA-256 清单。

- [ ] **Step 5: Commit**

Commit: `feat(mobile): add liuhetong visual foundation`

### Task 11: 实现沉浸式登录、注册和验证页面

**Files:** login/register/verification pages、main/session routing、Widget tests。

- [ ] **Step 1: 写失败页面测试**

断言三页共享背景；注册包含用户名、邮箱、密码、邀请码；无邀请码不能提交；验证页同时具有验证码、链接结果、重发、修改邮箱和状态反馈；按钮无纯绿填充；键盘出现不移动背景层。

- [ ] **Step 2: 验证 RED**

Run: `flutter test test/features/auth`

- [ ] **Step 3: 实现页面和路由**

页面只订阅 Controller 状态；加载时防重复提交；网络失败显示内联提示和白底“重试”；自动重试最多三次且不重放无原幂等键的注册写入。

- [ ] **Step 4: GREEN 与无障碍检查**

Run: `flutter test test/features/auth test/widget_test.dart`

- [ ] **Step 5: Commit**

Commit: `feat(mobile): build immersive authentication flow`

### Task 12: 实现“我”、资料编辑与头像裁剪上传

**Files:** profile controller/pages、AppHome、UserAvatar/Header、tests、platform permissions。

- [ ] **Step 1: 写失败测试**

覆盖资料加载/缓存/修改；相册权限拒绝、正方形裁剪、压缩、上传进度、失败重试、恢复默认头像；“我”页显示头像、昵称、六合通号、签名和显式设置/退出登录。

- [ ] **Step 2: 验证 RED**

Run: `flutter test test/features/profile/profile_controller_test.dart test/widget_test.dart`

- [ ] **Step 3: 实现资料 UI 与上传流程**

头像流程为 select → crop 1:1 → compress → preview → create upload → put → complete；取消不修改远端资料。退出登录二次确认后复用既有双域 session cleanup。

- [ ] **Step 4: GREEN**

Run: `flutter test test/features/profile test/core/session_store_test.dart test/core/session_bootstrap_controller_test.dart`

- [ ] **Step 5: Commit**

Commit: `feat(mobile): add profile and avatar experience`

### Task 13: 重构通讯录、好友主页和“更多”设置

**Files:** contacts page、contact profile/more pages、Business client、contact tests。

- [ ] **Step 1: 写失败测试**

断言列表永不渲染 UUID，展示名优先级为备注 > 昵称 > 用户名；点击好友进入资料页；主操作仅消息/语音/视频；备注、标签、朋友圈权限、拉黑、删除全部位于右上角 More。

- [ ] **Step 2: 验证 RED**

Run: `flutter test test/features/contacts/contact_flow_test.dart`

- [ ] **Step 3: 拆分现有单文件页面**

引入类型化 `ContactSummary`/`ContactDetails`；保存设置后刷新列表和资料页；删除成功返回通讯录；拉黑需二次确认。全部操作使用 `ModernActionButton` 或 `ProfileListRow`。

- [ ] **Step 4: GREEN**

Run: `flutter test test/features/contacts/contact_flow_test.dart test/features/moments/moments_flow_test.dart`

- [ ] **Step 5: Commit**

Commit: `feat(mobile): modernize contacts and friend settings`

### Task 14: 打通好友私聊创建与复用

**Files:** direct chat controller、Matrix adapter、contact profile、room/timeline tests。

- [ ] **Step 1: 写失败测试**

覆盖已有 `m.direct` 房间复用、无房间时创建仅两人的 encrypted room、双击只发起一次创建、失败可重试、成功导航到具体 Room controller。

- [ ] **Step 2: 验证 RED**

Run: `flutter test test/features/matrix/direct_chat_controller_test.dart test/features/matrix/room_timeline_controller_test.dart`

- [ ] **Step 3: 实现公共 Matrix 接口**

`openOrCreateDirectChat(matrixUserId)` 必须先查询有效 direct room；创建时设置 `is_direct`、邀请 MXID，并在进入时间线前确认 `m.room.encryption`。UI 不从 UUID 推导 MXID。

- [ ] **Step 4: GREEN**

Run focused Matrix 与 contact tests。

- [ ] **Step 5: Commit**

Commit: `feat(mobile): open encrypted direct chats from contacts`

### Task 15: 实现一对一加密语音和视频通话

**Files:** call controller/page、Matrix client composition、pubspec、Android/iOS permissions、call tests。

- [ ] **Step 1: 写失败通话状态机测试**

覆盖 `idle → requestingPermission → ringing → connected → ended`、拒绝权限、被叫接听/拒绝、静音、扬声器、切换摄像头、挂断、网络中断。断言通话只能从已验证的 encrypted direct room 发起。

- [ ] **Step 2: 验证 RED**

Run: `flutter test test/features/matrix/call_controller_test.dart`

- [ ] **Step 3: 接入 Matrix VoIP backend**

按 Matrix 0.34 的 `VoIP.init()`、`inviteToCall()` 和 `WebRTCDelegate` 接口适配固定版本 `flutter_webrtc`；Android 声明 CAMERA/RECORD_AUDIO，iOS 写入 camera/microphone usage description。界面显示对端头像和通话状态，不记录媒体或信令正文。

- [ ] **Step 4: GREEN 与双模拟器冒烟**

Run controller tests；使用两个账号验证语音与视频呼入、接听、挂断和权限拒绝。

- [ ] **Step 5: Commit**

Commit: `feat(mobile): add encrypted direct voice and video calls`

### Task 16: 替换离线占位矩形并全局迁移按钮

**Files:** session gate、AppHome、现有 auth/contact/moments/caibi/redpacket/wallet 页面、tests。

- [ ] **Step 1: 写失败布局与静态边界测试**

断言 offlineAuthenticated 使用 `Stack/Overlay` 的 `NetworkStatusCapsule`，不改变 body/TabBar 位置；点击重试；联网淡出。静态测试禁止业务页面继续引用 `WeChatPrimaryButton` 或 `CupertinoButton.filled`。

- [ ] **Step 2: 验证 RED**

Run: `flutter test test/session_gate_test.dart test/ui/wechat_components_test.dart` 和 `py -3.12 -m pytest tests/mobile/test_flutter_boundaries.py -q`。

- [ ] **Step 3: 实现悬浮胶囊和全局按钮迁移**

逐页用 `ModernActionButton`、图标导航动作和危险操作行替换旧按钮，保留原业务 Controller 与幂等键。API 地址继续从 `AppConfig`/构建参数读取，不在 Widget 中硬编码 `10.0.2.2`。

- [ ] **Step 4: GREEN 与视觉回归**

运行 focused Flutter/pytest；截取登录、注册、好友、“我”、朋友圈、彩币、红包、钱包的明暗模式截图写入验证索引。

- [ ] **Step 5: Commit**

Commit: `feat(mobile): finish global modern action styling`

### Task 17: 文档、评审和全链路验收

**Files:** OpenAPI、runbook、`UI_DESIGN.md`（仅补充实现偏差）、verification evidence。

- [ ] **Step 1: 启动并检查基础设施**

Run: `docker compose up -d`、`docker ps -a`、`docker compose ps`。确认 PostgreSQL、Redis、Synapse、Business API、Worker、Mailpit 健康；记录宿主机访问地址和不含秘密的健康输出。

- [ ] **Step 2: 运行后端完整验证**

Run: `py -3.12 -m pytest tests/business_api tests/business_worker -q`；Run: `pwsh -NoProfile -File scripts/verify.ps1`。

- [ ] **Step 3: 运行 Flutter 完整验证和构建**

Run: `flutter analyze`、`flutter test`、`flutter build apk --release`。在 macOS GitHub Actions 运行 iOS simulator build；不要求 App Store 上架或真实签名上传。

- [ ] **Step 4: 双模拟器真实回归**

使用两个新邀请码分别注册 `liuhetong_test01`、`liuhetong_test02`；在 Mailpit 完成 code 与 link 两种验证；覆盖登录、Matrix 同步、会话恢复、加好友、备注、朋友圈权限、E2EE 私聊、语音/视频、头像、退出登录和离线恢复。测试密码只保存在本地运行时，不写入 Git 或日志。

- [ ] **Step 5: 完成受保护变更评审**

按规格逐条记录 Domain Review，再记录 Quality/Security Review：身份绑定、Token 单次/过期、日志脱敏、Outbox 幂等、头像访问控制、Direct Chat E2EE、WebRTC 媒体边界、权限拒绝和回滚恢复。任何未解释失败均阻止完成。

- [ ] **Step 6: 写证据并最终提交**

将命令、退出码、测试计数、模拟器设备名、构建产物 SHA-256 和剩余非阻塞限制写入 `docs/verification/2026-08-14-auth-profile-contact-ui-modernization.md`。Commit: `docs(verification): record auth profile contact acceptance`。

---

## 完成判定

- 强制邀请码、双通道邮箱验证、Mailpit/SMTP、Matrix 创建和一次性登录令牌端到端可用。
- APP 重启后双域登录状态持续；只有主动退出、封禁或 Refresh Token 失效才回登录页。
- 通讯录不显示 UUID；好友页可发消息、语音通话、视频通话；所有好友设置位于 More。
- “我”页展示完整资料并支持头像选择、裁剪、上传、修改、默认头像和退出登录。
- 登录、注册、验证页使用 `landing.png`；双端图标由指定 SVG 生成。
- 所有目标页面遵循 `UI_DESIGN.md` 的白底图文按钮和离线状态胶囊规范。
- OpenAPI、迁移、配置、runbook、Android release、iOS simulator CI 与验证证据同步完成。
- Domain Review、Quality/Security Review、`scripts/verify.ps1` 和相关 E2E 全部通过，无占位实现、硬编码秘密或忽略失败。
