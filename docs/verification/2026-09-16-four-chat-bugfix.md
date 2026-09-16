# 四个聊天缺陷修复验证（朋友圈评论相册 / 群聊转账 / 专属红包 / 私聊转账）

日期：2026-09-16（Asia/Hong_Kong）
基线 commit：`8ef5cbac4c80b49a9ad43f54f84a01bedf8dc9c8` + 工作树改动
来源：用户 2026-09-16 报障（4 项）

## 1. 根因与改动

### 问题 1：朋友圈评论选图片卡死

**根因**：`moment_comment_composer.dart` 以 **2 字段**记录泛型 push
（`({photos, original})`），而 `ImagePickerPage` 出栈的是 **3 字段**记录
（`({photos, original, flash})`，见 `image_picker_page.dart:511,936`）。Dart 记录是
结构类型：用 3 字段值完成 `Completer<2字段?>` 抛运行时 `TypeError`，路由无法完成出栈，
相册页停留在屏幕上，编辑器 `picking` 恒为 true（`locked = busy || picking`）→ 无法发送、
无法退出。`scan_qr_page.dart` 存在同一处失效类型。

**改动**：
- `moment_comment_composer.dart`：新增 `MomentGallerySelection` 类型别名并统一 push 泛型；
  收到 `flash: true` 时明确拒绝（评论只支持图片/GIF，闪照是聊天专属形态）。
- `scan_qr_page.dart`：push 泛型补齐 `flash`。
- 测试：`moment_gallery_contract_test.dart`（编译期契约断言）、
  `moment_comment_composer_test.dart`、`scan_qr_page_test.dart` 同步记录字段。

### 问题 2：群聊转账出现非群成员

**根因**：`room_page.dart` 打开 `ChatTransferSheet` 时**未传** `groupMembers`/`roomMembers`，
`_pickRecipient` 因此落到 `contactsSource` 分支，拉取**全部好友**，非本群用户可被选中，
转账消息指向非群成员。

**改动**：
- `room_page._showTransfer`：群聊时实时拉取当前房间成员
  （`_liveGroupMemberIdentities` → `roomLease.refreshRoomInfo()`），传入 `isGroup`、
  `groupMembers`、`resolveBusinessUser`、`avatarMedia`；群聊**不传** `contactsSource`。
- `ChatTransferSheet`：新增 `isGroup`；群聊分支只允许当前房间成员，成员未就绪时提示
  「群成员尚未加载」而**绝不**回退通讯录。通讯录仅保留给「私聊且对端资料未就绪」。

### 问题 3：专属红包选指定成员失败

**根因**：`room_page._showRedPacket` 未传 `resolveBusinessUser` 与 `avatarMedia`；
成员投影只填了 `avatarUrl`（被当作 mxc 解析）而 `businessUserId`/`businessAvatarUrl`
恒为空。选中非好友成员后既无本地业务身份、也无查询入口 → 直接弹
「无法确认红包账号：当前会话暂不支持确认该群成员账号」；好友头像因缺 avatarMedia 无法解析。

**改动**：
- 新增纯函数 `chatRoomMembersFor(...)`（`chat_red_packet_sheet.dart`）：排除自己、只含
  已加入成员；Matrix 头像（mxc）与业务头像/账号分别保留；显示名优先好友备注。
- `room_page._showRedPacket` 传入 `resolveBusinessUser: api.lookupUserByMatrixId` 与
  `avatarMedia: roomLease`。

### 问题 4：私聊转账不应可选收款人

**根因**：私聊仅把 peer 作为**默认值**，收款人行仍可点击并回退到通讯录。

**改动**：`ChatTransferSheet` 新增 `_recipientLocked`（`peerId` 非空即私聊）：
不响应点击、不显示箭头、`_pickRecipient` 直接返回，收款人恒为当前会话对方。

## 2. 测试证据

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `flutter test`（全量） | 0 | **2698 通过 / 0 失败**（改动前 2680） |
| `flutter analyze` | 0 | `No issues found!` |

日志：`artifacts/2026-09-16/flutter-full-bugfix4.txt`。环境：Flutter 3.44.9 stable /
Dart 3.12.2 / Windows 10 Pro 19045。

TDD 记录（每个缺陷先观察失败）：

| 用例 | RED 观察 |
| --- | --- |
| 朋友圈相册契约 | 编译失败：`({flash, original, photos})` 不能赋给 `({original, photos})` |
| 群聊收款人不得回退通讯录 | `Found 1 widget with key 'chat-transfer-contact-list'`（找到了通讯录列表） |
| 私聊收款人固定为对方 | 同上（私聊也能打开通讯录列表） |
| 群成员投影 | 变异探针：`businessUserId` 置 null → `Expected: 'user-alice' / Actual: <null>` |

更新了 2 个**编码了缺陷行为**的既有用例：`chat_transfer_sheet_test.dart` 的
「group chat requires picking a recipient」原本从通讯录选人，已改为使用群成员。

## 3. 未执行项与限制

- 未构建 APK/IPA，未做真机验证，未部署生产。
- 群聊成员「实时加载」依赖 `roomLease.refreshRoomInfo()`；加载失败时降级为空列表并提示，
  不静默回退通讯录。
- 私聊转账若打开弹层时对端资料尚未就绪（`peer == null`），仍保留通讯录选择路径——这是
  原有的兜底语义，未改动。
- 工作树中存在**其他任务**的未提交改动（钱包/session_store 等）与遗留文件
  `test/features/matrix/_tmp_probe_test.dart`，本任务未触碰。
