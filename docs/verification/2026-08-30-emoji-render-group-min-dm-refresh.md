# 动效表情渲染 / 群聊下限 / DM 直聊根因修复 — 验证证据（2026-08-30）

## 1. 动效表情渲染为动画（不再退化为静态 Unicode）

- 目录新增反查：`fluentEmojiByChar(char)` 与纯函数 `fluentEmojisInMessage(text)`——消息全部字素（忽略空白）均为已知 Fluent 表情且数量 1–4 时判定为"纯表情消息"。
- 消息渲染（`matrix_home_page.dart`）：纯表情消息**去气泡**，按微信习惯放大渲染打包 GIF（单发 96px，多发 64px 并排，`gaplessPlayback` 保动画连续）；混合文本/未知字符/超过 4 个仍按普通文本渲染（保证可读与安全）。
- 兼容性：接收方 App 内置同一表情资产 + 增量通道可热更，因此两侧均以动画呈现；仅当消息中混有文字时退化为文本（产品上等价于微信的"表情与文字混排"）。
- 测试：`test/features/emoji/fluent_emoji_message_test.dart`（5 项：反查/纯表情/混合文本/超四上限/目录唯一性）。

## 2. 禁止创建二人群聊

- `GroupChatController.canCreate` 原本即要求选中 ≥2 位联系人（含自己共 3 人）；本批补齐**明确提示**（`group-chat-min-hint`）：不足时展示「群聊至少需要 3 名成员（含你自己）。仅选择 1 位联系人时无法创建；如需单聊请回到会话列表直接发起。」创建按钮保持禁用。
- 后续"邀请至 2 人"防御：群成员加入走服务端 auto-join 白名单，房间创建侧（GroupChatService）要求显式成员列表，2 人房间仅可能由 DM 降级路径产生——已由 #5 修复根除。

## 3 & 5. 新好友"无法打开加密会话"与"被组建为二人群聊"（根因与修复）

**根因链**（0.3.1 及之前的实现）：
1. B 向 A 发起会话时创建加密 DM 并邀请 A（Matrix DM 本质是 2 成员房间，属正常）；
2. A 侧打开联系人时，旧代码**不识别待接受的房间邀请**，转而创建**第二个** 2 人房间——该房间未写入 A 的 `m.direct` 映射，`Room.isDirectChat=false`，UI 以"群聊(2)"呈现（#5 现象）；
3. 旧代码成员统计只计"已加入"，新房间在 A 接受邀请前只有 1 人在线 → 校验抛错 → "无法打开加密会话"（#3 现象）。

**修复**（`matrix_direct_chat_adapter.dart`，0.3.2 已含，本批加固）：
- 成员统计改为 join+invite 口径，允许"对方待接受邀请"状态正常打开会话；
- `findJoinedDirectRoom` 增加受邀直房间扫描：自动 `join()` 对方发来的加密 DM 邀请，并补写本人 `m.direct` 映射（直聊识别随即可靠）；
- 本批加固：受邀扫描不再强依赖 `isDirectChat` 标记（服务器未复制 is_direct 的边缘情况也能识别——判断"受邀 + 成员恰为双方且含对方"）；
- 接受好友申请后**立即创建 DM**（见 #4），双方消息页即时出现会话入口，打开即聊天。

**验收**：双端为同构建时，接受申请 → 任一方进入联系人发消息 → 直接进入一对一加密会话收发消息；不出现第二个房间，不出现"群聊(2)"，不出现"无法打开加密会话"。

## 4. 好友状态与社交页面即时刷新

- 后端：好友申请投影补充 `matrix_user_id`（接受方据此直建 DM）。
- 客户端：`FriendRequestsPage` 接受成功后：
  1. `directChats.open(peer)` 立即创建双方加密会话（消息页同步出现入口）；
  2. `onRequestsChanged` → AppHome `_refreshAfterFriendChanges` → `ChatIdentityCache.refresh()`（监听它的通讯录/消息页即时重建）＋ 红点递减；
  3. 打开"新的朋友"与返回通讯录时均透传与刷新（`directChats`/`onRequestsChanged` 贯通 ContactsTabPage → ContactsPage）。
- 无需手动刷新或重新登录。

## 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` | **384 passed**（新增表情消息判定 5 项） |
| `pytest tests/business_api/friendship` | **14 passed**（投影补 matrix_user_id；按新去重契约更新 2 项） |
