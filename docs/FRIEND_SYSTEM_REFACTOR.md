# ChatFlow 好友系统重构（2026-09-03）

**适用：** `apps/mobile_flutter` + `backend`（friendship 模块）
**计划存档：** `docs/superpowers/plans/2026-09-03-friend-system-refactor.md`
**Android 兼容性：** `docs/DIRECT_CHAT_ANDROID_COMPATIBILITY.md`

---

## 1. ProfileRepository（BUG 1：头像/资料统一数据源）

消息页、通讯录、朋友圈的唯一好友资料来源（原 `ChatIdentityCache` 重构），
任何页面不得再自建独立 UserProfile 数据。

```text
Business API /friends + /profile
        ↓ load / refresh / refreshContactsQuietly
ProfileRepository (ChangeNotifier)
        ├─ SQLite 持久化（chatflow_profile_v1.db，含旧 SharedPreferences 一次性迁移）
        ├─ FriendProfile 投影 {userId, nickname, avatarUrl, avatarVersion, updatedAt}
        ├─ 头像缓存键 avatar:{userId}:{avatarVersion}（版本变化即新键）
        └─ notifyListeners → 通讯录/消息页/朋友圈 实时重绘
```

- **文件**：`lib/features/matrix/profile_repository.dart`。
- **刷新触发器**：① App 回前台；② 好友申请 60s 轮询同期（`AppHome._pollFriendRequests`）；
  ③ `MomentsPage` 已改为必传注入（删除自建回退）。
- **头像更新链路**：`refreshContactsQuietly` diff 出 avatarUrl 变化 → SQLite 落库 →
  `AvatarCache.invalidateUser`（旧头像逐出）→ `notifyListeners()`。通讯录无需重启。
- **contactsRevision**：任何好友集合/资料变化 +1，消费方用于判断数据新旧。
- 静默刷新带 15s 节流与快照 diff（无变化不 notify，防抖）。

## 2. 好友申请流程（BUG 2）

```text
搜索结果行点击 → AddFriendProfilePage（用户资料：头像/昵称/畅聊号）
      ↓ 「添加到通讯录」
RequestFriendPage（申请添加朋友：编辑 greeting / remark / tags / 朋友圈权限）
      ↓ 「发送」→ POST /friends/requests
新的朋友列表（状态：PENDING/ACCEPTED/REJECTED/EXPIRED/CANCELLED）
      ↓ 点击请求
FriendRequestReviewPage（通过朋友验证：头像/昵称/greeting/remark/tags）
      ├─ 通过验证 → POST /friends/requests/{id}/accept
      └─ 拒绝     → POST /friends/requests/{id}/reject
```

- 搜索行的"快捷添加"按钮**已移除**——禁止点击即发送请求。
- 新增 `DELETE /friends/requests/{id}`：申请人撤销（PENDING → CANCELLED）。
- `GET /friends/requests` 补充 `user_id/remark/tags`（验证页数据）。

## 3. 好友接受即时同步（BUG 3）

accept API 成功后的本地编排（`FriendAcceptanceCoordinator`）：

1. **乐观本地插入**：以请求行数据构造 ContactSummary →
   `ProfileRepository.applyUpdatedContact`（SQLite + revision++ + notify）——
   通讯录立即可见，不等整表网络刷新，禁止要求重启；
2. **建立/取得加密私聊**（canonical 网关，见 §4）；失败不回滚好友；
3. **好友接受系统消息**：`com.changliao.friend_accepted` 自定义事件发送到私聊房间
   （E2EE），双端渲染为居中灰字系统消息
   **"你已添加了 XXX，现在可以开始聊天了。"**
   —— 与拍一拍同一系统消息管线（`RoomMessageKind.system`），
   绝不伪装成对方名义的普通气泡消息；
4. 会话列表经 onSync 自然刷新。

## 4. Canonical Direct Conversation（Phase E）

**后端**（`backend/app/modules/friendship`，迁移 `0035_direct_conversations`）：

- 表 `direct_conversations(id, user_low_id, user_high_id, matrix_room_id, created_at)`，
  `UNIQUE(user_low_id, user_high_id)`（expand-only，可回滚）。
- `GET /api/v1/direct-conversations?peer_user_id=` → `{matrix_room_id | null}`
  （创建私聊前先查询，存在复用）；
- `POST /api/v1/direct-conversations {peer_user_id, matrix_room_id}` → 注册；
  并发双开冲突返回既有行（`existing=true`，客户端弃用自己的房间采用规范房间）。
- Matrix 房间仍由客户端创建（服务端无法设置双方 m.direct 语义），后端只做
  规范化登记与复用。

**客户端**（`CanonicalDirectChatGateway` 包装 `DirectChatController` 网关）：

```text
open(matrixUserId)
  → businessUserIdOf(matrixUserId)（ProfileRepository 映射）
  → GET canonical → 存在 → 打开既有房间（invite 自动加入 + 加密/双人校验）
  → 无 → startDirectChat 新建 → POST 注册 → 并发冲突则采用返回的规范房间
  → 目录失败 → 静默回落原有路径（弱网不阻断私聊）
```

## 5. Android 9 直聊变群聊修复（BUG 4）

详见 `docs/DIRECT_CHAT_ANDROID_COMPATIBILITY.md`。要点：

- 统一 `client.startDirectChat(mxid, enableEncryption: true, waitForSync: true)`
  （SDK 内部完成 已有DM复用/受邀加入/isDirect 创建/等同步/写 m.direct）；
  显式 `enableEncryption: true` 防止"对方无密钥"时静默降级明文；
- 建房后校验 `room.isDirectChat && room.directChatMatrixID == target`，
  未同步补写 m.direct 并等待（3 次重试），仍失败**不缓存房间**直接抛错；
- `DirectChatService._requireSafe`（加密 + join/invite 双人 + 含目标）为最终防线。

## 6. 测试

| 层 | 文件 | 覆盖 |
| --- | --- | --- |
| Repository 单测 | `test/features/matrix/profile_repository_test.dart` | SQLite 往返、头像变化→notify+revision、乐观插入、FriendProfile 键规范 |
| Canonical 网关单测 | `test/features/matrix/canonical_direct_chat_test.dart` | 复用/新建注册/并发冲突/目录异常回落/无映射直通 |
| Accept 编排单测 | `test/features/friendship/friend_acceptance_coordinator_test.dart` | 乐观插入、建房失败不回滚、系统招呼文案 |
| 验证页 Widget | `test/features/contacts/friend_request_review_page_test.dart` | greeting/remark/tags 展示、仅通过验证触发 accept、状态文案 |
| 搜索流程 Widget | `test/features/contacts/add_friend_search_test.dart` | 快捷发送已移除、行点击进资料页 |
| DirectChat 集成 | `test/features/matrix/direct_chat_controller_test.dart` | 复用/新建/单飞/安全校验拒绝 |
| 后端 | `tests/business_api/friendship/test_friend_refactor.py` | cancel（本人/非本人/已处理/幂等）、验证页字段、canonical 查询/注册/冲突/自对/鉴权 |

## 7. 端点汇总（本重构新增/变更）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| DELETE | `/api/v1/friends/requests/{id}` | 申请人撤销（→CANCELLED） |
| GET | `/api/v1/friends/requests` | 响应新增 `user_id`/`remark`/`tags` |
| GET | `/api/v1/direct-conversations?peer_user_id=` | 规范私聊查询 |
| POST | `/api/v1/direct-conversations` | 规范私聊注册（冲突返回既有） |
| GET | `/api/v1/users/lookup?matrix_user_id=` | 群成员非好友反查资料+关系状态（2026-09-03 追加；404=不存在/拉黑/自己） |

OpenAPI 已再生（`packages/api-contracts/openapi/liuhetong-v1.yaml`）。

## 8. 群成员非好友点击（2026-09-03 追加）

聊天信息页群成员列表此前仅好友可点（`contactsById` 命中才导航），非好友
点击无响应且无法"添加到通讯录"。现分流（`room_page.openGroupMemberProfile`）：

- 好友 → 好友资料页（原路径不变）；
- 非好友 → `GET /users/lookup?matrix_user_id=` 反查 → 用户资料页
  （`AddFriendProfilePage`，按 relationship_state 启用「添加到通讯录」）；
- 自己 → 不可点；反查失败（不存在/拉黑）→ 提示对话框。

配套：直聊不健康旧房间（对方已退出）的修复策略见
`docs/DIRECT_CHAT_ANDROID_COMPATIBILITY.md`「不健康旧房间的修复」。
