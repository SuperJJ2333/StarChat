# 好友系统专项重构实施计划

**状态：** 已批准
**日期：** 2026-09-03
**适用：** `apps/mobile_flutter` + `backend`（friendship 模块）
**依据：** 用户提交的好友系统专项整改要求（BUG 1–4 + Canonical Direct Conversation + 文档/测试矩阵）

## 现状结论（探索完成）

- BUG 1：通讯录数据来自 `ChatIdentityCache`（SharedPreferences 快照），仅在好友申请变化/自己头像更新时 refresh；好友改头像无触发器、头像缓存键不失效；朋友圈自建独立缓存违反单一数据源。
- BUG 2：搜索行有"快捷添加"直接发请求；"新的朋友"内联接受/拒绝，无验证详情页（申请编辑页 greeting/remark/tags 已存在）。
- BUG 3：accept 后靠整表网络刷新；无乐观插入/revision/系统消息；`friend.accepted` 仅为后端审计字符串。
- BUG 4：`createRoom(isDirect:true)+addToDirectChat` 的 m.direct 同步时序在 API 28 等设备上导致房间被缓存为群聊；SDK 0.34 `client.startDirectChat(mxid, waitForSync:true)` 可用，但需显式 `enableEncryption: true`。
- 后端无 `direct_conversations` 表；Matrix 房间创建全在客户端（服务端无法设置双方 m.direct，维持客户端创建、后端规范化登记）。

## Phase A — ProfileRepository（BUG 1）

ChatIdentityCache 重构为 ProfileRepository（保留 ChangeNotifier 与公开 API，页面接入面最小化）：FriendProfile{userId,nickname,avatarUrl,avatarVersion,updatedAt}；缓存键 `avatar:{userId}:{avatarVersion}`（与 avatar_cache.dart 版本键对齐）；持久化 SharedPreferences→SQLite（sqflite_common_ffi + 既有加密缓存仓库模式）；头像更新链路：写 SQLite → AvatarCache.invalidateUser → notify；刷新触发器：回前台（节流）+ FriendRequestWatch 60s 轮询同期 diff + 打开通讯录；contactsRevision 递增；朋友圈必传注入删除自建回退。测试先行：持久化/恢复、版本变更 invalidate+notify、revision、refresh 失败保留快照。

## Phase B — 好友申请流程（BUG 2）

删搜索行快捷添加；新增 AddFriendProfilePage（用户资料→添加到通讯录→既有申请页编辑 greeting/remark/tags→发送）；新增 FriendRequestReviewPage（通过朋友验证：头像/昵称/greeting/remark/tags→通过/拒绝，仅通过调 accept）；状态机 PENDING/ACCEPTED/REJECTED/EXPIRED/CANCELLED（后端补 DELETE /friends/requests/{id} 撤销）。

## Phase C — accept 即时同步（BUG 3）

accept 成功 → 乐观本地插入 ContactDetails（SQLite+revision+notify，不等网络整表）→ 建立 Direct Room（失败不阻断）→ 发送 `com.changliao.friend_accepted` 自定义事件到私聊房间，时间线映射 RoomMessageKind.system 渲染居中灰字"你已添加了 XXX，现在可以开始聊天了。"（绝不伪装对方气泡消息）→ 会话列表刷新；对端加入房间后同样渲染。

## Phase D — Direct Chat 修正（BUG 4）

`startDirectChat(enableEncryption: true, waitForSync: true)` + 建房后校验 `room.isDirectChat && directChatMatrixID==target`，不满足补 addToDirectChat 并等 m.direct 同步，仍失败不缓存抛错；结构化日志（sdkInt/roomId/targetUserId/isDirect 前后 m.direct/room 标志/encrypted/waitForSync/db 持久化）；`_requireSafe` 保留为最终防线。

## Phase E — Canonical Direct Conversation（后端）

新表 direct_conversations（user_low_id,user_high_id UNIQUE,matrix_room_id）+ Alembic 迁移（纯新增）；`GET /direct-conversations?peer_user_id=`（先查复用）与 `POST /direct-conversations`（注册，UNIQUE 冲突返回既有行）；客户端 DirectChatController 接入查-建-注册；OpenAPI 再生 + 测试。

## Phase F — 文档与验证

docs/FRIEND_SYSTEM_REFACTOR.md、docs/DIRECT_CHAT_ANDROID_COMPATIBILITY.md（含测试矩阵：API 28 Mi 6 真机实测，29–36 无设备行如实标注待测）；门禁全绿；Mi 6 全新安装/覆盖/清数据 × 私聊/accept/头像。不发版，验收后另行走发布流程。

## 顺序

A → B/C → D → E → F；测试先行；不触碰财务边界；后端仅新增（无破坏性变更）。
