# 申请添加朋友页 / DM 加密会话修复 / 好友申请通知与去重 — 验证证据（2026-08-30）

## 1. 「申请添加朋友」页面（新）

- 新页面 `lib/features/contacts/request_friend_page.dart`：
  - 打招呼内容（默认"我是"，≤50 字）；备注（≤20 字，对方通过后写入申请人通讯录）；
  - 标签：加载既有标签 + 行内新建，多选 ≤5（选中计数可见）；
  - 朋友圈权限三选一（默认 HIDE_MINE=不让他看我的朋友圈和状态；HIDE_THEIRS=不看他的；CHAT_ONLY=仅聊天）。
- 入口：搜索结果（`AddFriendPage`）点击候选用户进入该页；行尾快捷"添加"按钮保留。
- 提交：`POST /friends/requests` 扩展 `remark/tags/moments_permission`（body 校验：remark ≤20、tags ≤5 个每个 ≤64）；对方通过后偏好写入接收方通讯录（复式实现见下）。

## 2. 严重缺陷修复：「无法打开加密会话」

**根因**：新建 DM 后对方尚未接受邀请，`_snapshot` 只统计 joined 成员（=1），`DirectChatService._requireSafe` 要求 joined==2 → 必然抛错。此外受邀方 `findJoinedDirectRoom` 不识别待接受邀请，会重复创建第二个房间。

**修复**（`matrix_direct_chat_adapter.dart`）：
- 成员统计口径改为 join+invite（含受邀成员）；
- `findJoinedDirectRoom` 增加受邀直房间扫描：发现含对方的受邀直房间 → 自动 `join()` → 补写 `m.direct` → 正常返回；
- 会话加密校验（encrypted + 双成员 + 含对方）不变。

## 3. 好友申请通知（红点 + 系统通知）

- `FriendRequestWatch`：AppHome 每 60s 巡检 `/friends/requests`（PENDING），以 `requested_at|message` 签名与本地记录（SharedPreferences）比对：
  - 新记录 → 系统通知（独立渠道 `changliao_friend_requests`，正文"$昵称：打招呼内容"）+ 红点计数（=PENDING 条数）；
  - 已知记录内容/时间变化（重复申请）→ **弹新通知但红点不累计**（记录数未变）；
  - 记录消失（已处理）→ 清签名表；处理后再次申请产生新记录 → 通知 + 红点正常。
- 通知点击（`onDidReceiveNotificationResponse`）→ 根导航打开「新的朋友」页。
- 角标：通讯录"新的朋友"入口红色数字角标（`ValueNotifier<int>` 贯通 AppHome → ContactsTabPage → ContactsPage），处理一条减一。

## 4. 好友申请去重（后端）

- **重复申请（PENDING 存在）**：更新原记录的打招呼内容/申请时间/联系人偏好（幂等键不同也如此），返回 `duplicate:true`，不新增记录 —— 接收方仍只见一条，红点不增。
- **已处理（REJECTED/EXPIRED）后再申请**：插入**新**记录（不再复用旧行），红点与通知正常。
- **已是好友**：保持 409 `FRIEND_REQUEST_DUPLICATE`。
- **接受时应用偏好**：接受方通讯录写入申请人指定的备注/标签/朋友圈权限（`contact_*` 列，仅提供时覆盖）。
- 迁移 `0032_friend_request_prefs`（幂等 DO 块补三列；曾因版本号 33 字符超 `alembic_version` 列宽导致容器重启循环，已缩短为 `0032_friend_request_prefs` 并复验）。

## 5. 验证与部署

| 项目 | 结果 |
| --- | --- |
| `pytest tests/business_api/friendship` | **14 passed**（含新契约 4 项 + 按新规格更新的 2 项旧契约） |
| `pytest tests/business_api/test_user_search.py tests/business_api/ledger` | 8 passed |
| `flutter analyze` / `flutter test` | No issues / **369 passed**（新增申请页 3 项） |
| 生产部署（备份 `backups/20260829T214118Z/friendship/`） | business-api 重建；alembic head=0032；contact_* 三列已建 |
| 生产端到端探针 | `/friends/requests` 200；`/users/search?q=liu` 200（2 items，正确排除自己）；`?q=zz` 200 空结果 |

**遗留**：DM"邀请待接受"修复在真实双账号端到端（接受邀请→互发消息）建议人工复核一次（本地仅组件/服务层测试覆盖）；通知点击深链在 iOS 需随签名包实测。
