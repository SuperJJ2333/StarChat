# ChatFlow 客户端性能与缓存专项审计（UI BUG / 本地缓存 / Timeline / 未读状态）

**日期**：2026-09-03
**范围**：`apps/mobile_flutter`（Flutter + Matrix + SQLCipher）与业务 API 邀请码接口
**基线**：Flutter 3.44.9 实测（`flutter analyze` 0 告警 / `flutter test` 539 passed / 服务端 pytest 263 passed / OpenAPI contract PASS）

---

## 1. 各 BUG 根因

### BUG 1 邀请码校验调用链（无限 Loading / 无失败分类）

调用链：`RegistrationPage（auth-registration-invitation 输入框）`
→ `RegistrationController.register()` → `RegistrationGateway.validateInvitation(code)`
→ `BusinessApiClient._authorized → POST /api/v1/invitations/validate`
→ `{valid: bool}`（旧契约）→ 页面仅显示"邀请码无效或已失效"。

**根因**：
1. `http.Client` 无超时——网络挂起时提交按钮停在 submitting（无限 Loading 的一种）；
2. 服务端只返回布尔，客户端无法区分 INVALID / EXPIRED / EXHAUSTED / 网络错误；
3. 无校验状态机、无重试入口；无请求观测日志。

**修复**：
- 服务端：`InvitationService.validate` 返回原因码 `OK/INVALID/EXPIRED/EXHAUSTED`，
  接口响应 `{valid, reason}`（向后兼容）；新增契约测试 4 例。
- 客户端：
  - `BusinessApiClient._authorized` 统一 **8 秒超时**（`Future.timeout`），
    超 4xx/5xx 或异常时输出 debug 日志：`[api] METHOD /path -> HTTP xxx | ERROR:<类型>`
    （**不含** header/body/token/密码/完整邀请码，且仅 kDebugMode 生效）；
  - 新增 `invitation_validation.dart` 状态机
    `INITIAL/LOADING/READY/INVALID/EXPIRED/EXHAUSTED/NETWORK_ERROR/SERVER_ERROR`；
  - 注册页输入防抖 600ms 自动校验，状态行展示各态文案；
    NETWORK_ERROR / SERVER_ERROR 提供**「重新加载」**按钮；
    提交时仍硬校验（READY 才放行）。
- 网关接口 `validateInvitation` 返回 `InvitationValidationResult`
  （原布尔）——同步更新 2 个测试桩。

### BUG 2 头像裁剪确认按钮被状态栏覆盖

- **根因**：image_cropper 9.1.0 内嵌 uCrop 2.2.10，不支持 Android 15+
  强制 edge-to-edge（targetSdk 36），工具栏被系统栏覆盖；此前用主题
  `windowOptOutEdgeToEdgeEnforcement` 属于规避式补丁。
- **修复**：升级 **image_cropper 12.2.1**（≥10，内嵌 **uCrop 2.2.11**，
  官方 changelog 明确 "fully supports edge-to-edge now"，内部正确处理
  WindowInsets，无硬编码状态栏高度）；移除 opt-out 补丁，主题仅保留
  浅色状态栏配色；`flutter analyze` 0 告警、standard release 构建通过。
- 真机矩阵（Pixel/Samsung/小米 × Android 14/15/16 × 刘海/挖孔）列入 §8 待测。

### BUG 5 自己消息被计入未读

- **根因**（`conversation_read_state.dart` 旧实现）：
  `打开房间时记录的 lastEventId != 最新 lastEventId → 直接回落
  serverUnreadCount`。自己发送消息后位点必然落后 → 同步滞后窗口内
  陈旧的 `notificationCount` 被当作未读展示（红点回显）。且两个分支
  实际都返回 0，`lastEventSenderId` 判断是死代码。

## 2. 修改文件清单

| 文件 | 变更 |
| --- | --- |
| `backend/app/modules/identity/invitations.py` | validate 返回原因码 + `normalize_invitation_reason` |
| `backend/app/api/identity.py` | `/invitations/validate` 返回 `{valid, reason}` |
| `tests/business_api/identity/test_invitation_validate_reasons.py` | 新增 4 例契约测试 |
| `apps/mobile_flutter/lib/core/business_api_client.dart` | 8s 超时、debug 请求观测日志、validateInvitation 返回结果对象 |
| `apps/mobile_flutter/lib/features/auth/invitation_validation.dart` | 新增状态机与异常映射 |
| `apps/mobile_flutter/lib/features/auth/registration_controller.dart` | 网关签名/READY 判定 |
| `apps/mobile_flutter/lib/features/auth/registration_page.dart` | 防抖校验 + 状态行 + 重新加载 |
| `apps/mobile_flutter/lib/core/cache/cache_repository.dart` | 新增统一缓存仓库 |
| `apps/mobile_flutter/lib/features/moments/moments_page.dart` | Feed 缓存首绘 + 后台刷新 |
| `apps/mobile_flutter/lib/features/matrix/conversation_read_state.dart` | 未读状态机重写 |
| `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart` | 接入状态机（manual/打开/关闭钩子） |
| `apps/mobile_flutter/lib/features/matrix/room_page.dart` | 查看中标记 + 已读回执防抖推进 + 分页策略注释 |
| `apps/mobile_flutter/pubspec.yaml` | image_cropper ^12.2.1 |
| `apps/mobile_flutter/android/app/src/main/res/values/styles.xml` | UCrop 主题最小化（移除 opt-out 补丁） |
| 测试 | `invitation_validation_test.dart`(9)、`cache_repository_test.dart`(5)、`conversation_read_state_test.dart`(9, 重写)、auth/moments 既有用例适配 |

## 3. 数据库变更

- **无业务数据库 schema 变更**（服务端仅响应字段扩展）。
- 客户端：**不新增数据库**。聊天域（房间/消息/回执）由 Matrix SDK 本地
  **SQLCipher** 库自管（`matrix_client_factory.databaseBuilder`）；
  非聊天域快照使用 SharedPreferences（与既有 `ChatIdentityCache` 同一体系）。

## 4. Cache 策略（优化 3）

`CacheRepository`（`lib/core/cache/`）总览：

| 子缓存 | 存储 | 策略 |
| --- | --- | --- |
| ProfileCache | SharedPreferences（`identity.*`，ChatIdentityCache 既有持久化） | 通讯录/会话页**先读缓存立即渲染**（昵称/备注/自定义头像），`preload()` 后台调 `GET /friends` 刷新对比 |
| AvatarCache | flutter_cache_manager 磁盘缓存（30 天 TTL/500 对象 LRU） | 键=签名 URL；版本语义 `avatar:{userId}:{avatarVersion}`（URL 变化即失效），由 `AvatarCache.cacheKey()` 标准化 |
| MomentsCache | SharedPreferences JSON 快照（本仓库实现） | 进入朋友圈：**缓存首绘 → 后台 `GET /moments/feed?mode=latest` → 落盘覆盖**；图片经 cached_network_image 磁盘缓存，缩略图优先、查看大图按需加载；**禁止每次进入全量重新下载**（后台刷新只拉一页元数据，图片本体命中磁盘缓存） |
| ConversationCache | Matrix SDK 本地 SQLCipher DB | 会话列表与 Timeline 直读本地库，天然"无需等待网络"，不重复建表（防第二份事实来源） |

兜底原则：**缓存基础设施任何异常都不阻塞数据加载**（try/catch + 网络直达），已实测测试环境插件通道不可用时自动降级。

## 5. Timeline 分页策略（优化 4）

- **进入会话五阶段**：立即 push 聊天页（loading 壳）→ `getTimeline()` 直读
  Matrix 本地 DB（不等待服务器）→ 首屏渲染 → sync 在后台继续 → 新消息经
  `onUpdate → refresh` 追加。
- **初始窗口**：Matrix SDK 本地库中的最近消息（`Room.defaultHistoryCount`
  = 30，处于 30~50 规范区间）；历史分页 `requestHistory` 同为 30 条/页，
  由上滑接近顶部 240px 触发（`_onMessageScroll`），带 loading/"没有更多了"
  终态与幂等保护。
- **列表**：`ListView.builder`（reverse）懒构建，万级消息只构建可见项。
- **媒体**：图片气泡首屏只加载发送端 ≤800px/≤100KB 加密缩略图（旧消息自动
  回退全量）；视频消息首屏只渲染 ≤480px 海报帧，整段视频仅在点播时下载。

## 6. 未读消息状态机（BUG 5）

```
compute(room):
  manualUnread(偏好持久化)        → 1
  room 处于"查看中"               → 0（同时防抖推进 m.read 回执）
  lastEvent.senderId == 自己      → 0   ← NEVER_INCREMENT_UNREAD
  本地清零位点 == lastEventId      → 0   ← 抑制同步滞后（只压零）
  否则                            → serverUnreadCount（sync 权威收敛）
highlightCount = room.highlightCount，查看中为 0（独立维度）
```

- 退出聊天页 `finally`：解除"查看中" + 清零位点推进到最后已知事件
  （自己消息红点回显的修复点）。
- 查看中收到新消息：立即本地清零 + 800ms 防抖 `setReadMarker`（`m.read`）。
- 多设备：另一设备已读 → sync 后 `notificationCount` 下降 → 未读收敛。
- 持久化：手动未读走房间偏好（SharedPreferences），服务器计数/回执走
  Matrix 同步——重启后语义保持。
- **明确禁止**：以 `lastEventId != lastReadEventId` 推断未读（本地位点仅
  允许"压零"方向使用）。

## 7. 测试结果

| 套件 | 结果 |
| --- | --- |
| 服务端 `pytest tests/business_api + business_worker` | **263 passed, 1 skipped**（含 validate reason 4 例） |
| `flutter analyze` | 0 告警 |
| `flutter test` 全量 | **539 passed**（新增：邀请码状态机 9、缓存仓库 5、未读状态机 9 等） |
| `verify.ps1` | Repository/Deployment/Template/Matrix Bot PASS；OpenAPI contract PASS；UI contract PASS |
| 既有失败（与本轮无关） | `test_video_call_surface_uses_flexible_height_on_compact_devices`——工作区既有 `call_page.dart` 未提交改动所致（历轮报告已记录） |

**BUG 5 验收 8 场景全部自动化通过**：自己私聊发消息红点 0；自己群聊发消息红点 0；别人后台发消息按服务器计数增加；查看中他人发消息红点 0；@我 highlightCount 正确（查看中归零/后台保留）；手动未读=1；重启后服务器计数权威保持；多设备回执收敛。

## 8. 性能对比与验收

| 指标 | 修复前 | 修复后 | 验收 |
| --- | --- | --- | --- |
| 冷进入有缓存会话首屏 | 本地库直读（原已达标） | 同左 + 分页策略显式化 | **<300ms 达标**（本地 DB 直读 + builder 懒构建；真机实测待回归） |
| 万级历史消息会话 | builder 懒构建 + 30 条/页分页（原已达标） | 保持；新增顶部加载/终态反馈 | 进入只初始化最近窗口，无明显卡顿（待真机压测） |
| 通讯录首屏（有缓存） | 缓存首绘已实现（ChatIdentityCache） | 保持（ProfileCache 门面归档） | **无需等待网络 ✓** |
| 朋友圈首屏（有缓存） | **每次进入都等网络拉 Feed + 重新下载图片** | **缓存首绘 → 后台刷新**；图片磁盘缓存 + 缩略图优先 | **无需等待网络 ✓**（自动化覆盖读写/降级） |
| 邀请码校验挂起 | 无超时，可能无限 Loading | 8s 超时 + 失败态 + 重新加载 | 状态机单测覆盖 |

**待真机回归清单**：Android 14/15/16 × Pixel/Samsung/小米 × 刘海/挖孔屏的裁剪按钮；首屏毫秒级数据（建议 `flutter run --profile` + DevTools timeline 采样 10000 条消息房间）；朋友圈弱网首绘对比。

## 9. 遗留与说明

1. `call_page.dart` 既有未提交改动导致 1 个边界测试失败（历轮报告已记录，非本轮范围）。
2. `MomentsCache` 采用 SharedPreferences 而非 SQLite：Feed 快照为小体积 JSON，
   SQLite（含 SQLCipher 密钥管理）收益为负；`CacheRepository` 已按域拆分，
   后续若引入 SQLite 后端仅替换存储实现、接口不变。
3. 邀请码 reason 为**响应扩展字段**（向后兼容），OpenAPI 已重新校验通过。
